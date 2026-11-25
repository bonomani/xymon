#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/buildsystem/cmake-install-dirs.sh
#
# A CMake install creates every directory 755, and every parent it makes for
# one, whatever the umask, as the make build's install-dirs does
# (install-server-dirs.sh): a package built under umask 077 would otherwise
# ship directories the xymon user cannot enter. CMake creates directories
# under the umask, both for its install() rules and for file(MAKE_DIRECTORY),
# so the mode is set by xymon_install_dirs (cmake/XymonInstallHelpers.cmake.in).
#
# "cmake --install" of the build tests/testsuite-cmake names, into a scratch
# DESTDIR, under umask 077. A directory that already exists keeps its mode.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

[ -n "${XYMON_CMAKE_BUILDDIR:-}" ] || skip "not a CMake build (run through tests/testsuite-cmake)"
command -v cmake >/dev/null 2>&1 || skip "cmake not found"

work=$(mktempdir)
stage=$work/stage

# An existing directory in the path keeps its mode: the first directory the
# install creates under DESTDIR is pre-made 700.
mkdir -p "$stage"
(umask 022 && DESTDIR=$work/probe cmake --install "$XYMON_CMAKE_BUILDDIR" >"$work/probe.log" 2>&1) \
	|| fail "cmake --install failed: $(tail -5 "$work/probe.log")"
top=$(first_line "$(cd "$work/probe" && find . -mindepth 1 -maxdepth 1 -type d | sort)")
top=${top#./}
[ -n "$top" ] || fail "cmake --install created nothing under DESTDIR"
mkdir "$stage/$top"
chmod 700 "$stage/$top"

(umask 077 && DESTDIR=$stage cmake --install "$XYMON_CMAKE_BUILDDIR" >"$work/install.log" 2>&1) \
	|| fail "cmake --install under umask 077 failed: $(tail -5 "$work/install.log")"

bad=$(cd "$stage" && find . -mindepth 1 -type d ! -path "./$top" ! -perm 755 | sort)
[ -z "$bad" ] || fail "under umask 077, cmake --install left these directories other than 755:
$bad"
[ -z "$(cd "$stage" && find "./$top" -maxdepth 0 ! -perm 700)" ] \
	|| fail "the existing directory /$top did not keep its mode 700"
[ "$(cd "$stage" && find . -type d | wc -l)" -gt 10 ] \
	|| fail "cmake --install under umask 077 created almost nothing"

pass "a CMake install creates every directory 755 under umask 077, and leaves an existing one's mode"
