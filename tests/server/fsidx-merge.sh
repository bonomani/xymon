#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/fsidx-merge.sh
#
# Two-writer schema merge in the fileset index: the status- and
# data-channel xymond_rrd processes share one on-disk index per host.
# Schema fields (u/h/d/t) carry a declaration timestamp (g=); on flush a
# NEWER on-disk bundle is adopted outright, an older one ignored, and
# g-less legacy entries keep the old weak-fill merge. This is the fix
# for the recorded ping-pong watch-item: a stale writer used to
# republish its old spec forever instead of adopting the other's.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)
here=$(dirname "$0")

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
require_gnu_make

pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

[ -f "$ROOT/include/config.h" ] && [ -f "$ROOT/lib/libxymoncomm.a" ] \
	|| skip "tree not built (run make first; the post-build CI suite covers this)"

work=$(mktempdir)

"$XYMON_MAKE" -C "$ROOT/lib" libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot refresh libxymoncomm.a"; }

harness_cflags=$(xymon_cflags "$ROOT")
harness_ldflags=$(xymon_ldflags "$ROOT")
# shellcheck disable=SC2086  # deliberate word-splitting, as the neighbouring tests do
"$CC" $harness_cflags -o "$work/harness" "$here/fsidx-merge-harness.c" \
	"$ROOT/lib/libxymoncomm.a" $harness_ldflags $pcre_libs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }

run() {  # run <scenario> -> stdout of the published index lines
	rm -rf "$work/rrd"; mkdir -p "$work/rrd/h1"
	"$work/harness" "$work/rrd" "$1"
}

# The ping-pong case itself: disk moved to a newer declaration while we
# held a stale copy - our flush adopts the whole newer bundle.
out=$(run adopt-newer)
grep -q 'u=v:msec' <<<"$out" || fail "newer disk spec not adopted: $out"
grep -q 'h=v:300' <<<"$out" || fail "newer bundle not adopted wholesale: $out"
grep -q 'g=200' <<<"$out" || fail "adopted generation not recorded: $out"
grep -Eq 'u=v:ms( |$)' <<<"$out" && fail "stale spec republished (the ping-pong): $out"

# The reverse: an older on-disk generation must not beat our newer one.
out=$(run ignore-older)
grep -q 'u=v:msec' <<<"$out" || fail "newer in-memory spec lost to older disk: $out"
grep -q 'g=200' <<<"$out" || fail "generation regressed: $out"
grep -q 'u=v:old' <<<"$out" && fail "older disk spec adopted: $out"

# Legacy g-less files: the old weak-fill behavior is preserved.
out=$(run legacy-fill)
grep -q 'u=v:legacy' <<<"$out" || fail "legacy weak fill broken: $out"

# A live declaration stamps now() as its generation and outranks disk.
out=$(run live-wins)
grep -q 'u=v:live' <<<"$out" || fail "live declaration lost to on-disk generation: $out"
grep -q 'u=v:stale' <<<"$out" && fail "stale disk spec survived a live declaration: $out"

# Retraction: a sample's declaration bundle is the whole truth - a field
# the block stopped declaring must leave the record instead of being
# republished under every fresh generation. The undeclared (legacy
# handler) path in the same scenario must leave seeded fields alone.
out=$(run retract-live)
grep -q 'u=v:ms' <<<"$out" || fail "declared field lost by the retraction sample: $out"
grep -q 'h=v:600' <<<"$out" || fail "declared field lost by the retraction sample: $out"
grep -q 't=' <<<"$out" && fail "retracted threshold republished: $out"

# ... and retraction crosses the two-writer merge: adopting a newer disk
# bundle clears the fields it no longer carries.
out=$(run adopt-retract)
grep -q 'g=200' <<<"$out" || fail "newer disk bundle not adopted: $out"
grep -q 't=' <<<"$out" && fail "retraction lost in the cross-writer merge: $out"

# A channel-fed hostname carrying '/' must be rejected by every fsidx
# entry point: the decoy index planted OUTSIDE the RRD tree (where the
# "../outside" hostname would resolve) must survive untouched - no
# flock/rewrite from a flush, no unlink from a drop.
mkdir -p "$work/outside"
echo "sentinel" >"$work/outside/.fileset-index"
: >"$work/outside/.fileset-index.lock"
out=$(run reject-slash 2>/dev/null)
grep -q 'probe=null' <<<"$out" || fail "fsidx API honored a '/' hostname: $out"
grep -q 'sentinel' "$work/outside/.fileset-index" 2>/dev/null \
	|| fail "'/' hostname escaped the RRD tree (outside index removed or rewritten)"

# An rrdfn the space-separated record format cannot carry (blank, line
# break, leading '#') is refused at every recording entry point.
out=$(run reject-badfn 2>/dev/null)
grep -q 'f\.a\.rrd 1000' <<<"$out" || fail "valid entry missing from the flush: $out"
grep -q 'bad' <<<"$out" && fail "record-corrupting rrdfn was indexed: $out"
grep -q 'lead' <<<"$out" && fail "leading-# rrdfn was indexed: $out"

pass "the fileset index merges the two writers by declaration generation and refuses unsafe names"
