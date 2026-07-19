#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymond-rrd-markers.sh
#
# Self-describing statuses: a status message carrying an embedded
# "<!--XYMON METRICS: <name>" block (or the legacy "<!--DEVMON RRD:"
# banner) is routed to the RRD block writer by content, with no TEST2RRD
# mapping. Feed real messages to the built xymond_rrd over stdin and
# assert which RRD files get created.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"

work=$(mktempdir)

# METRICS blocks are lazy by default (no file until the values change).
# Most sections below assert the EAGER path's mechanics - creation,
# units, dispatch, migration - so they pin the opt-out; the default-lazy
# behavior has its own section, which drops this override.
export LAZYDEFAULT=off

feed_status() {  # feed_status <testname> <bodyfile> -- send one status message
	local ts; ts=$(date +%s)
	rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
	{
		printf '@@status|%s|127.0.0.1|origin|testhost|%s|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$ts" "$1" $((ts+1800)) "$ts" "$ts"
		cat "$2"
		printf '@@\n'
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
	ls "$work/rrd/testhost" 2>/dev/null || true
}

# A status with two METRICS blocks: files appear for every instance of both,
# even though "diskio" has no TEST2RRD mapping.
cat >"$work/body-metrics" <<'EOF'
<!--XYMON METRICS: diskio_ops
DS:reads:GAUGE:600:0:U DS:writes:GAUGE:600:0:U
ada0 10:20
ada1 5:6
-->
<!--XYMON METRICS: diskio_busy
DS:busy:GAUGE:600:0:100
ada0 5
ada1 10
-->
<!--XYMON GRAPH: diskio_ops -->

Disk I/O Status

ada0: 10 r/s, 20 w/s
ada1: 5 r/s, 6 w/s
EOF
out=$(feed_status diskio "$work/body-metrics")
assert_contains "diskio_ops.ada0.rrd" "$out" "METRICS block creates one file per instance"
assert_contains "diskio_ops.ada1.rrd" "$out" "METRICS block creates one file per instance"
assert_contains "diskio_busy.ada0.rrd" "$out" "second METRICS block in the same message written too"
assert_contains "diskio_busy.ada1.rrd" "$out" "second METRICS block in the same message written too"

# A METRICS instance is reversibly encoded (rrdinstance_encode): a mount
# point or a name containing a comma round-trips to one unambiguous file,
# instead of the legacy lossy '/'->',' that aliased "/a/b" and "/a,b".
cat >"$work/body-encode" <<'EOF'
<!--XYMON METRICS: diskpath
DS:v:GAUGE:600:0:U
/data 1
/a,b 2
-->
status text
EOF
out=$(feed_status diskio "$work/body-encode")
assert_contains "diskpath.%2Fdata.rrd" "$out" "METRICS instance '/data' is percent-encoded, not ',data'"
assert_contains "diskpath.%2Fa,b.rrd" "$out" "'/a,b' stays distinct from what '/a/b' would encode to"

# Block names become RRD filename prefixes, so invalid names skip the whole
# block - but a valid block later in the same message is still written.
cat >"$work/body-evil" <<'EOF'
<!--XYMON METRICS: ../evil
DS:v:GAUGE:600:0:U
oops 1
-->
<!--XYMON METRICS: good_one
DS:v:GAUGE:600:0:U
inst 1
-->
status text
EOF
out=$(feed_status diskio "$work/body-evil")
assert_not_contains "evil" "$out" "invalid block name is rejected"
assert_contains "good_one.inst.rrd" "$out" "valid block after a rejected one is still written"

# The legacy devmon banner is routed by content too (previously it needed
# TEST2RRD="<column>=devmon").
cat >"$work/body-devmon" <<'EOF'
<!--DEVMON RRD: if_load 0 0
DS:ds0:COUNTER:600:0:U DS:ds1:COUNTER:600:0:U
eth0.0 4678222:9966777
eth1.0 123:456
-->
status text
EOF
out=$(feed_status devtest "$work/body-devmon")
assert_contains "if_load.eth0.0.rrd" "$out" "legacy DEVMON RRD banner routed without TEST2RRD"
assert_contains "if_load.eth1.0.rrd" "$out" "legacy DEVMON RRD banner routed without TEST2RRD"

# The legacy banner's name becomes a filename prefix too: path separators
# must never escape the host's RRD directory.
cat >"$work/body-traversal" <<'EOF'
<!--DEVMON RRD: ../../escape 0 0
DS:v:GAUGE:600:0:U
oops 1
-->
status text
EOF
out=$(feed_status devtest "$work/body-traversal")
[ -e "$work/rrd/escape.oops.rrd" ] || [ -e "$work/escape.oops.rrd" ] \
	&& fail "path traversal: RRD file created outside the host directory"
[ -f "$work/rrd/testhost/..,..,escape.oops.rrd" ] \
	|| fail "legacy banner name is sanitized, not honored as a path"

# CRLF messages work: trailing CRs are stripped from banner names and
# value lines instead of poisoning filenames and RRD updates.
printf '<!--XYMON METRICS: crlf_metric\r\nDS:v:GAUGE:600:0:U\r\ninst 7\r\n-->\r\nstatus text\r\n' >"$work/body-crlf"
out=$(feed_status diskio "$work/body-crlf")
assert_contains "crlf_metric.inst.rrd" "$out" "CRLF message still creates clean RRD files"

# A value longer than the writer's assembly buffer is skipped, not
# overflowed - and the rest of the block is still written.
{
	printf '<!--XYMON METRICS: longline\n'
	printf 'DS:v:GAUGE:600:0:U\n'
	printf 'huge %s\n' "$(printf '9%.0s' $(seq 1 30000))"
	printf 'ok 1\n'
	printf -- '-->\n'
	printf 'status text\n'
} >"$work/body-long"
out=$(feed_status diskio "$work/body-long")
assert_not_contains "longline.huge.rrd" "$out" "oversized value line is skipped"
assert_contains "longline.ok.rrd" "$out" "lines after an oversized one are still written"

# A "lazy" METRICS block: an instance begins existing when its values
# first change. The first frame only teaches baselines (idle 0:0,
# live 5:0); the second frame's live 0:0 deviates from its baseline and
# creates the file, while idle stays at baseline and never does. Once
# created, every later sample updates the file as usual.
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lazydemo lazy\n'
	printf 'DS:r:GAUGE:600:0:U DS:w:GAUGE:600:0:U\n'
	printf 'idle 0:0\n'
	printf 'live 5:0\n'
	printf -- '-->\n'
	printf 'status text\n'
	printf '@@\n'
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+300)) $((ts+2100)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lazydemo lazy\n'
	printf 'DS:r:GAUGE:600:0:U DS:w:GAUGE:600:0:U\n'
	printf 'idle 0:0\n'
	printf 'live 0:0\n'
	printf -- '-->\n'
	printf 'status text\n'
	printf '@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$work/rrd/testhost/lazydemo.live.rrd" ] \
	|| fail "lazy block: an instance whose values changed must get a file"
[ -e "$work/rrd/testhost/lazydemo.idle.rrd" ] \
	&& fail "lazy block: a baseline-steady instance must not create a file"

# The same gate from the graph definition: [lazygdef] carries LAZY in
# graphs.cfg, so a block WITHOUT any banner attribute is still lazy.
mkdir -p "$work/etc"
cat >"$work/etc/graphs.cfg" <<'GDEFS'
[lazygdef]
	LAZY
[filt]
	EXSTOREPATTERN bad
[only]
	STOREPATTERN keep
[flz]
	LAZY
	STOREPATTERN pinned
[cfmax]
	FNPATTERN ^cfx\..+\.rrd
	DEF:m=x.rrd:v:MAX
GDEFS
lazyfeed() {  # lazyfeed <blockheader> <inst1 val1a val1b> <inst2 val2a val2b>
	local ts; ts=$(date +%s)
	rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
	{
		printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$ts" $((ts+1800)) "$ts" "$ts"
		printf '<!--XYMON METRICS: %s\nDS:v:GAUGE:600:0:U\n%s %s\n%s %s\n-->\nstatus\n@@\n' \
			"$1" "$2" "$3" "$5" "$6"
		printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			$((ts+300)) $((ts+2100)) "$ts" "$ts"
		printf '<!--XYMON METRICS: %s\nDS:v:GAUGE:600:0:U\n%s %s\n%s %s\n-->\nstatus\n@@\n' \
			"$1" "$2" "$4" "$5" "$7"
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
	ls "$work/rrd/testhost" 2>/dev/null || true
}

# EXSTOREPATTERN drops matching instances at the writer; STOREPATTERN
# keeps only matching ones; and a STOREPATTERN match forces an instance
# past the LAZY gate - a steady value stores immediately when named.
cat >"$work/body-storefilters" <<'BODY'
<!--XYMON METRICS: filt
DS:v:GAUGE:600:0:U
bad 5
good 6
-->
<!--XYMON METRICS: only
DS:v:GAUGE:600:0:U
keep 7
other 8
-->
<!--XYMON METRICS: flz
DS:v:GAUGE:600:0:U
pinned 100
rest 100
-->
status text
BODY
out=$(feed_status diskio "$work/body-storefilters")
assert_not_contains "filt.bad.rrd" "$out" "EXSTOREPATTERN drops the matching instance"
assert_contains "filt.good.rrd" "$out" "EXSTOREPATTERN leaves the others"
assert_contains "only.keep.rrd" "$out" "STOREPATTERN keeps the matching instance"
assert_not_contains "only.other.rrd" "$out" "STOREPATTERN drops non-matching instances"
assert_contains "flz.pinned.rrd" "$out" "a STOREPATTERN match forces storage past the LAZY gate"
assert_not_contains "flz.rest.rrd" "$out" "unforced flat instances stay lazy"

# gdef LAZY: the first sample is the baseline, whatever its value - the
# steady instance (4 -> 4) gets no file, the changing one (4 -> 9) does.
out=$(lazyfeed lazygdef steady 4 4 changing 4 9)
assert_not_contains "lazygdef.steady.rrd" "$out" "a steady instance never gets a file, even at a nonzero baseline"
assert_contains "lazygdef.changing.rrd" "$out" "an instance is created when its value first changes"

# A dropped host re-learns lazy baselines instead of comparing against
# stale ones. In one xymond_rrd process: learn baseline 5 for a lazy
# instance, drop the host, then re-report a NEW steady value 8 twice.
# With the drop hook the baseline is re-learned (8 is the new baseline,
# no file); without it the stale 5 makes 8 look like a deviation and a
# file is created spuriously.
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|dh|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lz lazy\nDS:v:GAUGE:600:0:U\nx 5\n-->\ns\n@@\n'
	printf '@@drophost|%s|127.0.0.1|dh\n@@\n' $((ts+60))
	printf '@@status|%s|127.0.0.1|origin|dh|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+120)) $((ts+1920)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lz lazy\nDS:v:GAUGE:600:0:U\nx 8\n-->\ns\n@@\n'
	printf '@@status|%s|127.0.0.1|origin|dh|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+180)) $((ts+1980)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lz lazy\nDS:v:GAUGE:600:0:U\nx 8\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" "$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -e "$work/rrd/dh/lz.x.rrd" ] \
	&& fail "drop hook: re-added instance steady at a new value must re-learn, not create"

# Markers are line-anchored: a banner quoted mid-line must not trigger the
# writer, and a plain status creates nothing.
cat >"$work/body-midline" <<'EOF'
the docs mention <!--XYMON METRICS: quoted
and that is all
EOF
out=$(feed_status diskio "$work/body-midline")
assert_not_contains ".rrd" "$out" "mid-line banner text does not trigger the writer"

printf 'all green\n' >"$work/body-plain"
out=$(feed_status diskio "$work/body-plain")
assert_not_contains ".rrd" "$out" "plain status without markers creates nothing"

# Dialect extensibility: a DS spec may declare a unit as an optional 7th
# colon field - the writer must strip it before rrdtool sees the spec, or
# file creation fails. A declaration line the writer does not know (an
# ALL-CAPS keyword ending in ':', here a future THRESHOLD:) is ignored:
# no file for it, and the instances around it are written normally.
cat >"$work/body-dialect" <<'EOF'
<!--XYMON METRICS: temperature
DS:temp:GAUGE:1200:-30:50:degC DS:hi:GAUGE:600:-30:50
THRESHOLD:temp:>hi:warn
cpu 47:70
ambient 22:35
-->
temperatures OK
EOF
out=$(feed_status diskio "$work/body-dialect")
assert_contains "temperature.cpu.rrd" "$out" "unit-suffixed DS spec still creates the file"
assert_contains "temperature.ambient.rrd" "$out" "instance after a declaration line written normally"
assert_not_contains "THRESHOLD" "$out" "unknown declaration line creates no file"
# The declared unit, heartbeats AND the THRESHOLD relation land in the
# fileset index (units only for the DS that has one; heartbeats for every
# declared DS; the relation validated against the block)
grep -q 'temperature\.cpu\.rrd [0-9]* u=temp:degC h=temp:1200,hi:600 d=temp,hi t=temp:>hi:warn g=[0-9]*$' "$work/rrd/testhost/.fileset-index" \
	|| fail "declared unit/heartbeat/threshold not recorded in the fileset index: $(cat "$work/rrd/testhost/.fileset-index")"

# A redeclared heartbeat replaces the record outright (strong, complete
# spec) - the schema-reconcile tool trusts h= as the CURRENT declaration.
sed 's/DS:temp:GAUGE:1200/DS:temp:GAUGE:900/' "$work/body-dialect" >"$work/body-dialect2"
feed_status diskio "$work/body-dialect2" >/dev/null
grep -q 'temperature\.cpu\.rrd [0-9]* u=temp:degC h=temp:900,hi:600 ' "$work/rrd/testhost/.fileset-index" \
	|| fail "redeclared heartbeat did not replace h=: $(grep temperature.cpu "$work/rrd/testhost/.fileset-index")"

# Durable lazy baselines: the (value, since) record survives the writer.
# Process 1 learns the baseline (no file); process 2 - a restart - sees a
# changed value and creates the file on its FIRST sample, seeded with the
# baseline one step earlier (a true step edge). The flat record clears on
# materialization. ts is step-aligned: the seed's consolidated bucket is
# >= 50% covered (xff) only when ts % 300 <= 150, so an arbitrary ts
# makes the splice-fetch assertion below a coin flip.
ts=$(( $(date +%s) / 300 * 300 ))
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lzp lazy\nDS:v:GAUGE:600:0:U\nx 5\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -e "$work/rrd/testhost/lzp.x.rrd" ] && fail "baseline learn must not create a file"
grep -q 'lzp\.x\.rrd [0-9]* h=v:600 d=v g=[0-9]* b=[0-9]*,5$' "$work/rrd/testhost/.fileset-index" \
	|| fail "baseline not durable in the index: $(grep lzp "$work/rrd/testhost/.fileset-index")"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+300)) $((ts+2100)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lzp lazy\nDS:v:GAUGE:600:0:U\nx 9\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$work/rrd/testhost/lzp.x.rrd" ] \
	|| fail "restart lost the baseline - the change was not detected on the first sample"
grep -q 'lzp\.x\.rrd.* b=' "$work/rrd/testhost/.fileset-index" \
	&& fail "the flat record must clear when the file materializes"
if command -v rrdtool >/dev/null 2>&1; then
	# With the step-aligned ts above, the seed bucket (value 5, ending
	# at ts) and the change bucket (9, ending ts+300) are both fully
	# covered - deterministic, where an arbitrary ts left the seed
	# bucket under the xff threshold half the time.
	nvals=$(rrdtool fetch "$work/rrd/testhost/lzp.x.rrd" AVERAGE -s $((ts-700)) -e $((ts+700)) 2>/dev/null \
		| grep -cE ': [0-9]')
	[ "$nvals" -ge 2 ] || fail "splice seed missing - expected the baseline step edge plus the change (got $nvals values)"
fi

# Freshness follows COMMIT, not receipt: an update rrdtool rejects (a
# timestamp behind the file's last update) must not advance the entry's
# index timestamp, or a chronically broken producer looks fresh forever.
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
feed_at() {  # feed_at <statusts> <value> -- one committed-or-rejected sample
	{
		printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$1" $(($1+1800)) "$ts" "$ts"
		printf '<!--XYMON METRICS: frsh\nDS:v:GAUGE:600:0:U\nx %s\n-->\ns\n@@\n' "$2"
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
}
feed_at "$ts" 5
ts1=$(awk '/^frsh\.x\.rrd /{print $2}' "$work/rrd/testhost/.fileset-index")
[ -n "$ts1" ] || fail "committed update did not stamp the index"
feed_at $((ts-600)) 6	# behind the file's last update: rrdtool rejects it
ts2=$(awk '/^frsh\.x\.rrd /{print $2}' "$work/rrd/testhost/.fileset-index")
[ "$ts2" = "$ts1" ] || fail "rejected update advanced freshness ($ts1 -> $ts2)"
# The discriminating case: a NEWER timestamp whose value rrdtool rejects
# (the max-merge hides the older-timestamp case, this one it cannot).
feed_at $((ts+150)) not-a-number
ts2=$(awk '/^frsh\.x\.rrd /{print $2}' "$work/rrd/testhost/.fileset-index")
[ "$ts2" = "$ts1" ] || fail "rejected garbage value advanced freshness ($ts1 -> $ts2)"
feed_at $((ts+300)) 7
ts3=$(awk '/^frsh\.x\.rrd /{print $2}' "$work/rrd/testhost/.fileset-index")
[ "$ts3" -gt "$ts1" ] || fail "accepted update did not advance freshness ($ts1 -> $ts3)"

# Drop barrier: a straggler message already queued behind @@drophost must
# not recreate files - or the fileset index - inside the deleted host
# directory (the deletion itself is forked, so a recreated file also
# races it). The barrier discards messages for a recently dropped host.
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: dropme\nDS:v:GAUGE:600:0:U\nx 5\n-->\ns\n@@\n'
	printf '@@drophost|%s|127.0.0.1|testhost\n@@\n' "$ts"
	# Give the forked deletion time to FINISH before the straggler
	# arrives - the losing interleaving, where a recreated file has
	# nothing left to clean it up. (Without the delay the child's rm
	# usually runs last and hides the recreation by timing luck.)
	sleep 2
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+1)) $((ts+1801)) "$ts" "$ts"
	printf '<!--XYMON METRICS: dropme\nDS:v:GAUGE:600:0:U\nx 6\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
