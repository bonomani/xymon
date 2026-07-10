#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/web/html-log-rrdcount.sh
#
# Regression guard for issue #234: graph paging on status pages must use the
# RRD update count recorded by xymond_rrd when one is available and fresh,
# instead of guessing from the status text line count (which emits dead graph
# images whenever the two diverge). Drives the real generate_html_log()
# through a small C harness; see the harness for the full list of assertions.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)
here=$(dirname "$0")

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
command -v make >/dev/null 2>&1 || skip "make not available"

pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

ssllibs=$(sed -n 's/^SSLLIBS *= *//p' "$ROOT/Makefile" 2>/dev/null || true)

work=$(mktemp -d "${TMPDIR:-/tmp}/xymon-htmllog-rrdcount.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

# The harness links libxymoncomm. A tree that was never configured/built
# skips (tests.yml runs on a bare tree; the post-build suite in build.yml
# then exercises it for real). On a built tree, refresh the archive
# incrementally so the harness tests this tree's code.
[ -f "$ROOT/include/config.h" ] && [ -f "$ROOT/lib/libxymoncomm.a" ] \
	|| skip "tree not built (run make first; the post-build CI suite covers this)"
make -C "$ROOT/lib" libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot refresh libxymoncomm.a"; }

"$CC" -I"$ROOT/include" -I"$ROOT/lib" -o "$work/harness" \
	"$here/html-log-rrdcount-harness.c" "$ROOT/lib/libxymoncomm.a" \
	$pcre_libs $ssllibs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }

mkdir -p "$work/rrd"

XYMONHOME="$work" \
XYMONRRDS="$work/rrd" \
CGIBINURL="/xymon-cgi" \
RRDWIDTH=576 \
RRDHEIGHT=120 \
XYMONSKIN="/xymon/gifs" \
XYMONWEB="/xymon" \
IMAGEFILETYPE="gif" \
TEST2RRD="cpu=la,disk" \
GRAPHS="la,disk" \
INFOCOLUMN="info" \
TRENDSCOLUMN="trends" \
ACKUNTILMSG="until %H:%M" \
	"$work/harness" 2>"$work/stderr.log" || fail "harness assertions failed: $(cat "$work/stderr.log")"

pass "status-page graph paging uses the recorded RRD update count"
