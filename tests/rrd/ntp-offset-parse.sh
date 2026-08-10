#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/rrd/ntp-offset-parse.sh
#
# Compiles and runs ntp-offset-parse-harness.c, which drives the real do_net.c +
# do_ntpstat.c offset parsing for the "ntp" test across both backends
# (built-in probe banner, ntpdate) and the do_ntpstat "offset=" path, with
# the RRD plumbing stubbed. Fails if any offset is parsed or scaled wrongly.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

if [ -r "$here/../lib/assert.sh" ]; then
	# shellcheck source=tests/lib/assert.sh
	. "$here/../lib/assert.sh"
else
	# Mirrors lib/assert.sh, including the stream: a verdict goes to stdout
	# next to the runner's line for this test.
	fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
	skip() { printf 'SKIP: %s\n' "$*"; exit 77; }
	have_tool() { command -v "$1" >/dev/null 2>&1; }
	require_tool() { for t; do have_tool "$t" || skip "$t not available on this host"; done; }
	require_cc() { CC=${CC:-cc}; require_tool "$CC"; }
fi

require_cc

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

harness="$work/ntp-offset-parse"
if ! "$CC" -g -O1 -fsanitize=address,undefined -o "$harness" \
		"$here/ntp-offset-parse-harness.c" 2>"$work/cc-asan.log"; then
	"$CC" -g -O1 -o "$harness" "$here/ntp-offset-parse-harness.c" 2>"$work/cc.log" \
		|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }
fi

if ! ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}" \
		"$harness" >"$work/run.log" 2>&1; then
	cat "$work/run.log" >&2
	fail "ntp offset parsing/scaling is broken (see output above)"
fi

pass "ntp offset parsing and scaling hold across both backends and the do_ntpstat path"
