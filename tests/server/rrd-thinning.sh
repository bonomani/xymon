#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/rrd-thinning.sh
#
# Write-thinning: a sample carrying no new information is not written.
# The gate is the block's own DS heartbeat declaration (keepalive =
# half the smallest declared heartbeat, capped by the file's own; the
# stock 600 = 2*step declares no tolerance and thins nothing). On a
# change after a gap the writer pre-writes the old values one step
# earlier, pinning the step edge - without it rrdtool back-fills the
# whole gap with the NEW value.
# ABSOLUTE DSes and 'U' values are excluded: equal ABSOLUTE readings
# are new information, and thinning unknowns would invent continuity.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"
command -v rrdtool >/dev/null 2>&1 || skip "rrdtool CLI not available"

work=$(mktempdir)
mkdir -p "$work/rrd" "$work/tmp"

# Step-aligned base; later samples run FORWARD from here (rrdtool accepts
# future timestamps, but rejects ones behind a file's creation time).
ts=$(( $(date +%s) / 300 * 300 + 300 ))	# next step boundary: never behind the file's create time

msg_at() {  # msg_at <statusts> <blockname> <dsspec> <value> -- one message on stdout
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$1" $(($1+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: %s\n%s\nx %s\n-->\ns\n@@\n' "$2" "$3" "$4"
}
run_daemon() {  # consume stdin messages in ONE daemon process (thinning state is per process)
	env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
}
lastupd() {  # lastupd <rrdfile> -> last update timestamp
	rrdtool lastupdate "$work/rrd/testhost/$1" | awk '/^[0-9]+:/{sub(":","",$1); print $1}'
}

# One daemon run, five samples of the declared-tolerance block:
# heartbeat 7200 -> keepalive 3600. Unchanged samples inside the window
# skip; the unchanged sample past the keepalive writes; the change after
# a gap writes AND pre-writes the old value one step earlier.
{
	msg_at "$ts"          thn "DS:v:GAUGE:7200:0:U" 5
	msg_at $((ts+300))    thn "DS:v:GAUGE:7200:0:U" 5
	msg_at $((ts+600))    thn "DS:v:GAUGE:7200:0:U" 5
} | run_daemon
[ "$(lastupd thn.x.rrd)" = "$ts" ] \
	|| fail "unchanged samples inside the keepalive were written (last=$(lastupd thn.x.rrd), want $ts)"

{
	msg_at "$ts"          thn "DS:v:GAUGE:7200:0:U" 5
	msg_at $((ts+3900))   thn "DS:v:GAUGE:7200:0:U" 5
	msg_at $((ts+5100))   thn "DS:v:GAUGE:7200:0:U" 9
} | run_daemon
[ "$(lastupd thn.x.rrd)" = "$((ts+5100))" ] || fail "changed sample was not written"
fetchval() {  # fetchval <endts> -> consolidated value of the bucket ending there
	rrdtool fetch "$work/rrd/testhost/thn.x.rrd" AVERAGE -s $(($1-300)) -e "$1" \
		| awk -v t="$1" '$1 == t":" {print $2}'
}
grep -q '^5' <<<"$(fetchval $((ts+4800)))" \
	|| fail "gap not pinned at the old value: bucket $(fetchval $((ts+4800)))"
grep -q '^9' <<<"$(fetchval $((ts+5100)))" \
	|| fail "change bucket does not carry the new value: $(fetchval $((ts+5100)))"

# The stock heartbeat (600 = 2*step) declares no tolerance: no thinning,
# every sample writes - existing producers see zero behavior change.
{
	msg_at "$ts"          std "DS:v:GAUGE:600:0:U" 5
	msg_at $((ts+300))    std "DS:v:GAUGE:600:0:U" 5
} | run_daemon
[ "$(lastupd std.x.rrd)" = "$((ts+300))" ] \
	|| fail "stock-heartbeat block was thinned (last=$(lastupd std.x.rrd))"

# ABSOLUTE is excluded even with a large heartbeat: equal readings are
# new information (the value resets on read).
{
	msg_at "$ts"          abs "DS:v:ABSOLUTE:7200:0:U" 5
	msg_at $((ts+300))    abs "DS:v:ABSOLUTE:7200:0:U" 5
} | run_daemon
[ "$(lastupd abs.x.rrd)" = "$((ts+300))" ] \
	|| fail "ABSOLUTE block was thinned (last=$(lastupd abs.x.rrd))"

# 'U' always writes: unknown is not a constant to interpolate.
{
	msg_at "$ts"          unk "DS:v:GAUGE:7200:0:U" U
	msg_at $((ts+300))    unk "DS:v:GAUGE:7200:0:U" U
} | run_daemon
[ "$(lastupd unk.x.rrd)" = "$((ts+300))" ] \
	|| fail "unknown values were thinned (last=$(lastupd unk.x.rrd))"

# The baseline thinning compares against must be a value the file holds.
hb='DS:v:GAUGE:7200:U:U'	# keepalive R = 3600s: thinning is active

