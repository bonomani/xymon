#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymongen-testgroup.sh
#
# A testgroup declared in test.cfg is one light on the overview matrix:
# xymongen hides the member tests' columns, adds a column named after the
# group, colours its light by the worst member, and links it to the group
# page (svcstatus.cgi?...SERVICE=<group>). A test outside any group keeps its
# own column. Driven through a real xymond and the built xymongen.
set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/xymond-daemon.sh
. "$(dirname "$0")/../lib/xymond-daemon.sh"

ROOT=$(find_root)
require_bin XYMOND xymond/xymond
require_bin XYMONCLIENT common/xymon
require_bin XYMONGEN xymongen/xymongen

work=$(mktempdir)

XYMOND_PID=""
stop_xymond() {
	[ -n "$XYMOND_PID" ] || return 0
	kill "$XYMOND_PID" 2>/dev/null || true
	local i=0
	while kill -0 "$XYMOND_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
		sleep 0.1
		i=$((i+1))
	done
	XYMOND_PID=""
}
register_cleanup stop_xymond

home="$work/home"
mkdir -p "$home/etc" "$home/tmp" "$home/www" "$home/web"
cp "$ROOT/xymond/webfiles/"* "$home/web/"
printf '127.0.0.1 realhost # conn\n' >"$home/etc/hosts.cfg"
cat >"$home/etc/test.cfg" <<'EOF'
group grp {
        member grpa
        member grpb
}
EOF

require_cfg XYMONSERVER_CFG xymond/etcfiles/xymonserver.cfg
sed -e 's|^XYMONHOME=.*|XYMONHOME="'"$home"'"|' \
    -e 's|^XYMONTMP=.*|XYMONTMP="'"$home"'/tmp"|' \
    -e 's|^HOSTSCFG=.*|HOSTSCFG="'"$home"'/etc/hosts.cfg"|' \
    -e 's|^XYMONWWWDIR=.*|XYMONWWWDIR="'"$home"'/www"|' \
	"$XYMONSERVER_CFG" > "$work/xymonserver.cfg"

xymond_launch() {
	local port=$1; shift
	"$XYMOND" --no-daemon --listen="127.0.0.1:$port" \
		--hosts="$home/etc/hosts.cfg" --env="$work/xymonserver.cfg" \
		--pidfile="$work/xymond.pid" \
		"$@" \
		> "$work/xymond.log" 2>&1 &
	XYMOND_PID=$!
}
start_xymond
{
	echo "XYMONDPORT=\"$PORT\""
	echo 'XYMSRV="127.0.0.1"'
	echo 'XYMSERVERS=""'
} >>"$work/xymonserver.cfg"

send() { "$XYMONCLIENT" "127.0.0.1:$PORT" "$1" >/dev/null || fail "xymond rejected: $1"; }
send "status realhost.grpa green fine"
send "status realhost.grpb red broken"
send "status realhost.solo green alone"
board() { "$XYMONCLIENT" "127.0.0.1:$PORT" "xymondboard host=realhost fields=testname" 2>/dev/null || true; }
i=0
while [ "$i" -lt 100 ]; do
	all=$(board)
	case $all in *grpb*) case $all in *solo*) break ;; esac ;; esac
	sleep 0.1
	i=$((i+1))
done
assert_contains "solo" "$all" "fixture is wrong: the statuses never reached xymond"

"$XYMONGEN" --env="$work/xymonserver.cfg" "$home/www" >"$work/xymongen.log" 2>&1 \
	|| { cat "$work/xymongen.log" >&2; fail "xymongen failed"; }
[ -f "$home/www/xymon.html" ] || { cat "$work/xymongen.log" >&2; fail "xymongen wrote no xymon.html"; }
page=$(cat "$home/www/xymon.html")

# The matrix's column headers link each test's help page; a light links its
# status page with SERVICE=<test>. The group is one column; its members are not.
assert_contains "SERVICE=grp" "$page" "the matrix has no light for the group"
assert_not_contains "SERVICE=grpa" "$page" "member grpa still has its own light"
assert_not_contains "SERVICE=grpb" "$page" "member grpb still has its own light"
assert_contains "SERVICE=solo" "$page" "a test outside any group lost its light"
# The group's light takes the worst member's colour.
grplight=$(grep -a -E 'SERVICE=grp[&"]' <<<"$page" || true)
assert_contains "red" "$grplight" "the group's light is not red, its worst member's colour"

pass "xymongen shows a testgroup as one light, coloured by its worst member"
