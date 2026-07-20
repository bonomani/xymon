#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/rrd-long-legacy-name.sh
#
# A file name keeps its exact form up to the file-name limit: names from
# 205 to 255 characters existed before the block writer, and shortening
# them would start an empty file beside the one holding the history. So
# the disk handler's legacy file of that length is renamed to the encoded
# name - history kept - rather than orphaned, and only a name too long to
# create at all is shortened, to its first 205 characters plus an md5 of
# the rest. Driven through the built xymond_rrd and the disk handler.
set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"
command -v rrdtool >/dev/null 2>&1 || skip "rrdtool CLI not available"

work=$(mktempdir)

feed_disk() {	# feed_disk <mount point> -- one disk status with that mount
	local ts; ts=$(date +%s)
	mkdir -p "$work/rrd" "$work/tmp"
	{
		printf '@@status|%s|127.0.0.1|origin|testhost|disk|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$ts" $((ts+1800)) "$ts" "$ts"
		printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
		printf '/dev/sda1 100 50 50 50%% %s\n' "$1"
		printf '@@\n'
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
	ls "$work/rrd/testhost" 2>/dev/null || true
}

# A 229-character legacy disk file with a sample in it, as an older
# Xymon left it. The update renames it to the encoded name (232
# characters, under the limit): the same file, its history with it.
long=$(printf 'a%.0s' $(seq 1 220))
rm -rf "$work/rrd"; mkdir -p "$work/rrd/testhost"
legacy="$work/rrd/testhost/disk,$long.rrd"
rrdtool create "$legacy" --start "$(($(date +%s) - 3600))" --step 300 \
	DS:pct:GAUGE:600:0:100 DS:used:GAUGE:600:0:U RRA:AVERAGE:0.5:1:576
# Two samples, so a whole step holds a known value (one update alone
# leaves its step unknown).
t0=$(( ($(date +%s) - 1800) / 300 * 300 ))
rrdtool update "$legacy" "$t0:40:400" "$((t0+300)):40:400" "$((t0+600)):40:400"
out=$(feed_disk "/$long")
assert_contains "disk.%2F$long.rrd" "$out" "the long legacy file was not carried to its encoded name"
case $out in *_*.rrd*) fail "a file name under the limit was shortened: $out" ;; esac
assert_not_contains "disk,$long.rrd" "$out" "the legacy file was left behind beside a new one"
hist=$(rrdtool fetch "$work/rrd/testhost/disk.%2F$long.rrd" AVERAGE -s "$((t0-300))" -e "$((t0+600))")
grep -q 'e+01' <<<"$hist" \
	|| fail "the renamed file lost the legacy file's history: $hist"

# A mount whose encoded name is over the limit is shortened.
toolong=$(printf 'b%.0s' $(seq 1 300))
rm -rf "$work/rrd"
out=$(feed_disk "/$toolong")
[ -n "$out" ] || fail "a file name over the limit created no file at all"
[ "${#out}" -le 255 ] || fail "a file name over the limit was not shortened (${#out} characters)"
case $out in disk.%2Fb*_*.rrd) ;; *) fail "the shortened name lost its prefix or its hash: $out" ;; esac

pass "RRD file names keep their exact form up to the file-name limit, and long legacy files keep their history"
