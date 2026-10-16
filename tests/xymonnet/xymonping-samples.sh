#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/xymonping-samples.sh
#
# Pins xymonping --samples=N against 127.0.0.1: one output line carrying N
# round-trip times and the loss count, and the pings to one host spaced
# 1000 ms apart by default (fping's -p default, which SmokePing measures
# with), not squeezed into the reply timeout. --timeout=1 makes the two
# distinguishable: a timeout-derived spacing would send all four pings
# within one second, the 1000 ms default needs three. Also pins that --max-pps
# still limits the rate, and that a refused ping counts as lost.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/assert.sh
. "$here/../lib/assert.sh"

require_bin XYMONPING xymonnet/xymonping

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

run() {
	local rc=0
	"$XYMONPING" "$@" 127.0.0.1 >"$work/out" 2>"$work/err" || rc=$?
	if [ "$rc" != 0 ] && grep -q -E 'Cannot (get|open) [A-Za-z0-9 ]*socket: (Operation not permitted|Permission denied)' "$work/err"; then
		skip "no unprivileged ICMP socket (net.ipv4.ping_group_range) and not root"
	fi
	[ "$rc" = 0 ] || { cat "$work/err" >&2; fail "xymonping $* exited $rc"; }
}

start=$SECONDS
run --samples=4 --timeout=1
elapsed=$((SECONDS - start))
line=$(first_line "$(cat "$work/out")")
assert_match '^127\.0\.0\.1 is alive \([^)]*\) samples=[0-9.]+,[0-9.]+,[0-9.]+,[0-9.]+ loss=0/4$' "$line" \
	"--samples=4 reports four round-trip times and no loss"
[ "$elapsed" -ge 3 ] \
	|| fail "four pings took ${elapsed}s: expected at least 3s, the default spacing is 1000 ms"

start=$SECONDS
run --samples=4 --timeout=1 --per-host-interval=0
elapsed=$((SECONDS - start))
[ "$elapsed" -lt 3 ] \
	|| fail "--per-host-interval=0 took ${elapsed}s: the option does not set the spacing"

# --max-pps holds with --samples too: four pings at one per second need
# three seconds even with no per-host spacing.
start=$SECONDS
run --samples=4 --timeout=1 --per-host-interval=0 --max-pps=1
elapsed=$((SECONDS - start))
[ "$elapsed" -ge 3 ] \
	|| fail "--max-pps=1 sent four pings in ${elapsed}s: --samples does not honour it"

# A host whose every send is refused (the broadcast address, without
# SO_BROADCAST) counts each ping as lost.
rc=0
"$XYMONPING" --samples=3 --per-host-interval=0 --timeout=1 255.255.255.255 >"$work/out" 2>"$work/err" || rc=$?
[ "$rc" = 0 ] || { cat "$work/err" >&2; fail "xymonping --samples=3 255.255.255.255 exited $rc"; }
if grep -q 'Failed to send ICMP packet' "$work/err"; then
	assert_equal "255.255.255.255 is unreachable loss=3/3" "$(first_line "$(cat "$work/out")")" \
		"three refused pings are three lost ones"
fi

pass "xymonping --samples=4 reports four samples and the loss, spaced 1000 ms apart unless --per-host-interval says otherwise, within --max-pps"
