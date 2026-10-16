#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/rrd-long-legacy-name.sh
#
# A legacy handler's RRD file name keeps its exact form up to the file-name
# limit. Names from 205 to 255 characters existed before the block writer, and
# shortening them would start an empty file beside the one holding the
# history. Only a name too long to create at all is shortened, to its first
# 205 characters plus an md5 of the rest. Driven through the built xymond_rrd
# and the built-in disk handler.
set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"

work=$(mktempdir)

feed_disk() {	# feed_disk <mount point> -- one disk status with that mount
	local ts; ts=$(date +%s)
	rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
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

long=$(printf 'a%.0s' $(seq 1 220))
out=$(feed_disk "/$long")
assert_contains "disk,$long.rrd" "$out" \
	"a 229-character legacy file name was not kept as it is"
case $out in *_*.rrd*) fail "a file name under the limit was shortened: $out" ;; esac

toolong=$(printf 'b%.0s' $(seq 1 300))
out=$(feed_disk "/$toolong")
[ -n "$out" ] || fail "a file name over the limit created no file at all"
[ "${#out}" -le 255 ] || fail "a file name over the limit was not shortened (${#out} characters)"
case $out in disk,b*_*.rrd) ;; *) fail "the shortened name lost its prefix or its hash: $out" ;; esac

pass "legacy RRD file names keep their exact form up to the file-name limit"
