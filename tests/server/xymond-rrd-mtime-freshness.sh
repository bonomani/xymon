#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymond-rrd-mtime-freshness.sh
#
# showgraph drops an RRD from a graph when "nostale" is set and the file's
# timestamp is more than a day old (web/showgraph.c), and every graph link
# Xymon generates carries that flag. The timestamp is therefore part of the
# writer's contract: it must move whenever xymond_rrd writes a reading, or the
# graph goes empty a day later with nothing logged anywhere.
#
# do_rrd.c stamps the file explicitly because RRDtool writes through mmap,
# where the kernel does not move the timestamp by itself. That stamp used to
# be compiled for Linux only, although nothing about mmap is Linux-specific.
#
# This pins the contract rather than the workaround, in both directions: a
# written RRD must come out newer than a marker taken before the write, and an
# RRD whose reading RRDtool rejected must not. What each case actually catches
# was measured rather than assumed:
#
#   - the accepted-reading case does NOT discriminate on Linux with librrd
#     1.7.2, where the timestamp moves on its own; it is there for macOS, where
#     after two hours of updates "rrdtool last" reported 02:00 while the file's
#     mtime was still 00:02, and for RRDtool versions that behave that way.
#   - the rejected-reading case discriminates everywhere, including Linux:
#     nothing but the explicit stamp can move the timestamp when RRDtool has
#     declined to write.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"

work=$(mktempdir)
mkdir -p "$work/rrd" "$work/tmp"
ts=$(date +%s)

status_msg() {  # status_msg <msg-timestamp>
	printf '@@status|%s|127.0.0.1|origin|testhost|disk|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$1" $(($1+1800)) "$1" "$1"
	printf 'disk report\n'
	printf '/dev/sda1 1000000 400000 600000 40%% /\n'
	printf '@@\n'
}

run_worker() {  # run_worker <msg-timestamp>
	status_msg "$1" | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
}

# --no-cache so the reading is written on the spot: with the cache on nothing
# reaches the file until a flush, and the test would be timing the flush.
run_worker "$ts"
rrd=$(find "$work/rrd" -name '*.rrd' | head -1)
[ -n "$rrd" ] || fail "xymond_rrd created no RRD from a disk status message"

# Marker taken AFTER creation, so only the second write can make the file
# newer. Sleep past the coarsest timestamp granularity in play (1s on HFS+).
touch "$work/marker"
sleep 1.1
run_worker $((ts + 300))

[ -n "$(find "$rrd" -newer "$work/marker")" ] \
	|| fail "the RRD's timestamp did not move when xymond_rrd wrote a new reading -- showgraph's 'nostale' filter drops it from every graph once it is a day old"

# ---- and only then --------------------------------------------------------
# The other half of the contract. RRDtool refuses a reading that is not newer
# than the last one and leaves the file untouched; stamping regardless would
# make an RRD that has stopped being written look fresh to the same 'nostale'
# check, which is worse than the staleness the stamp is there to prevent.
# Found by SoundGoof reviewing PR #349, reproduced on FreeBSD and here; the
# success gate itself is the substance of PR #82.
touch "$work/marker2"
sleep 1.1
run_worker "$ts"   # older than the reading already stored: rejected

[ -z "$(find "$rrd" -newer "$work/marker2")" ] \
	|| fail "the RRD's timestamp moved for a reading RRDtool rejected -- an RRD that has stopped being written would keep passing showgraph's 'nostale' filter"

pass "a written RRD comes out newer than a marker taken before the write, and a rejected one does not"