sleep 1		# the forked directory deletion
[ -e "$work/rrd/testhost" ] \
	&& fail "straggler recreated the dropped host directory: $(ls "$work/rrd/testhost")"

# renamehost: pending CACHED updates must flush into the old-named files
# before the rename moves them (rrdcacheflushhost cannot do this: it
# expects "/host"-shaped keys and rate-limits; a call with a bare
# hostname is a silent no-op).
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: renm nolazy\nDS:v:GAUGE:600:0:U\nx 5\n-->\ns\n@@\n'
	printf '@@renamehost|%s|127.0.0.1|testhost|newhost\n@@\n' "$ts"
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --debug >"$work/dbg.log" 2>&1
[ -d "$work/rrd/newhost" ] || fail "rename did not move the host directory"
grep -q "flushed and dropped 1 entries for host testhost" "$work/dbg.log" \
	|| fail "pending update not flushed before the rename: $(grep -i updcache "$work/dbg.log")"

# The shipped default (no LAZYDEFAULT in the environment): every METRICS
# block is lazy - a flat first sample becomes an index record, not a
# file - and "nolazy" opts a block out. (The export at the top pins
# LAZYDEFAULT=off for the eager sections; drop it here.)
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: ld\nDS:v:GAUGE:600:0:U\nx 5\n-->\n'
	printf '<!--XYMON METRICS: ldno nolazy\nDS:v:GAUGE:600:0:U\ny 6\n-->\ns\n@@\n'
} | env -u LAZYDEFAULT XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -e "$work/rrd/testhost/ld.x.rrd" ] && fail "default: a plain METRICS block must be lazy"
grep -q 'ld\.x\.rrd .* b=' "$work/rrd/testhost/.fileset-index" \
	|| fail "default-lazy flat record missing"
