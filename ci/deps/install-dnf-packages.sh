#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-dnf-packages.sh [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. rpm)
  --os NAME       OS key (e.g. rockylinux, fedora)
  --version NAME  Optional version key (e.g. 9, 40)
USAGE
}

ci_deps_init_linux_installer dnf "$@"

DNF_REPO_ARGS=()

configure_rocky_fallback_repos() {
  [[ "${os_name}" == "rockylinux" ]] || return 0
  ci_deps_configure_rocky_fallback_repos "${os_name}" "${version}" || return 1

  DNF_REPO_ARGS=(
    --disablerepo=baseos
    --disablerepo=appstream
    --disablerepo=extras
    --enablerepo=ci-rocky-baseos
    --enablerepo=ci-rocky-appstream
    --enablerepo=ci-rocky-extras
  )
}

configure_enterprise_builder_repos() {
  if [[ "${os_name}" == "rockylinux" || "${os_name}" == "almalinux" ]]; then
    if [[ "${version}" == "8" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled powertools || true
    elif [[ "${version}" == "9" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled crb || true
    fi
    return 0
  fi

  if [[ "${os_name}" == "oraclelinux" && -n "${version}" ]]; then
    ci_deps_as_root dnf config-manager --set-enabled "ol${version}_codeready_builder" || true
  fi
}

install_optional_epel_release() {
  local epel_package="epel-release"

  if [[ "${os_name}" == "oraclelinux" && -n "${version}" ]]; then
    epel_package="oracle-epel-release-el${version}"
  fi

  dnf_run -y install "${epel_package}" || true
}

dnf_run() {
  ci_deps_as_root dnf "${DNF_REPO_ARGS[@]}" "$@"
}

dnf_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

dnf_pkg_available() {
  dnf -q "${DNF_REPO_ARGS[@]}" list --available "$1" >/dev/null 2>&1
}

dnf_install_one() {
  dnf_run -y install "$1"
}

dnf_pre_install() {
  echo "=== Install (Linux packages) ==="

  configure_rocky_fallback_repos
  dnf_run -y install dnf-plugins-core
  configure_enterprise_builder_repos
  install_optional_epel_release
  dnf_run clean all
  dnf_run -y makecache
}

ci_deps_run_installer_modes \
  dnf_pkg_installed dnf_pkg_available dnf_install_one dnf_pre_install
