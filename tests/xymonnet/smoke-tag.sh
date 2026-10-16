#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/smoke-tag.sh
#
# Pins how xymonnet pings a host carrying the hosts.cfg "smoke" tag: through
# $FPING with "--samples=N" when it is xymonping, or "-C N -q" when it is
# fping, N from the tag or else $SMOKEPINGSAMPLES, while an untagged host is
# pinged as before, and the samples= and loss= fields reach the conn status.
# $FPING is a stub that records its arguments and answers in the format of
# the pinger it is named after, so no ICMP is sent.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMONNET xymonnet/xymonnet

root=$(find_root)
work=$(mktempdir)
register_cleanup "rm -rf '$work'"

mkdir -p "$work/home/etc" "$work/tmp" "$work/calls"
cp "$root/xymonnet/protocols.cfg" "$work/home/etc/protocols.cfg"

# One record per call, "ARGS|IP IP ...", in a file of its own: xymonnet runs
# one $FPING per sample count, concurrently.
cat > "$work/xymonping" <<'STUB'
#!/bin/sh
args="$*"
ips=""
while read -r ip rest; do
	ips="$ips$ip "
	case $args in
	*--samples=*) echo "$ip is alive (1.00 ms) samples=0.001000,0.002000 loss=0/2" ;;
	*) echo "$ip is alive (1.00 ms)" ;;
	esac
done
printf '%s|%s\n' "$args" "$ips" > "$(dirname "$0")/calls/$$"
STUB
chmod 755 "$work/xymonping"

cat > "$work/home/etc/hosts.cfg" <<'HOSTS'
127.0.0.1 counted # smoke:3
127.0.0.2 defaulted # smoke
127.0.0.3 plain #
HOSTS

XYMONHOME="$work/home" XYMONTMP="$work/tmp" FPING="$work/xymonping" FPINGOPTS="-Ae" \
	SMOKEPINGSAMPLES=5 "$XYMONNET" --no-update --timeout=2 </dev/null >"$work/out" 2>"$work/err" \
	|| { cat "$work/err" >&2; fail "xymonnet exited non-zero"; }

calls=$(cat "$work"/calls/*)
assert_contains "-Ae --samples=3|127.0.0.1 " "$calls" "a host tagged smoke:3 is pinged with --samples=3"
assert_contains "-Ae --samples=5|127.0.0.2 " "$calls" "a bare smoke tag takes SMOKEPINGSAMPLES"
assert_contains "-Ae|127.0.0.3 " "$calls" "an untagged host is pinged without --samples"

status=$(cat "$work/out")
assert_contains "127.0.0.1 is alive (1.00 ms) samples=0.001000,0.002000 loss=0/2" "$status" \
	"the samples reach the conn status"

# fping has no --samples: a smoke host is pinged in its count mode,
# "-C N -q", whose summary fping prints on stderr in milliseconds with
# "-" for a lost ping. xymonnet turns it into xymonping's line, so the
# status - and the RRD written from it - is the same with either pinger.
cat > "$work/fping" <<'STUB'
args="$*"
ips=""
while read -r ip rest; do
	ips="$ips$ip "
	case $args in
	*-C*) echo "$ip : 1.000 - 2.000" >&2 ;;
	*) echo "$ip is alive (1.00 ms)" ;;
	esac
done
echo "ICMP Host Unreachable from 10.9.9.9 for ICMP Echo sent to 10.0.0.1" >&2
printf '%s|%s\n' "$args" "$ips" > "$(dirname "$0")/fcalls/$$"
STUB
chmod 755 "$work/fping"
mkdir -p "$work/fcalls"

XYMONHOME="$work/home" XYMONTMP="$work/tmp" FPING="$work/fping" FPINGOPTS="-Ae" \
	SMOKEPINGSAMPLES=5 "$XYMONNET" --no-update --timeout=2 </dev/null >"$work/fout" 2>"$work/ferr" \
	|| { cat "$work/ferr" >&2; fail "xymonnet exited non-zero with fping"; }

fcalls=$(cat "$work"/fcalls/*)
assert_contains "-Ae -C 3 -q|127.0.0.1 " "$fcalls" "with fping, a host tagged smoke:3 is pinged with -C 3 -q"
assert_contains "-Ae -C 5 -q|127.0.0.2 " "$fcalls" "with fping, a bare smoke tag takes SMOKEPINGSAMPLES"
assert_contains "-Ae|127.0.0.3 " "$fcalls" "with fping, an untagged host is pinged as before"
assert_contains "127.0.0.1 is alive (1.500 ms) samples=0.001000,0.002000 loss=1/3" "$(cat "$work/fout")" \
	"fping's count-mode summary reaches the conn status as xymonping's samples line"

pass "xymonnet pings smoke-tagged hosts with N samples (the tag's N, else SMOKEPINGSAMPLES) through xymonping or fping, others as before, and reports the samples"