[ -f "$work/rrd/testhost/ldno.y.rrd" ] \
	|| fail "nolazy must opt a block out of the lazy default"
# ... and a legacy DEVMON banner stays eager under the default.
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--DEVMON RRD: lddev\nDS:v:GAUGE:600:0:U\nz 7\n-->\ns\n@@\n'
} | env -u LAZYDEFAULT XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$work/rrd/testhost/lddev.z.rrd" ] \
	|| fail "legacy DEVMON banner must stay eager under the lazy default"

# Deep-review regressions: (1) a legacy DEVMON block may carry instances
# named like a declaration keyword - the METRICS-only contract must not
# drop them; (2) a METRICS block without a DS line writes nothing and
# must not inherit the previous block's DS params; (3) a self-closed
# one-line banner is an empty block - the status text after it must not
# be consumed as instance data.
cat >"$work/body-regress" <<'EOF'
<!--DEVMON RRD: if_load 0 0
DS:ds0:COUNTER:600:0:U DS:ds1:COUNTER:600:0:U
CPU:1 47:70
-->
<!--XYMON METRICS: goodblock
DS:v:GAUGE:600:0:U DS:w:GAUGE:600:0:U
full 1:2
short 1
-->
<!--XYMON METRICS: nodsblock
x 5
y 6
-->
<!--XYMON METRICS: selfclosed -->
oops 7
status text
EOF
out=$(feed_status devtest "$work/body-regress")
# Lazy gate vs unknown values: "U" and "0" are DIFFERENT samples - an
# instance whose probe failed (U baseline) and then reports 0 has
# changed and must get its file (numeric-only comparison equated them).
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lzu lazy\nDS:v:GAUGE:600:0:U\nx U\n-->\ns\n@@\n'
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+300)) $((ts+2100)) "$ts" "$ts"
	printf '<!--XYMON METRICS: lzu lazy\nDS:v:GAUGE:600:0:U\nx 0\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$work/rrd/testhost/lzu.x.rrd" ] \
	|| fail "lazy: a U -> 0 transition is a change and must create the file"

