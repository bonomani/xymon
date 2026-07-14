#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/web/showgraph-fallback-gdef.sh
#
# Self-describing statuses, end to end: an XYMON METRICS block fed through
# the real xymond_rrd creates <name>.<instance>.rrd files, and showgraph
# must then graph them without any graphs.cfg entry - when no [name] gdef
# exists it synthesizes a generic one from the dataset names of the first
# matching file.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
command -v make >/dev/null 2>&1 || skip "make not available"

require_bin XYMOND_RRD "xymond/xymond_rrd"

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

work=$(mktemp -d "${TMPDIR:-/tmp}/xymon-showgraph-fb.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

make -C "$ROOT/lib" libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot refresh libxymoncomm.a"; }

"$CC" -I"$ROOT/include" -I"$ROOT/lib" $rrddef -o "$work/showgraph" \
	"$ROOT/web/showgraph.c" "$ROOT/lib/libxymoncomm.a" \
	$pcre_libs $rrdlibs $ssllibs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "showgraph does not compile"; }

# Create the RRD files the way the feature does: an XYMON METRICS block
# fed to xymond_rrd on a column with no TEST2RRD mapping.
rrds="$work/rrd/testhost"
mkdir -p "$work/rrd" "$work/tmp"
ts=$(date +%s)
{
	printf '@@status|%s|127.0.0.1|origin|testhost|diskio|%s|green||green|%s|0||0||%s|0|linux|/\n' \
		"$ts" $((ts+1800)) "$ts" "$ts"
	printf '<!--XYMON METRICS: diskio_ops\n'
	printf 'DS:reads:GAUGE:600:0:U DS:writes:GAUGE:600:0:U\n'
	printf 'ada0 10:20\n'
	printf 'ada1 5:6\n'
	printf -- '-->\n'
	printf 'Disk I/O Status\n'
	printf '@@\n'
} | env XYMONHOME="$work" XYMONTMP="$work/tmp" \
	"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache 2>/dev/null
[ -f "$rrds/diskio_ops.ada0.rrd" ] && [ -f "$rrds/diskio_ops.ada1.rrd" ] \
	|| fail "xymond_rrd did not create the METRICS block files"

cp "$ROOT/xymond/etcfiles/graphs.cfg.DIST" "$work/graphs.cfg"

render() {  # render <service> -> $work/out (PNG + debug dump interleaved)
	REQUEST_METHOD=GET \
	QUERY_STRING="host=testhost&service=$1&graph=hourly&action=view" \
	XYMONHOME="$work" \
		"$work/showgraph" --debug --config="$work/graphs.cfg" \
		--rrddir="$rrds" >"$work/out" 2>&1 || true
}

# No [diskio_ops] section exists in graphs.cfg: the synthesized gdef must
# find both files and one DEF+LINE per dataset, and produce a real PNG.
render "diskio_ops"
grep -aq "DEF:v0@RRDIDX@=@RRDFN@:reads:AVERAGE" "$work/out" 2>/dev/null \
	|| grep -aq "=diskio_ops.ada0.rrd:reads:AVERAGE" "$work/out" \
	|| fail "no generated DEF for dataset 'reads': $(grep -a 'DEF\|error\|Unknown' "$work/out" | head -5)"
grep -aq "=diskio_ops.ada1.rrd:writes:AVERAGE" "$work/out" \
	|| fail "second instance file not matched by the synthesized pattern"
grep -aq "Content-type: image/png" "$work/out" \
	|| fail "fallback did not render a PNG: $(grep -a 'error\|Unknown\|No RRD' "$work/out" | head -5)"

# A name with no matching RRD files fails cleanly, not with a crash.
render "ghost_graph"
grep -aq "No RRD files match this graph" "$work/out" \
	|| fail "missing-files case not reported cleanly: $(head -3 "$work/out")"

# Hand-written gdefs still win: [la] exists in the stock graphs.cfg, so an
# la request must not use the synthesized pattern.
render "la"
grep -aq "diskio_ops" "$work/out" && fail "stock gdef contaminated by fallback"

pass "showgraph synthesizes a working gdef for marker-created RRD files"
