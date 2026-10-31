#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/analysis/client-status-text.sh
#
# The statuses xymond_client builds from a client report, pinned to the text
# they had before the analysers were moved onto metric samples judged by
# lib/metric.c. Each case in status-text/ is a client report (NAME.msg), the
# analysis.cfg it is judged under (NAME.cfg) and every status the report
# produced on the tree before that change (NAME.expected), recorded from
# "xymond_client --local" and kept byte for byte.
#
# The cases cover what each analyser does differently or by exception.
# Disk and inode:
#   - linux-defaults: the built-in levels, one mount per colour, in both tables
#   - darwin-unreachable: the client's unavailable-mount marker ("-" sizes,
#     100%) in both tables, and an all-dash row without the marker
#   - solaris-inode-empty: an empty inode table is a green inode status
#   - aix-rules-abs: AIX headers; levels in units free beside levels in
#     percent; a mount that trips the warning level only
#   - rules-ignore-counts-group: IGNORE drops the row from the table; a
#     filesystem that must exist and one that must not; GROUP= on the
#     tripping rule puts the group in the status line
#   - missing-headers: a table without the expected column names
# Memory:
#   - memory-linux-defaults: new-style free(1), built-in levels
#   - memory-linux-rules: old-style free(1) with -/+ buffers/cache; MEMPHYS,
#     MEMACT and MEMSWAP rules, one row exactly one point above its level
#   - memory-linux-invalid: swap used above swap total is invalid data
#   - memory-linux-zero: a zero total is "detection FAILED"
#   - memory-darwin: vm_stat page counters and sysctl swap

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_CLIENT xymond/xymond_client

here=$(dirname "$0")
cases=$here/status-text
work=$(mktempdir)
mkdir -p "$work/home"

# Everything from the first status of a local-mode run, without the combo
# header that precedes it and its padding.
statuses() {
	sed -n '/^ *status/,$p' | sed 's/^ *//'
}

n=0
for msg in "$cases"/*.msg; do
	name=$(basename "$msg" .msg)
	expected=$cases/$name.expected
	[ -f "$expected" ] || fail "$name has no expected output beside it"

	env XYMONHOME="$work/home" XYMONTMP="$work" \
		"$XYMOND_CLIENT" --local --no-update --config="$cases/$name.cfg" \
		<"$msg" 2>"$work/$name.stderr" | statuses >"$work/$name.got" \
		|| fail "xymond_client exited non-zero on $name: $(cat "$work/$name.stderr")"

	if ! cmp -s "$expected" "$work/$name.got"; then
		fail "the status text for $name changed:
$(diff "$expected" "$work/$name.got" || true)"
	fi
	n=$((n + 1))
done

[ "$n" -gt 0 ] || fail "no cases found in $cases"

pass "the client statuses are unchanged on $n recorded client reports"
