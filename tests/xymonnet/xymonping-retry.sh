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
# empty input is a quiet success, as it always was.

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

pass "xymonping retries a host whose send fails, --retries times, and takes empty input quietly"
