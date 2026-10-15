#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymonmarkers.sh
#
# The marker parser in lib/xymonmarkers.c decides which status messages
# reach the RRD block writer and how many instances a graph pages over.
# Compiles xymonmarkers-harness.c against the built libxymoncomm.a and runs
# its assertions: banner recognition, named and unnamed blocks, instance
# counting (keyword lines, short lines, names with spaces), GRAPH attributes,
# unclosed blocks, the legacy DEVMON banner, and the two dispatch probes.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)
here=$(dirname "$0")

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
require_gnu_make

[ -f "$ROOT/include/config.h" ] && [ -f "$ROOT/lib/libxymoncomm.a" ] \
	|| skip "tree not built (run make first; the post-build CI suite covers this)"

work=$(mktempdir)

"$XYMON_MAKE" -C "$ROOT/lib" libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot refresh libxymoncomm.a"; }

pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

harness_cflags=$(xymon_cflags "$ROOT")
harness_ldflags=$(xymon_ldflags "$ROOT")
# shellcheck disable=SC2086  # deliberate word-splitting, as the neighbouring tests do
"$CC" $harness_cflags -o "$work/harness" "$here/xymonmarkers-harness.c" \
	"$ROOT/lib/libxymoncomm.a" $harness_ldflags $pcre_libs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }

"$work/harness" 2>"$work/stderr.log" \
	|| fail "marker parser assertions failed: $(cat "$work/stderr.log")"

pass "the marker parser recognizes banners and counts instances as the writer stores them"
