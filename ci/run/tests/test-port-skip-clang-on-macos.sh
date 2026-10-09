#!/usr/bin/env bash
# Regression test: clang must not be requested as a MacPorts package on macOS.
#
# MacPorts has no plain `clang` port (only versioned ports such as clang-18),
# so adding it to the dependency list makes `port install` fail. The macOS
# CLT/Xcode toolchain already provides clang, so dependency resolution must skip
# it for the port pkgmgr -- just as it already does for brew.
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

output="$(
  cd "${repo_root}"
  VARIANT=server \
  ENABLE_LDAP=ON \
  ENABLE_SNMP=ON \
  CI_COMPILER=clang \
  CI_DEPS_BUILD_TOOL=cmake \
    bash ci/deps/install-packages.sh --pkgmgr port --print --family macos --os macos --version latest
)"

if printf '%s\n' "${output}" | grep -Fx -- "clang" >/dev/null 2>&1; then
  fail "MacPorts dependency resolution should not request clang on macOS"
fi

if [[ -z "${output//[$' \t\n']/}" ]]; then
  fail "MacPorts dependency resolution produced no packages"
fi

echo "PASS: clang excluded from MacPorts (port) dependency resolution"