assert_contains "if_load.CPU:1.rrd" "$out" "legacy devmon keyword-named instance still written"
assert_contains "goodblock.full.rrd" "$out" "normal instance in a 2-DS block written"
assert_not_contains "goodblock.short" "$out" "instance with too few values skipped"
assert_not_contains "nodsblock" "$out" "block without a DS line writes nothing"
assert_not_contains "selfclosed" "$out" "self-closed banner opens no block"
assert_not_contains ".oops." "$out" "status text after a self-closed banner is not instance data"

# The writer-kept fileset index: every RRD write is bookkept into
# <host>/.fileset-index (a durable home for display counts and, later,
# units/thresholds/lazy baselines). A deleted index is reseeded from a
# one-off directory scan, so pre-existing files reappear in it.
ts=$(date +%s)
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: fsx\nDS:v:GAUGE:600:0:U\na 1\nb 2\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
idx="$work/rrd/testhost/.fileset-index"
[ -f "$idx" ] || fail "fileset index not written"
grep -q '^fsx\.a\.rrd [0-9]' "$idx" || fail "index misses a written file: $(cat "$idx")"
grep -q '^fsx\.b\.rrd [0-9]' "$idx" || fail "index misses a written file"

rm -f "$idx"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+300)) $((ts+2100)) "$ts" "$ts"
	printf '<!--XYMON METRICS: fsy\nDS:v:GAUGE:600:0:U\nc 3\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
