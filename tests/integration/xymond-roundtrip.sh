#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/integration/xymond-roundtrip.sh
#
# Bridge between the bash testsuite and the Python functional harness. The
# actual scenario lives in tests/python/test_xymond_roundtrip.py: it starts a
# private xymond, submits a `status`, and reads it back via `xymondboard` over
# a raw TCP socket. This wrapper just locates the prerequisites and maps
# pytest's exit code onto the suite contract (0=pass, 77=skip, else=fail).
#
# Why a bridge: tests/testsuite discovers only executable *.sh, so a .py harness
# is invisible to it. This single .sh entry point lets `./tests/testsuite` and
# `make test` cover the Python round-trip too, without a second runner. The
# Python side is also runnable directly: pytest tests/python/

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)

command -v python3 >/dev/null 2>&1 || skip "python3 not found"
python3 -c 'import pytest' 2>/dev/null \
	|| skip "pytest not installed (pip install -r tests/python/requirements.txt)"

# Locate xymond the same way every other binary test does, and hand the path to
# the fixtures via XYMOND_BIN. Skips (not fails) when it is not built -- e.g. a
# suite run that did not compile the tree.
require_bin XYMOND xymond/xymond
export XYMOND_BIN="$XYMOND"

# Tell the harness it is running under the bridge: a session where every test
# skipped (e.g. xymond present but unusable) is promoted to a failing exit code
# by conftest's pytest_sessionfinish, so it cannot masquerade as a green PASS.
export XYMON_TESTSUITE_BRIDGE=1

# pytest exit codes: 0 = real PASS, 5 = nothing collected, anything else = a
# failure/error (including the all-skipped promotion above). rc=5 is treated as
# a failure, not a skip: the prerequisites were satisfied, so an empty
# collection means the harness is broken, not absent. The only legitimate skip
# is the missing interpreter/binary handled before pytest is ever launched.
set +e
python3 -m pytest "$ROOT/tests/python" -q
rc=$?
set -e

case $rc in
	0) exit 0 ;;
	5) fail "no Python tests collected under tests/python (broken harness)" ;;
	*) fail "pytest failed (rc=$rc)" ;;
esac
