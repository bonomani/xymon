#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/client/client-cfg-substituted.sh
#
# The client's generated xymonclient.cfg and clientlaunch.cfg carry no
# @PLACEHOLDER@ left from their .DIST templates. A placeholder left in is read
# as a literal path: "optional directory @XYMONHOME@/etc/clientlaunch.d" then
# includes nothing, and msgcache writes its pidfile under "@XYMONCLIENTRUNDIR@".
# The make build substitutes them in client/Makefile, the CMake build in
# client/CMakeLists.txt; tests/testsuite-cmake points the two variables at the
# CMake build's copies.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_cfg XYMONCLIENT_CFG client/xymonclient.cfg
require_cfg CLIENTLAUNCH_CFG client/clientlaunch.cfg

for f in "$XYMONCLIENT_CFG" "$CLIENTLAUNCH_CFG"; do
	left=$(grep -nE '@[A-Z_]+@' "$f" || true)
	[ -z "$left" ] || fail "$f still carries placeholders from its template:
$left"
done

pass "the client's xymonclient.cfg and clientlaunch.cfg carry no @PLACEHOLDER@ from their templates"