grep -q '^fsy\.c\.rrd [0-9]' "$idx" || fail "rebuilt index misses the new write"
grep -q '^fsx\.a\.rrd [0-9]' "$idx" || fail "rebuilt index misses pre-existing files (scan seed): $(cat "$idx")"

# Derived consolidations: a gdef whose FNPATTERN matches the file and
# whose DEFs read :MAX makes the writer clone the AVERAGE archives as
# MAX at creation; a file no gdef reads beyond AVERAGE gets exactly the
# stock set. (Requires the rrdtool CLI to inspect the created file.)
if command -v rrdtool >/dev/null 2>&1; then
	ts=$(date +%s)
	rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
	{
		printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$ts" $((ts+1800)) "$ts" "$ts"
		printf '<!--XYMON METRICS: cfx\nDS:v:GAUGE:600:0:U\na 1\n-->\ns\n@@\n'
		printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			$((ts+1)) $((ts+1801)) "$ts" "$ts"
		printf '<!--XYMON METRICS: cfplain\nDS:v:GAUGE:600:0:U\nx 1\n-->\ns\n@@\n'
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
	rrdtool info "$work/rrd/testhost/cfx.a.rrd" | grep -q 'cf = "MAX"' \
		|| fail "gdef-declared MAX archives not derived at creation"
	rrdtool info "$work/rrd/testhost/cfx.a.rrd" | grep -q 'cf = "AVERAGE"' \
		|| fail "AVERAGE archives must remain alongside derived ones"
	rrdtool info "$work/rrd/testhost/cfplain.x.rrd" | grep -q 'cf = "MAX"' \
		&& fail "a file no gdef reads beyond AVERAGE must keep the stock archive set"
fi

# Crash-leftover rebuild: a zero-length index (interrupted flush) must
# reseed from the directory scan, exactly like a missing one. Pin a file
# that is actually on disk - which set that is depends on whether the
# (rrdtool-gated) CF section above ran and reset the directory.
preexisting=$(basename "$(ls "$work/rrd/testhost/"*.rrd | head -1)")
: >"$idx"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+600)) $((ts+2400)) "$ts" "$ts"
	printf '<!--XYMON METRICS: fsz\nDS:v:GAUGE:600:0:U\nd 4\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