# A dropped host's files are deleted, and its baseline must go with them:
# the same value sent again after the drop is the new file's first sample.
rm -rf "$work/rrd"; mkdir -p "$work/rrd"
{
	msg_at "$ts" drp "$hb" 5
	printf '@@drophost|%s|127.0.0.1|testhost\n@@\n' "$((ts+60))"
	msg_at "$((ts+300))" drp "$hb" 5
} | run_daemon
[ "$(lastupd drp.x.rrd)" = "$((ts+300))" ] \
	|| fail "the first sample after a drophost was thinned against the dropped host's value (last=$(lastupd drp.x.rrd))"

# With the update cache on, a queued value is not yet in the file: if its
# batch is then rejected, the same value must still be written when it
# comes again. The 12th cached update forces a flush (CACHESZ); the file is
# a directory at that moment, so the batch fails and is dropped. Cached
# updates are deduplicated by message sequence, so each message has its own.
seq=0
msg_seq() {  # msg_seq <statusts> <blockname> <dsspec> <value> -- like msg_at, numbered
	seq=$((seq+1))
	printf '@@status#%s|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$seq" "$1" $(($1+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: %s\n%s\nx %s\n-->\ns\n@@\n' "$2" "$3" "$4"
}
rm -rf "$work/rrd"; mkdir -p "$work/rrd"
{
	msg_seq "$ts" cch "$hb" 5
	i=1
	while [ "$i" -le 10 ]; do
		msg_seq "$((ts+300*i))" fill "$hb" "$i"
		i=$((i+1))
	done
	sleep 1
	rm -f "$work/rrd/testhost/cch.x.rrd"
	mkdir "$work/rrd/testhost/cch.x.rrd"
	msg_seq "$((ts+600))" cch "$hb" 6
	sleep 1
	rmdir "$work/rrd/testhost/cch.x.rrd"
	msg_seq "$((ts+900))" cch "$hb" 5
	printf '@@shutdown\n@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" 2>/dev/null
[ "$(lastupd cch.x.rrd)" = "$((ts+900))" ] \
	|| fail "a value whose cached batch was rejected was later thinned as if stored (last=$(lastupd cch.x.rrd))"

# A queued value is the newest one on its way to the file, so thinning
# compares with it rather than with the last committed one. Each run
# commits 6 first: the new file's 5 is queued, ten fillers bring the
# update count to the forced flush, and the 6 takes the batch to disk.
# Then 10 is queued, and the next sample must be judged against it.
queued_case() {  # queued_case <blockname> <last value> -- prints the file's last update
	rm -rf "$work/rrd"; mkdir -p "$work/rrd"
	{
		msg_seq "$ts" "$1" "$hb" 5
		i=1
		while [ "$i" -le 10 ]; do
			msg_seq "$((ts+300*i))" fill "$hb" "$i"
			i=$((i+1))
		done
		msg_seq "$((ts+300))" "$1" "$hb" 6
		msg_seq "$((ts+600))" "$1" "$hb" 10
		msg_seq "$((ts+900))" "$1" "$hb" "$2"
		printf '@@shutdown\n@@\n'
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" 2>/dev/null
	lastupd "$1.x.rrd"
}
# Back to the committed 6 after the queued 10: a change, so it is written.
last=$(queued_case qd 6)
[ "$last" = "$((ts+900))" ] \
	|| fail "a return to the committed value past a queued change was thinned (last=$last, want $((ts+900)))"
# 7 one step after the queued 10: no gap after the queued value, so no
# pre-write - one stamped on the 10's time makes rrdtool reject the batch.
last=$(queued_case qe 7)
[ "$last" = "$((ts+900))" ] \
	|| fail "a change one step after a queued value lost its batch (last=$last, want $((ts+900)))"

# The keepalive follows the file's own heartbeat when that is smaller
# than the declared one: a file created with 600 (legacy, or before the
# declaration grew) records UNKNOWN across any gap longer than that, so
# it is not thinned until rrdreconcile has raised it.
rm -rf "$work/rrd"; mkdir -p "$work/rrd/testhost"
rrdtool create "$work/rrd/testhost/hbf.x.rrd" --start $((ts-300)) --step 300 \
	DS:v:GAUGE:600:U:U RRA:AVERAGE:0.5:1:100
{
	msg_at "$ts"          hbf "DS:v:GAUGE:7200:0:U" 5
	msg_at $((ts+300))    hbf "DS:v:GAUGE:7200:0:U" 5
	msg_at $((ts+600))    hbf "DS:v:GAUGE:7200:0:U" 5
} | run_daemon
[ "$(lastupd hbf.x.rrd)" = "$((ts+600))" ] \
	|| fail "a file whose own heartbeat is 600 was thinned by the declared 7200 (last=$(lastupd hbf.x.rrd), want $((ts+600)))"

pass "write-thinning skips unchanged values, pins the step edge and never thins unknowns"
