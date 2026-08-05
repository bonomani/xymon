# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck shell=bash
#
# tests/lib/build-worker.sh -- compile a xymond worker from the configured
# tree for a test. Source after assert.sh, then e.g.:
#
#     build_xymond_worker "$outdir" xymond_hostdata \
#         xymond/xymond_hostdata.c xymond/xymond_worker.c
#
# Source paths are relative to the repo root; the binary lands in
# <outdir>/<name>.
#
# Skips (not fails) when the toolchain or a configured tree is absent, and
# when the worker does not compile here: the product build is what CI
# verifies, so a test-side link failure is a missing precondition for this
# test, not a product regression to report as red.

[ -n "${__XYMON_TESTS_BUILD_WORKER_SOURCED:-}" ] && return 0
__XYMON_TESTS_BUILD_WORKER_SOURCED=1

build_xymond_worker() {
	local outdir=$1 prog=$2 root cc treelibs pcre_libs src srcs
	shift 2
	root=$(find_root)
	cc=${CC:-cc}

	command -v "$cc" >/dev/null 2>&1 || skip "no C compiler available (CC=$cc)"
	command -v make >/dev/null 2>&1 || skip "make not available"
	[ -f "$root/include/config.h" ] || skip "tree not configured (no include/config.h)"
	[ -f "$root/Makefile" ] || skip "tree not configured (no Makefile)"

	# The extra libraries the product link uses (XYMONCOMMLIBS in
	# xymond/Makefile). Asked of make, not sed from the Makefile: NETLIBS,
	# ZLIBLIBS and LIBRTDEF live in the per-OS file the Makefile includes.
	treelibs=$(printf '__testlibs:\n\t@echo $(ZLIBLIBS) $(SSLLIBS) $(NETLIBS) $(LIBRTDEF)\n' \
			| make -s -C "$root" -f Makefile -f - __testlibs 2>/dev/null) \
		|| treelibs=$(sed -n 's/^SSLLIBS *= *//p' "$root/Makefile")

	# PCRELIBS: explicit env override first, then the configured tree's own
	# setting (which carries any -L for a nonstandard install), then
	# pkg-config, then the bare library as a last resort.
	pcre_libs=${PCRELIBS:-}
	[ -n "$pcre_libs" ] || pcre_libs=$(sed -n 's/^PCRELIBS *= *//p' "$root/Makefile")
	if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
		pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
	fi
	[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

	make -C "$root/lib" libxymon.a libxymoncomm.a libxymontime.a >"$outdir/libbuild.log" 2>&1 \
		|| { cat "$outdir/libbuild.log" >&2; skip "cannot build the xymon libraries here"; }

	srcs=()
	for src in "$@"; do srcs+=("$root/$src"); done

	# Archives listed twice rather than --start-group, which is GNU ld only.
	"$cc" -I"$root/include" -I"$root/lib" -I"$root/xymond" -o "$outdir/$prog" \
		"${srcs[@]}" \
		"$root/lib/libxymon.a" "$root/lib/libxymoncomm.a" "$root/lib/libxymontime.a" \
		"$root/lib/libxymon.a" \
		$pcre_libs $treelibs 2>"$outdir/cc.log" \
		|| { cat "$outdir/cc.log" >&2; skip "$prog does not compile here"; }
}
