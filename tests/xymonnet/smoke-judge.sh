#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymonnet/smoke-judge.sh
#
# Pins how xymonnet judges a smoke host's link in the "smoke" column:
# loss over the last hour once 100 pings are in, a run losing half its
# pings yellow at once and red twice in a row, a host that does not
# answer blue ("not judged") and left out of the hour, conn left green
# by loss, the verdict added to the ping line for xymond_rrd, and the
# column dropped when the smoke tag goes. $FPING is a stub speaking
# fping's count mode, so no ICMP is sent; each run is one xymonnet run.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMONNET xymonnet/xymonnet

root=$(find_root)
work=$(mktempdir)
register_cleanup "rm -rf '$work'"
mkdir -p "$work/home/etc" "$work/tmp"
cp "$root/xymonnet/protocols.cfg" "$work/home/etc/protocols.cfg"

# 10.0.0.1 loses as many of its pings as $work/lost says; 10.0.0.2 never answers.
cat > "$work/fping" <<'STUB'
args="$*"
n=$(echo "$args" | sed -n 's/.*-C \([0-9]*\).*/\1/p')
lost=$(cat "$(dirname "$0")/lost")
while read -r ip rest; do
	case $args in
	*-C*)
		line=""; i=0
		while [ "$i" -lt "$n" ]; do
			if [ "$ip" = 10.0.0.2 ] || [ "$i" -lt "$lost" ]; then line="$line -"; else line="$line 20.$i"; fi
			i=$((i + 1))
		done
		echo "$ip :$line" >&2 ;;
	*) echo "$ip is alive (1.00 ms)" ;;
	esac
done
STUB
chmod 755 "$work/fping"

hosts() { printf '10.0.0.1 gw # %s\n10.0.0.2 deadhost # smoke:20\n' "$1" > "$work/home/etc/hosts.cfg"; }
run() {	# run <lost>: one xymonnet run, its output in $work/out
	echo "$1" > "$work/lost"
	XYMONHOME="$work/home" XYMONTMP="$work/tmp" FPING="$work/fping" FPINGOPTS="-Ae" \
		"$XYMONNET" --no-update --timeout=2 </dev/null >"$work/out" 2>"$work/err" \
		|| { cat "$work/err" >&2; fail "xymonnet exited non-zero"; }
}
status_line() { grep -a "^status+[0-9]* $1 " "$work/out" || true; }

hosts "smoke:20"
run 0
assert_match 'gw\.smoke green .*collecting: 20 pings in the last hour, judged from 100' "$(status_line gw.smoke)" \
	"a first run is collected, not judged"

run 10
assert_match 'gw\.smoke yellow .*10 of 20 pings lost in the last run' "$(status_line gw.smoke)" \
	"a run losing half its pings is yellow at once"
assert_match 'gw\.conn green' "$(status_line gw.conn)" "loss never colours conn"

run 10
assert_match 'gw\.smoke red ' "$(status_line gw.smoke)" "two such runs in a row are red"

run 1; run 1; run 1
assert_match 'gw\.smoke red .*packet loss 19\.2% over the last hour \(critical at 10%\)' "$(status_line gw.smoke)" \
	"once 100 pings are in, the hour is judged: 23 of 120 lost is red"
assert_contains "23/120 (19.2%)" "$(cat "$work/out")" "the status shows the hour's count"
assert_contains "loss=1/20 losshour=0.191667 lossstate=2 losswarn=0.030000 losscrit=0.100000" "$(cat "$work/out")" \
	"the verdict follows the samples on the ping line, for xymond_rrd"

assert_match 'deadhost\.smoke blue .*not judged' "$(status_line deadhost.smoke)" \
	"a host that does not answer is blue, not judged"
assert_not_contains "deadhost" "$(cat "$work/tmp"/smoke.*.status | grep -v '^deadhost 0 0$' || true)" \
	"its runs without a reply stay out of the hour"

hosts ""
run 0
assert_contains "drop gw smoke" "$(cat "$work/out")" "removing the smoke tag drops the column"
assert_not_contains "gw.smoke" "$(cat "$work/out")" "and no smoke status is sent for it"

pass "xymonnet judges a smoke host's loss over the hour in its own column, blue when it does not answer, dropped with its tag"
