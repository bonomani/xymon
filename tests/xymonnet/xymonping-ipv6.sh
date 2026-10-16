#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/xymonping-ipv6.sh
#
# Pins that xymonping pings an IPv6 address: ::1 answers like any host, with
# and without --samples, and a link-local address given with its %iface on the
# command line is sent on that interface -- without the scope the kernel
# refuses the send with "Invalid argument" -- and reported as it was given.
# Skips where the host has no route to ::1, the only environment it cannot
# check; a socket that will not open is a failure.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/assert.sh
. "$here/../lib/assert.sh"

require_bin XYMONPING xymonnet/xymonping

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ping6() {
	local rc=0
	"$XYMONPING" "$@" </dev/null >"$work/out" 2>"$work/err" || rc=$?
	if grep -q -E 'Cannot (get|open) [A-Za-z0-9 ]*socket: (Operation not permitted|Permission denied)' "$work/err"; then
		skip "no unprivileged ICMPv6 socket and not root"
	fi
	if grep -q -E 'Network is unreachable|Cannot assign requested address' "$work/err" \
			&& ! grep -q '%' <<<"$*"; then
		skip "no IPv6 loopback on this host"
	fi
	[ "$rc" = 0 ] || { cat "$work/err" >&2; fail "xymonping $* exited $rc"; }
}

ping6 --samples=2 --per-host-interval=0 ::1
assert_match '^::1 is alive \([^)]*\) samples=[0-9.]+,[0-9.]+ loss=0/2$' "$(first_line "$(cat "$work/out")")" \
	"--samples=2 pings ::1"

ping6 --retries=0 --timeout=1 ::1
assert_match '^::1 is alive \([0-9.]+ (usec|ms)\)$' "$(first_line "$(cat "$work/out")")" \
	"without --samples ::1 is pinged too"

# The loopback has no link-local address, so the ping itself fails; what
# matters is that the address is taken from the command line and sent with
# its scope.
for ifname in lo lo0; do
	ping6 --samples=1 --per-host-interval=0 --timeout=1 "fe80::1%$ifname"
	grep -q 'unknown interface' "$work/err" && continue
	assert_match "^fe80::1%$ifname is (alive|unreachable)" "$(first_line "$(cat "$work/out")")" \
		"fe80::1%$ifname on the command line is pinged, and reported as given"
	! grep -q 'Invalid argument' "$work/err" \
		|| fail "fe80::1%$ifname was sent without its interface scope: $(cat "$work/err")"
	pass "xymonping pings ::1 with and without --samples, and sends fe80::1%$ifname on that interface"
done

pass_partial "xymonping pings ::1 with and without --samples" \
	"no loopback named lo or lo0 to scope fe80::1 to"
