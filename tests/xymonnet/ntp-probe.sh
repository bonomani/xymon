#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/ntp-probe.sh
#
# Compiles and runs ntp-probe-harness.c (the real xymonnet/ntpprobe.c against a
# stub strbuffer) and fails if it does. See the harness for the regressions it
# pins (the NTP offset formula, the stray/spoofed/unsynchronised/KoD rejections,
# and that the success line carries the offset where parse_ntp_offset() reads it). No
# socket is opened; only the pure packet-build and validation code runs.

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

harness="$work/ntp-probe"
if ! "$CC" -g -O1 -fsanitize=address,undefined -o "$harness" \
		"$here/ntp-probe-harness.c" 2>"$work/cc-asan.log"; then
	"$CC" -g -O1 -o "$harness" "$here/ntp-probe-harness.c" 2>"$work/cc.log" \
		|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }
fi

if ! ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}" \
		"$harness" >"$work/run.log" 2>&1; then
	cat "$work/run.log" >&2
	fail "internal SNTP probe is broken (see output above)"
fi

pass "internal SNTP probe: offset formula and stray/spoofed/unsynchronised/KoD rejections hold"
