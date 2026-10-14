#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/libxymon/smokeping.sh
#
# Compiles smokeping-harness.c with lib/smokeping.c, the code xymond_rrd
# uses to turn xymonping --samples output into an RRD update, and fails if
# any check does. See the harness for what it pins.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/assert.sh
. "$here/../lib/assert.sh"

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

root="$here/../.."
harness="$work/smokeping"
if ! asan_usable || ! "$CC" -g -O1 -fsanitize=address,undefined -iquote "$root/include" -o "$harness" \
		"$here/smokeping-harness.c" "$root/lib/smokeping.c" -lm 2>"$work/cc-asan.log"; then
	"$CC" -g -O1 -iquote "$root/include" -o "$harness" "$here/smokeping-harness.c" \
		"$root/lib/smokeping.c" -lm 2>"$work/cc.log" \
		|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }
fi

rc=0
ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}" \
	"$harness" >"$work/run.log" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
	cat "$work/run.log" >&2
	fail "lib/smokeping.c does not parse or shape samples as pinned (see output above)"
fi

pass "lib/smokeping.c parses samples and loss, takes the median, and sizes the RRD from the sample count"
