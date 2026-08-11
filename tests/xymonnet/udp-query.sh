#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/udp-query.sh
#
# Compiles and runs udp-query-harness.c (the real xymonnet/udpquery.c) over the
# loopback interface and fails if it does. See the harness for what it pins (the
# request/echo round-trip, the send/receive timestamps, and the timeout path).
# The harness exits 77 (skip) if the sandbox forbids the loopback socket setup.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if [ -r "$here/../lib/assert.sh" ]; then
	# shellcheck source=tests/lib/assert.sh
	. "$here/../lib/assert.sh"
else
	# This branch stands in for lib/assert.sh, so it owes a definition for
	# every helper the body below calls -- a missing one is not a skip, it is
	# `command not found` and rc=127 reported as a test failure. Keep it in
	# step with the calls, not with what assert.sh happens to export.
	fail()         { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
	skip()         { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
	skip_env()     { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
	pass()         { printf 'PASS: %s\n' "${*:-ok}"; exit 0; }
	have_tool()    { command -v "$1" >/dev/null 2>&1; }
	require_tool() { for t; do have_tool "$t" || skip_env "$t not available on this host"; done; }
	require_cc()   { CC=${CC:-cc}; require_tool "$CC"; }
fi

require_cc

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# udpquery.c #includes "config.h" for the HAVE_SYS_SELECT_H guard. The testsuite
# runs without a configure step, so stand in a minimal config.h on the include
# path; the loopback hosts that run this test all have <sys/select.h>.
printf '#define HAVE_SYS_SELECT_H 1\n' > "$work/config.h"

harness="$work/udp-query"
if ! "$CC" -g -O1 -fsanitize=address,undefined -I"$work" -o "$harness" \
		"$here/udp-query-harness.c" 2>"$work/cc-asan.log"; then
	"$CC" -g -O1 -I"$work" -o "$harness" "$here/udp-query-harness.c" 2>"$work/cc.log" \
		|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }
fi

rc=0
ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}" \
	"$harness" >"$work/run.log" 2>&1 || rc=$?
if [ "$rc" = 77 ]; then
	cat "$work/run.log" >&2
	skip_env "loopback UDP not available in this sandbox"
fi
if [ "$rc" != 0 ]; then
	cat "$work/run.log" >&2
	fail "udp_query transport is broken (see output above)"
fi

pass "udp_query keeps its round-trip, send/receive timestamps and timeout path over loopback"
