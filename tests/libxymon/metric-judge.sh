#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/libxymon/metric-judge.sh
#
# lib/metric.c is the one comparison the client analysers share: a sample
# (test, instance, name, value, state) judged by rules that name a metric, a
# level and a colour. The analysers used to carry a copy each; this pins what
# the shared one promises, so a change to it is a change everyone sees:
#   - at or above the level trips, at or below with "below" set;
#   - a rule trips only on the metric it names;
#   - the worst tripping colour wins, green when none trips, and the first
#     rule in order among that colour is the one reported;
#   - an unmeasured sample never trips.
#
# See metric-judge-harness.c for the assertions, all through the library's
# public interface.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)
here=$(dirname "$0")

[ -f "$ROOT/lib/metric.c" ] || skip "lib/metric.c not present in this checkout"

require_c_buildenv "$ROOT"
[ -f "$ROOT/lib/libxymonclient.a" ] \
	|| skip "tree not built (run make first; the post-build CI suite covers this)"

work=$(mktempdir)

build_xymon_libs "$ROOT" "$work/libbuild.log" libxymonclient.a

harness_cflags=$(xymon_cflags "$ROOT")
harness_ldflags=$(xymon_ldflags "$ROOT")
"$CC" $harness_cflags -o "$work/harness" \
	"$here/metric-judge-harness.c" \
	"$ROOT/lib/libxymonclient.a" \
	$harness_ldflags 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }

"$work/harness" 2>"$work/stderr.log" \
	|| fail "metric_judge assertions failed:
$(cat "$work/stderr.log")"

pass "metric_judge trips at the level, on the named metric only, worst colour first, never on an unmeasured sample"
