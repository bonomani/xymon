#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/xymonping-retry.sh
#
# Pins that xymonping retries a host whose send fails outright: with
# --retries=2 it tries three times, a timeout apart, before reporting the host
# unreachable. 255.255.255.255 makes the failure deterministic -- a send to the
# broadcast address without SO_BROADCAST is refused (EACCES) on every try --
# so the test counts the refusals instead of timing anything. Also pins that
# empty input is a quiet success, as it always was, and that the defaults are
# fping's: four tries in about 4 seconds.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/assert.sh
. "$here/../lib/assert.sh"

require_bin XYMONPING xymonnet/xymonping

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rc=0
"$XYMONPING" --retries=2 --timeout=1 255.255.255.255 >"$work/out" 2>"$work/err" || rc=$?
if [ "$rc" != 0 ] && grep -q -E 'Cannot (get|open) [A-Za-z0-9 ]*socket: (Operation not permitted|Permission denied)' "$work/err"; then
	skip "no unprivileged ICMP socket for this user and not root"
fi
[ "$rc" = 0 ] || { cat "$work/err" >&2; fail "xymonping exited $rc"; }
refused=$(grep -c 'Failed to send ICMP packet' "$work/err" || :)
[ "$refused" != 0 ] || skip "this system sends to the broadcast address without SO_BROADCAST"
[ "$refused" = 3 ] \
	|| { cat "$work/err" >&2; fail "a refused send was tried $refused times with --retries=2, expected 3"; }
assert_equal "255.255.255.255 is unreachable" "$(first_line "$(cat "$work/out")")" \
	"a host whose every send fails is reported unreachable"

rc=0
"$XYMONPING" </dev/null >"$work/out" 2>"$work/err" || rc=$?
[ "$rc" = 0 ] || fail "empty input exited $rc, expected 0"
[ ! -s "$work/out" ] && [ ! -s "$work/err" ] || fail "empty input printed something"

# The defaults are fping's: 3 retries, a 500 ms first timeout, 1.5 times
# longer on each retry -- four tries, given up on after about 4 seconds.
start=$SECONDS
rc=0
"$XYMONPING" 255.255.255.255 >"$work/out" 2>"$work/err" || rc=$?
elapsed=$((SECONDS - start))
[ "$rc" = 0 ] || { cat "$work/err" >&2; fail "xymonping with its defaults exited $rc"; }
refused=$(grep -c 'Failed to send ICMP packet' "$work/err" || :)
[ "$refused" = 4 ] || fail "with the defaults a refused send was tried $refused times, expected 4 (--retries=3)"
[ "$elapsed" -ge 3 ] && [ "$elapsed" -le 6 ] \
	|| fail "with the defaults four tries took ${elapsed}s, expected about 4 (500+750+1125+1688 ms)"

pass "xymonping retries a host whose send fails, --retries times, with fping's default retries and backed-off timeouts, and takes empty input quietly"
