#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/web/svcstatus-path-traversal.sh
#
# Regression guard for the CGI path-traversal series #145 / #146 / #147.
#
# svcstatus.cgi --historical serves a client-data file from
# "$CLIENTLOGS/<host>/<timestamp>", where both components come straight from
# the request. basename() alone does not confine them: it returns ".." for
# ".." (one level up) and "/" for "/" (collapse onto the parent), and the
# host is not validated before the path is built -- loadhostdata() runs later
# in do_request(), and the access-control check is conditional on an
# access-control file being configured.
#
# This drives the real CGI against canary files planted above and inside the
# client-log root and asserts that every non-component host is refused, while
# a legitimate request still returns its data.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
command -v make >/dev/null 2>&1 || skip "make not available"
[ -f "$ROOT/include/config.h" ] || skip "tree not configured (no include/config.h)"
[ -f "$ROOT/Makefile" ] || skip "tree not configured (no Makefile)"

ssllibs=$(sed -n 's/^SSLLIBS *= *//p' "$ROOT/Makefile")
pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

work=$(mktemp -d "${TMPDIR:-/tmp}/xymon-svcstatus-traversal.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

make -C "$ROOT/lib" libxymon.a libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot build libxymon.a / libxymoncomm.a"; }

# svcstatus.cgi is svcstatus.o + svcstatus-info.o + svcstatus-trends.o
# (web/Makefile SVCSTATUSOBJS); build them here so the test does not depend
# on the tree having been built already.
# The archives are listed twice rather than wrapped in --start-group:
# --start-group is GNU ld only, and the Darwin linker rejects it.
"$CC" -I"$ROOT/include" -I"$ROOT/lib" -I"$ROOT/web" -o "$work/svcstatus" \
	"$ROOT/web/svcstatus.c" "$ROOT/web/svcstatus-info.c" "$ROOT/web/svcstatus-trends.c" \
	"$ROOT/lib/libxymon.a" "$ROOT/lib/libxymoncomm.a" "$ROOT/lib/libxymon.a" \
	$pcre_libs $ssllibs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "svcstatus does not build -- cannot verify the traversal guards"; }

mkdir -p "$work/etc" "$work/var/hostdata/realhost"
cp "$ROOT/xymond/etcfiles/xymonserver.cfg.DIST" "$work/etc/xymonserver.cfg"

# The canaries. ABOVE_ROOT sits one level up from CLIENTLOGS (reachable with
# a ".." host); IN_ROOT sits in CLIENTLOGS itself (reachable when a component
# collapses to nothing, or to "/").
printf 'CANARY-ABOVE-ROOT\n'  >"$work/var/CANARY_ABOVE"
printf 'CANARY-IN-ROOT\n'     >"$work/var/hostdata/CANARY_IN"
printf 'legitimate client data\n' >"$work/var/hostdata/realhost/20260101"

render() {  # render <query-string>
	local out rc
	set +e
	out=$(REQUEST_METHOD=GET QUERY_STRING="$1" \
	      XYMONHOME="$work" XYMONVAR="$work/var" CLIENTLOGS="$work/var/hostdata" \
		"$work/svcstatus" --historical --env="$work/etc/xymonserver.cfg" 2>/dev/null)
	rc=$?
	set -e
	# 0 = page served, 1 = errormsg() refusal. Anything else (137, 139, ...)
	# is a crash, which would otherwise look exactly like "no canary found".
	[ "$rc" -le 1 ] || fail "svcstatus exited $rc (crash?) on QUERY_STRING=$1"
	printf '%s' "$out"
}

# Every one of these names no real host: ".." escapes upward, "." and "/"
# collapse onto the client-log root. "," and ",," look like ordinary
# components until the CLIENT branch rewrites ',' to '.', which is why they
# have to be tested separately from "." and "..". None may return a canary.
for host in ".." "." "/" "//" "../" "/.." "," ",," ",,/" "./" ",."; do
	for target in CANARY_ABOVE CANARY_IN; do
		out=$(render "CLIENT=$host&TIMEBUF=$target")
		case "$out" in
			*CANARY-ABOVE-ROOT*|*CANARY-IN-ROOT*)
				fail "path traversal: CLIENT='$host' disclosed $target (#145/#146/#147)"
				;;
		esac
	done
done

# A legitimate request must still be served -- the guards must not have
# turned into a blanket refusal.
out=$(render "CLIENT=realhost&TIMEBUF=20260101")
assert_contains "legitimate client data" "$out" \
	"legitimate client-data request no longer served"

# Hosts named by IP take a different parse path (CLIENT rewrites ',' to '.'),
# so cover both spellings.
mkdir -p "$work/var/hostdata/192.168.1.1"
printf 'ipv4 client data\n' >"$work/var/hostdata/192.168.1.1/20260101"
for spelling in "192,168,1,1" "192.168.1.1"; do
	out=$(render "CLIENT=$spelling&TIMEBUF=20260101")
	assert_contains "ipv4 client data" "$out" \
		"IP-named host ($spelling) no longer served"
done

echo "OK $(basename "$0")"
