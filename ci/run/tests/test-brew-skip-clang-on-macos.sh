#!/usr/bin/env bash
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
    bash ci/deps/install-packages.sh --pkgmgr brew --print --family macos --os macos --version latest
)"

if printf '%s\n' "${output}" | grep -Fx -- "clang" >/dev/null 2>&1; then
  fail "brew dependency resolution should not request clang on macOS"
fi

for expected in cmake make ninja; do
  if ! printf '%s\n' "${output}" | grep -Fx -- "${expected}" >/dev/null 2>&1; then
    fail "missing expected Homebrew package: ${expected}"
  fi
done
