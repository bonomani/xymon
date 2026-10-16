#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/rrd/conn-smoke-usual.sh
#
# The shipped [conn-smoke] graph draws a smoke host's usual latency: the
# median at the same time of day on each of the last 7 days, with one
# standard deviation either side. Take the band's lines from
# graphs.cfg.DIST as shipped, give them a summary file whose median follows
# a daily pattern, and check what rrdtool computes: the usual value is the
# pattern's at this time of day - not the day's overall average, and not
# today's departure from it.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

command -v rrdtool >/dev/null 2>&1 || skip "rrdtool not installed"

here=$(cd "$(dirname "$0")" && pwd)
cfg="$here/../../xymond/etcfiles/graphs.cfg.DIST"
work=$(mktempdir)

# The band's definitions: every line of [conn-smoke] that reads the summary
# file or computes from what it read.
lines=$(sed -n '/^\[conn-smoke\]$/,/^\[/p' "$cfg" |
	grep -E '^[[:space:]]*(DEF:smed|CDEF:usual)' | sed 's/^[[:space:]]*//' || true)
[ -n "$lines" ] || fail "[conn-smoke] in graphs.cfg.DIST draws no usual band (DEF:smed, CDEF:usual...)"

# Nine days of 5-minute medians ending at the next step. Around this time
# of day the median is 20 ms; half a day away, 40 ms, so a day's average is
# 30 ms. The last three hours depart from it at 100 ms.
end=$(( ($(date +%s) / 300 + 1) * 300 ))
start=$((end - 9*86400))
f="$work/tcp.conn-smoke-summary.rrd"
rrdtool create "$f" --start $((start - 300)) -s 300 \
	DS:median:GAUGE:600:0:U RRA:AVERAGE:0.5:1:28800
t=$start
batch=()
while [ "$t" -le "$end" ]; do
	phase=$(( ((end - t) % 86400 + 21600) % 86400 ))
	if [ $((end - t)) -lt 10800 ]; then v=0.100
	elif [ "$phase" -lt 43200 ]; then v=0.020
	else v=0.040
	fi
	batch+=("$t:$v")
	if [ "${#batch[@]}" -ge 200 ]; then rrdtool update "$f" "${batch[@]}"; batch=(); fi
	t=$((t + 300))
done
[ "${#batch[@]}" -eq 0 ] || rrdtool update "$f" "${batch[@]}"

defs=()
while IFS= read -r l; do defs+=("${l//tcp.conn-smoke-summary.rrd/$f}"); done <<<"$lines"
out=$(rrdtool graph /dev/null -s $((end - 3600)) -e "$end" "${defs[@]}" \
	'VDEF:u=usual,LAST' 'VDEF:sd=usualsd,LAST' 'VDEF:m=smed,LAST' \
	'PRINT:u:%.4lf' 'PRINT:sd:%.4lf' 'PRINT:m:%.4lf' 2>&1 | tail -n +2 | tr '\n' ' ')

assert_equal "0.0200 0.0000 0.1000 " "$out" \
	"usual = the median at this time of day on the last 7 days (20 ms), not the day's average (30 ms) or today's (100 ms); deviation 0; median now 100 ms"

pass "[conn-smoke] draws the usual latency for the time of day from the last 7 days"
