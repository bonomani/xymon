#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymond-rrd-smoke-grow.sh
#
# A smoke host whose sample count is raised (smoke:3 -> smoke:5, or a
# larger SMOKEPINGSAMPLES) keeps its tcp.conn-smoke.rrd updating: the
# writer adds the missing pingK datasets and switches the cached template,
# in a running xymond_rrd and after a restart. Without that, rrdtool
# refuses every update naming a dataset the file lacks, and the whole
# file freezes. Feeds real conn statuses to the built xymond_rrd.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"
command -v rrdtool >/dev/null 2>&1 || skip "no rrdtool command to inspect the files with"

work=$(mktempdir)
register_cleanup "rm -rf '$work'"
f="$work/rrd/testhost/tcp.conn-smoke.rrd"

conn_msg() {	# conn_msg <ts> <samples> <N>
	printf '@@status|%s|127.0.0.1|origin|testhost|conn|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$1" $(($1+1800)) "$1" "$1"
	printf '&green 10.0.0.1 is alive (2.00 ms) samples=%s loss=0/%s\n@@\n' "$2" "$3"
}
run_rrd() {	# feed stdin to one xymond_rrd process
	env XYMONHOME="$work" XYMONTMP="$work/tmp" PINGCOLUMN=conn \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
}
info_val() {	# info_val <key> - one value from rrdtool info
	rrdtool info "$f" | sed -n "s/^$1 = //p"
}
ts=$(date +%s)

# A running writer: three samples, then five, then five again.
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
{
	conn_msg "$ts" 0.001,0.002,0.003 3
	conn_msg $((ts+60)) 0.001,0.002,0.003,0.004,0.005 5
	conn_msg $((ts+120)) 0.001,0.002,0.003,0.004,0.005 5
} | run_rrd
assert_contains "ds[ping5].type" "$(rrdtool info "$f")" \
	"running writer: a raised sample count must add the new ping datasets"
assert_equal "$((ts+120))" "$(info_val last_update)" \
	"running writer: the smoke file must keep updating after the sample count is raised"

# A restart: the file was created with three samples, a new process sees five.
rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
conn_msg "$ts" 0.001,0.002,0.003 3 | run_rrd
conn_msg $((ts+60)) 0.001,0.002,0.003,0.004,0.005 5 | run_rrd
assert_equal "$((ts+60))" "$(info_val last_update)" \
	"restarted writer: a file created with fewer samples must take the larger update"
assert_equal '"0.005000"' "$(info_val 'ds\[ping5\]\.last_ds')" \
	"restarted writer: the new ping dataset receives its sample"

pass "a smoke file keeps updating when its host's sample count is raised"