grep -q "^${preexisting//./\\.} [0-9]" "$idx" \
	|| fail "empty index file not rebuilt by the scan ($preexisting missing): $(cat "$idx")"
grep -q '^fsz\.d\.rrd [0-9]' "$idx" || fail "rebuilt index misses the triggering write"

# The block writer carries a pre-cutover legacy file across (do_disk's
# one-time migration, ported): after the rename, only the encoded file
# remains - no frozen legacy curve graphing next to a restarted one.
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: mig\nDS:v:GAUGE:600:0:U\n/var 1\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$work/rrd/testhost/mig.%2Fvar.rrd" ] || fail "migration setup: encoded file not created"
mv "$work/rrd/testhost/mig.%2Fvar.rrd" "$work/rrd/testhost/mig,var.rrd"
rm -f "$work/rrd/testhost/.fileset-index"
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		$((ts+300)) $((ts+2100)) "$ts" "$ts"
	printf '<!--XYMON METRICS: mig\nDS:v:GAUGE:600:0:U\n/var 2\n-->\ns\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$work/rrd/testhost/mig.%2Fvar.rrd" ] || fail "legacy block file not migrated to the encoded name"
[ -e "$work/rrd/testhost/mig,var.rrd" ] && fail "legacy file left behind - every mount would graph twice"

