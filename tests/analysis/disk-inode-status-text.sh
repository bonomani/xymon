#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/analysis/disk-inode-status-text.sh
#
# The disk and inode statuses that xymond_client builds from a client's
# filesystem tables, pinned to the text they had before the two reports
# became one function judging metric samples (lib/metric.c). Each case in
# fs-status-text/ is a client report (NAME.msg), the analysis.cfg it is
# judged under (NAME.cfg) and the disk and inode statuses the report
# produced on the tree before that change (NAME.expected), recorded from
# "xymond_client --local" and kept byte for byte.
#
# The cases cover what the two reports do differently or by exception:
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

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_CLIENT xymond/xymond_client

here=$(dirname "$0")
cases=$here/fs-status-text
work=$(mktempdir)
mkdir -p "$work/home"

# The disk and inode statuses of a local-mode run, without the combo header
# that precedes the first status and its padding. The status line carries
# the alert group as "status/group:NAME", so the first word is matched up
# to its space.
statuses() {
	sed -n '/^ *status/,$p' | sed 's/^ *//' |
		awk '/^status(\/[^ ]*)? /{keep = ($0 ~ /\.(disk|inode) /)} keep'
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
		fail "the disk/inode status text for $name changed:
$(diff "$expected" "$work/$name.got" || true)"
	fi
	n=$((n + 1))
done

[ "$n" -gt 0 ] || fail "no cases found in $cases"

pass "the disk and inode statuses are unchanged on $n recorded client reports"
