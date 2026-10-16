#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/rrd/conn-smoke.sh
#
# Compiles and runs conn-smoke-harness.c, which drives the real do_net.c and
# lib/smokeping.c for the "conn" test with the RRD plumbing stubbed. Fails if
# a status with xymonping's samples= and loss= fields does not update
# tcp.conn-smoke.rrd as pinned, if a plain one updates more than tcp.conn.rrd,
# or if do_net_rrd stops returning the tcp.conn.rrd update's result.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/assert.sh
. "$here/../lib/assert.sh"

require_cc

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

harness="$work/conn-smoke"
if ! asan_usable || ! "$CC" -g -O1 -fsanitize=address,undefined -iquote "$here/../../include" \
		-o "$harness" "$here/conn-smoke-harness.c" -lm 2>"$work/cc-asan.log"; then
	"$CC" -g -O1 -iquote "$here/../../include" -o "$harness" "$here/conn-smoke-harness.c" -lm \
		2>"$work/cc.log" || { cat "$work/cc.log" >&2; fail "harness does not compile"; }
fi

if ! ASAN_OPTIONS="detect_leaks=0${ASAN_OPTIONS:+:$ASAN_OPTIONS}" \
		"$harness" >"$work/run.log" 2>&1; then
	cat "$work/run.log" >&2
	fail "do_net.c does not record conn samples as pinned (see output above)"
fi

pass "do_net.c writes the samples to tcp.conn-smoke.rrd and the median, loss and verdict to tcp.conn-smoke-summary.rrd beside tcp.conn.rrd, and returns the tcp.conn.rrd update's result"