# Dispatch precedence (self-describing beats built-in): a status whose
# column has a built-in handler but which carries a store block is
# written by the block writer ONLY - the built-in must not double-write.
# A block-less status on the same column hits the built-in unchanged.
cat >"$work/body-diskblock" <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 100 50 50 50% /var
<!--XYMON METRICS: diskpct
DS:pct:GAUGE:600:0:100
/var 50
-->
EOF
out=$(feed_status disk "$work/body-diskblock")
assert_contains "diskpct.%2Fvar.rrd" "$out" "block on a built-in column is written by the block writer"
assert_not_contains "disk.%2Fvar.rrd" "$out" "built-in disk handler must not double-write a block-bearing status"

cat >"$work/body-diskplain" <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 100 50 50 50% /var
EOF
out=$(feed_status disk "$work/body-diskplain")
assert_contains "disk.%2Fvar.rrd" "$out" "block-less disk status hits the built-in handler unchanged"

# A banner the writer would REJECT (invalid name) must not divert routing:
# the built-in handler still runs, instead of storing nothing at all.
cat >"$work/body-badname" <<'EOF'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/sda1 100 50 50 50% /var
<!--XYMON METRICS: ../evil
DS:v:GAUGE:600:0:U
x 1
-->
EOF
out=$(feed_status disk "$work/body-badname")
assert_contains "disk.%2Fvar.rrd" "$out" "invalid-name block falls back to the built-in handler"

pass "XYMON METRICS blocks and legacy DEVMON banners are written by content routing"
