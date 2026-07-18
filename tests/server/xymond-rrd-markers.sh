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
DS:temp:GAUGE:600:-30:50:degC DS:hi:GAUGE:600:-30:50
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

pass "XYMON METRICS blocks and legacy DEVMON banners are written by content routing"
