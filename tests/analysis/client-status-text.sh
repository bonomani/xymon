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
#     MEMACT and MEMSWAP rules, one row exactly at its level, which does not trip
#   - memory-linux-invalid: swap used above swap total is invalid data
#   - memory-linux-zero: a zero total is "detection FAILED"
#   - memory-darwin: vm_stat page counters and sysctl swap
# Cpu:
#   - cpu-linux-defaults: built-in load levels, a long uptime, users and
#     processes counted from [who] and [ps]
#   - cpu-linux-rules: LOAD with the load exactly at the yellow level, which
#     does not trip; UP with a reboot inside the recent limit, in red
#   - cpu-freebsd-ancient: "load averages:" without commas, load above the
#     red level; UP with an uptime beyond the ancient limit
#   - cpu-linux-clock: a [clock] epoch far from the server's: CLOCK trips
# Procs, ports and services, the counting analysers:
#   - procs-linux-rules: PROC with a count inside, above and below its limits,
#     a pattern that matches more than one command, TRACK= and TEXT=
#   - procs-linux-noheader: a ps table without the command heading
#   - ports-linux-rules: PORT on local address and state, inside, above and
#     below its limits, with TEXT= and TRACK=
#   - svcs-bbwin-rules: SVC on a Windows service list: a service as wanted,
#     one in the wrong state, one absent

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_CLIENT xymond/xymond_client

here=$(dirname "$0")
cases=$here/status-text
work=$(mktempdir)
mkdir -p "$work/home"

# Everything from the first status of a local-mode run, without the combo
# header that precedes it and its padding. The cpu status prints the client's
# clock offset from the server's clock at the time of the run, which no
# recording can pin; the number is replaced by N on both sides.
statuses() {
	sed -n '/^ *status/,$p' | sed 's/^ *//' |
		sed -E 's/(System clock is )-?[0-9]+( seconds off)/\1N\2/'
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
