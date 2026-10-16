#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymond-rrd-gdef-warning.sh
#
# A METRICS block stores its files as <block>.<instance>.rrd, and a
# hand-written graphs.cfg section of the same name wins over the graph
# synthesized for it. When that section draws other files - fixed ones, as
# the shipped [la] draws la.rrd, or an FNPATTERN the block's files do not
# match - the data is stored and never shown. xymond_rrd must say so in its
# log, once per block name, and stay silent when the section does draw the
# block's files, when it only adjusts a synthesized graph, or when there is
# none.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"

work=$(mktempdir)
mkdir -p "$work/etc"
printf '[]\n\tRRA:AVERAGE:0.5:1:576\n' > "$work/etc/rrddefinitions.cfg"

feed() {	# feed [count]: send the block in one or more statuses; the log goes to $work/log
	local n=${1:-1} i ts
	rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
	ts=$(date +%s)
	for i in $(seq 1 "$n"); do
		printf '@@status#%s|%s|127.0.0.1|origin|testhost|cpu|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$i" $((ts+i*300)) $((ts+i*300+1800)) $((ts+i*300)) $((ts+i*300))
		printf '<!--XYMON METRICS: la\nDS:load:GAUGE:600:U:U\n1min 1.5\n-->\nstatus text\n@@\n'
	done | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache >"$work/log" 2>&1
}
warnings() { grep -c "METRICS block 'la' is stored in la" "$work/log" || true; }

# The shipped kind: no FNPATTERN, DEFs naming a fixed file.
printf '[la]\n\tTITLE Load\n\tDEF:avg=la.rrd:la:AVERAGE\n\tLINE2:avg#00CC00:Load\n' > "$work/etc/graphs.cfg"
feed 3
assert_equal "1" "$(warnings)" "a section drawing a fixed file warns, once for three statuses"
[ -e "$work/rrd/testhost/la.1min.rrd" ] || fail "the block is still stored while it warns"

printf '[la]\n\tFNPATTERN ^la\\.(.+)\\.rrd\n\tDEF:avg@RRDIDX@=@RRDFN@:load:AVERAGE\n\tLINE2:avg@RRDIDX@#00CC00:@RRDPARAM@\n' > "$work/etc/graphs.cfg"
feed
assert_equal "0" "$(warnings)" "a section whose FNPATTERN matches the block's files is silent"

printf '[la]\n\tFNPATTERN ^la\\.rrd$\n\tDEF:avg=la.rrd:la:AVERAGE\n\tLINE2:avg#00CC00:Load\n' > "$work/etc/graphs.cfg"
feed
assert_equal "1" "$(warnings)" "an FNPATTERN the block's files do not match warns"

printf '[la]\n\tTHRESHOLDS OFF\n' > "$work/etc/graphs.cfg"
feed
assert_equal "0" "$(warnings)" "a section with no DEF lines stays synthesized and is silent"

printf '[other]\n\tDEF:x=other.rrd:x:AVERAGE\n\tLINE1:x#000000:x\n' > "$work/etc/graphs.cfg"
feed
assert_equal "0" "$(warnings)" "no section of the block's name is silent"

pass "xymond_rrd warns when a hand-written graph of a block's name does not draw its files"
