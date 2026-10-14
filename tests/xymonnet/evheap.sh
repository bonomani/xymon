#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/evheap.sh
#
# Compiles evheap-harness.c with xymonnet/evheap.c, the event queue
# xymonping schedules its probes on, and fails if any check does. See the
# harness for what it pins.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/assert.sh
. "$here/../lib/assert.sh"

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

src="$here/../../xymonnet"
harness="$work/evheap"
if ! asan_usable || ! "$CC" -g -O1 -fsanitize=address,undefined -iquote "$src" -o "$harness" \
		"$here/evheap-harness.c" "$src/evheap.c" 2>"$work/cc-asan.log"; then
	"$CC" -g -O1 -iquote "$src" -o "$harness" "$here/evheap-harness.c" "$src/evheap.c" \
		2>"$work/cc.log" || { cat "$work/cc.log" >&2; fail "harness does not compile"; }
fi

rc=0
"$harness" >"$work/run.log" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
	cat "$work/run.log" >&2
	fail "xymonnet/evheap.c does not keep its ordering contract (see output above)"
fi

pass "xymonnet/evheap.c pops events in deadline order across growth, ties and clear()"
