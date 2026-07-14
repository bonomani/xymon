#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/web/showgraph-gdef-include.sh
#
# Gdef inheritance: "INCLUDE <base>" copies an earlier definition's header
# keywords and definition lines; the variant's own keywords override
# (later wins) and its definition lines append. Drives the real showgraph
# with --debug against stub RRD files and asserts on the argument dump.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
command -v make >/dev/null 2>&1 || skip "make not available"

[ -f "$ROOT/include/config.h" ] && [ -f "$ROOT/lib/libxymoncomm.a" ] \
	|| skip "tree not built (run make first; the post-build CI suite covers this)"
[ -f "$ROOT/web/showgraph.cgi" ] || skip "tree built without RRD support (no showgraph.cgi)"

rrddef=$(sed -n 's/^RRDDEF *= *//p' "$ROOT/Makefile")
rrdlibs=$(sed -n 's/^RRDLIBS *= *//p' "$ROOT/Makefile")
[ -n "$rrdlibs" ] || rrdlibs="-lrrd"
ssllibs=$(sed -n 's/^SSLLIBS *= *//p' "$ROOT/Makefile")

pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

work=$(mktemp -d "${TMPDIR:-/tmp}/xymon-gdefinc.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

make -C "$ROOT/lib" libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot refresh libxymoncomm.a"; }

"$CC" -I"$ROOT/include" -I"$ROOT/lib" $rrddef -o "$work/showgraph" \
	"$ROOT/web/showgraph.c" "$ROOT/lib/libxymoncomm.a" \
	$pcre_libs $rrdlibs $ssllibs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "showgraph does not compile"; }

rrds="$work/rrd/testhost"
mkdir -p "$rrds"
touch "$rrds/incm.a.rrd" "$rrds/incm.b.rrd"

cp "$ROOT/xymond/etcfiles/graphs.cfg.DIST" "$work/graphs.cfg"
cat >>"$work/graphs.cfg" <<'EOF'

[incbase]
	FNPATTERN ^incm\.(.+)\.rrd
	TITLE Base title
	YAXIS ops
	DEF:v@RRDIDX@=@RRDFN@:v:AVERAGE
	LINE1:v@RRDIDX@#@COLOR@:@RRDPARAM@

[incvar]
	INCLUDE incbase
	TITLE Variant title
	GPRINT:v0:LAST:extra %5.1lf

[incvar2]
	TITLE Early title
	INCLUDE incbase
EOF

render() {
	REQUEST_METHOD=GET \
	QUERY_STRING="host=testhost&service=$1&graph=hourly&action=view" \
	XYMONHOME="$work" \
		"$work/showgraph" --debug --config="$work/graphs.cfg" \
		--rrddir="$rrds" >"$work/out" 2>&1 || true
}

# The variant inherits FNPATTERN and the DEF/LINE lines, overrides the
# title, and appends its own line.
render "incvar"
grep -aq "=incm.a.rrd:v:AVERAGE" "$work/out" || fail "inherited FNPATTERN/DEF not applied"
grep -aq "=incm.b.rrd:v:AVERAGE" "$work/out" || fail "inherited pattern must match all files"
grep -aq "Variant title" "$work/out" || fail "variant TITLE did not override"
grep -a "title" "$work/out" | grep -aq "Base title" && fail "base TITLE leaked into the variant"
grep -aq "GPRINT:v0:LAST:extra" "$work/out" || fail "appended definition line missing"

# A keyword written BEFORE the INCLUDE also wins - the variant's own
# keywords override the inherited ones wherever they appear.
render "incvar2"
grep -aq "Early title" "$work/out" || fail "pre-INCLUDE keyword was clobbered by the base"
grep -aq "=incm.a.rrd:v:AVERAGE" "$work/out" || fail "pre-INCLUDE variant lost the inherited defs"

# The base is untouched by being included.
render "incbase"
grep -aq "Base title" "$work/out" || fail "base gdef no longer renders on its own"
grep -aq "GPRINT:v0:LAST:extra" "$work/out" && fail "variant line leaked into the base"

pass "INCLUDE inherits a gdef with later-wins overrides and appended lines"
