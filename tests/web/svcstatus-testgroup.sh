#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/web/svcstatus-testgroup.sh
#
# A testgroup declared in test.cfg is one page: svcstatus.cgi?SERVICE=<group>
# fetches each member's status from xymond, shows a band with every member's
# colour, then each member's own content below it, and colours the page by the
# worst member. Driven through a real xymond holding two member statuses - one
# green, one red - and the real CGI.
set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"
# shellcheck source=tests/lib/xymond-daemon.sh
. "$(dirname "$0")/../lib/xymond-daemon.sh"

ROOT=$(find_root)
require_c_buildenv "$ROOT"
require_bin XYMOND xymond/xymond
require_bin XYMONCLIENT common/xymon

# shellcheck source=tests/lib/svcstatus-cgi.sh
. "$(dirname "$0")/../lib/svcstatus-cgi.sh"
svcstatus_setup --no-daemon
svcstatus_build || { cat "$work/cc.log" >&2; fail "svcstatus does not build"; }

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

mkdir -p "$work/xymond/tmp"
require_cfg XYMONSERVER_CFG xymond/etcfiles/xymonserver.cfg
sed -e 's|^XYMONHOME=.*|XYMONHOME="'"$work"'/xymond"|' \
    -e 's|^XYMONTMP=.*|XYMONTMP="'"$work"'/xymond/tmp"|' \
	"$XYMONSERVER_CFG" > "$work/xymond.cfg"
xymond_launch() {
	local port=$1; shift
	"$XYMOND" --no-daemon --listen="127.0.0.1:$port" \
		--hosts="$work/etc/hosts.cfg" --env="$work/xymond.cfg" \
		--pidfile="$work/xymond.pid" \
		"$@" \
		> "$work/xymond.log" 2>&1 &
	XYMOND_PID=$!
}
start_xymond
# The CGI's environment file comes from the DIST one, whose XYMONHOME is a
# placeholder that loadenv() puts over the real environment: point it at
# $work, where test.cfg is read from ($XYMONHOME/etc/test.cfg).
{
	echo "XYMONDPORT=\"$PORT\""
	echo "XYMONHOME=\"$work\""
} >>"$work/etc/xymonserver.cfg"

send() { "$XYMONCLIENT" "127.0.0.1:$PORT" "$1" >/dev/null || fail "xymond rejected: $1"; }
send "status realhost.grpa green GRPA-BODY all fine"
send "status realhost.grpb red GRPB-BODY something broke"
board() { "$XYMONCLIENT" "127.0.0.1:$PORT" "xymondboard host=realhost fields=testname" 2>/dev/null || true; }
i=0
while [ "$i" -lt 100 ]; do
	all=$(board)
	case $all in *grpa*) case $all in *grpb*) break ;; esac ;; esac
	sleep 0.1
	i=$((i+1))
done
assert_contains "grpb" "$all" "fixture is wrong: the member statuses never reached xymond"

# A header carrying the page colour the way the stock one does
# (xymond/webfiles/hostsvc_header), so the page colour can be read back.
mkdir -p "$work/web"
printf '<BODY class="&XYMWEBBACKGROUND">\n' >"$work/web/hostsvc_header"
printf '</BODY>\n' >"$work/web/hostsvc_footer"

cat >"$work/etc/test.cfg" <<'EOF'
group grp {
        member grpa
        member grpb
}
EOF

render_live "HOST=realhost&SERVICE=grp"
assert_not_contains "Status: 403" "$OUT" "the group page was refused"

# A CGI answer starts with its headers: without a Content-type the web
# server rejects the page before the browser sees it.
hdr=${OUT%%$'\n\n'*}
assert_contains "Content-type: " "$hdr" "the group page is sent without a Content-type header"

# The band names every member, with its own colour.
assert_contains "alt=\"green\" border=0> grpa" "$OUT" "the band does not show grpa as green"
assert_contains "alt=\"red\" border=0> grpb" "$OUT" "the band does not show grpb as red"
# Each member's section follows, with that member's status text.
assert_contains "<h3>grpa</h3>" "$OUT" "no section for member grpa"
assert_contains "<h3>grpb</h3>" "$OUT" "no section for member grpb"
assert_contains "GRPA-BODY" "$OUT" "member grpa's status text is missing from its section"
assert_contains "GRPB-BODY" "$OUT" "member grpb's status text is missing from its section"
# A member's status line is its heading, as on its own page - not body
# text that still carries the colour word.
assert_contains "GRPA-BODY all fine</H3>" "$OUT" "member grpa's status line is not its heading"
assert_not_contains "green GRPA-BODY" "$OUT" "member grpa's status line is shown as body text"
# The page takes the worst member's colour.
assert_contains '<BODY class="red">' "$OUT" "the page is not coloured by its worst member"

# On an access-controlled site, a member is shown only to a user allowed to
# view it: being allowed the group name must not reveal the other members,
# nor their colour through the page colour.
printf 'grp: alice\ngrpa: alice\n' >"$work/etc/access.cfg"
RENDER_ENV="REMOTE_USER=alice" \
	render_live "HOST=realhost&SERVICE=grp" --access="$work/etc/access.cfg"
assert_not_contains "Status: 403" "$OUT" "a user allowed the group was refused its page"
assert_contains "GRPA-BODY" "$OUT" "an allowed member is missing from the access-controlled page"
assert_not_contains "GRPB-BODY" "$OUT" "a member the user may not view is shown on the group page"
assert_not_contains "> grpb</td>" "$OUT" "a member the user may not view is in the band"
assert_contains '<BODY class="green">' "$OUT" "the page colour reveals a member the user may not view"

# A test that is not a group still gets its ordinary page.
render_live "HOST=realhost&SERVICE=grpa"
assert_contains "GRPA-BODY" "$OUT" "an ordinary member page no longer renders"
assert_not_contains "<h3>grpb</h3>" "$OUT" "an ordinary page shows another member's section"

pass "a testgroup page shows every member's colour and content, coloured by the worst"
