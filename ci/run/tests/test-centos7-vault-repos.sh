#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"

# shellcheck source=../../deps/lib/install-common.sh
source "${repo_root}/ci/deps/lib/install-common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains_text() {
  local file="$1"
  local expected="$2"
  if ! grep -F -- "$expected" "$file" >/dev/null 2>&1; then
    echo "Missing expected text in ${file}: ${expected}" >&2
    sed -n '1,120p' "$file" >&2 || true
    exit 1
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

test_centos7_vault_root_selection() {
  assert_equals \
    "http://vault.centos.org/7.9.2009" \
    "$(ci_deps_centos7_vault_root x86_64)" \
    "x86_64 should use the primary CentOS 7 vault"

  assert_equals \
    "http://vault.centos.org/altarch/7.9.2009" \
    "$(ci_deps_centos7_vault_root aarch64)" \
    "aarch64 should use the CentOS 7 altarch vault"

  assert_equals \
    "http://vault.centos.org/altarch/7.9.2009" \
    "$(ci_deps_centos7_vault_root ppc64le)" \
    "ppc64le should use the CentOS 7 altarch vault"

  assert_equals \
    "armhfp" \
    "$(ci_deps_detect_rpm_basearch armv7l)" \
    "armv7l should normalize to armhfp"

  assert_equals \
    "http://vault.centos.org/altarch/7.9.2009" \
    "$(ARCHITECTURE=ppc64le ci_deps_centos7_vault_root)" \
    "ARCHITECTURE=ppc64le should use the CentOS 7 altarch vault even without rpm/uname detection"

  assert_equals \
    "armhfp" \
    "$(ARCHITECTURE=arm32v7 ci_deps_detect_rpm_basearch)" \
    "ARCHITECTURE=arm32v7 should normalize to the RPM armhfp basearch"

  if ! ci_deps_centos7_has_epel_archive x86_64; then
    fail "x86_64 should have a CentOS 7 EPEL archive"
  fi

  if ! ci_deps_centos7_has_epel_archive aarch64; then
    fail "aarch64 should have a CentOS 7 EPEL archive"
  fi

  if ci_deps_centos7_has_epel_archive armhfp; then
    fail "armhfp should not claim a CentOS 7 EPEL archive"
  fi
}

test_centos7_vault_repo_generation() {
  local tmpdir
  local repo_file
  local epel_repo_file

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  repo_file="${tmpdir}/centos7-vault.repo"
  epel_repo_file="${tmpdir}/epel7-archive.repo"

  ci_deps_as_root() {
    "$@"
  }

  ci_deps_install_centos7_vault_repo "${repo_file}" aarch64
  assert_file_contains_text "${repo_file}" "baseurl=http://vault.centos.org/altarch/7.9.2009/os/\$basearch/"
  assert_file_contains_text "${repo_file}" "baseurl=http://vault.centos.org/altarch/7.9.2009/updates/\$basearch/"
  assert_file_contains_text "${repo_file}" "baseurl=http://vault.centos.org/altarch/7.9.2009/extras/\$basearch/"

  ci_deps_install_centos7_vault_repo "${repo_file}" x86_64
  assert_file_contains_text "${repo_file}" "baseurl=http://vault.centos.org/7.9.2009/os/\$basearch/"
  assert_file_contains_text "${repo_file}" "baseurl=http://vault.centos.org/7.9.2009/updates/\$basearch/"
  assert_file_contains_text "${repo_file}" "baseurl=http://vault.centos.org/7.9.2009/extras/\$basearch/"

  ci_deps_install_epel7_archive_repo "${epel_repo_file}"
  assert_file_contains_text "${epel_repo_file}" "[ci-epel7-archive]"
  assert_file_contains_text "${epel_repo_file}" "baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/\$basearch/"

  trap - RETURN
  rm -rf "${tmpdir}"
}

test_centos7_vault_root_selection
test_centos7_vault_repo_generation
