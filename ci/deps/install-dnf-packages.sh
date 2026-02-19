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

ci_deps_init_cli
ci_deps_parse_cli 1 1 "$@"
ci_deps_setup_variant_defaults
ci_deps_build_os_key
ci_deps_resolve_packages dnf "${family}" "${os_key}"

dnf_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

dnf_pkg_available() {
  dnf -q list --available "$1" >/dev/null 2>&1
}

dnf_install_one() {
  ci_deps_as_root dnf -y install "$1"
}

dnf_pre_install() {
  echo "=== Install (Linux packages) ==="

  ci_deps_as_root dnf -y install dnf-plugins-core
  if [[ "${os_name}" == "rockylinux" || "${os_name}" == "almalinux" ]]; then
    if [[ "${version}" == "8" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled powertools || true
    elif [[ "${version}" == "9" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled crb || true
    fi
  fi
  ci_deps_as_root dnf -y install epel-release || true
  ci_deps_as_root dnf clean all
  ci_deps_as_root dnf -y makecache
}

if [[ "${mode}" == "install" ]]; then
  dnf_pre_install
fi

PKG_SPECS=("${PKGS[@]}")
ci_deps_resolve_package_alternatives dnf_pkg_installed dnf_pkg_available

ci_deps_mode_print_or_exit
ci_deps_mode_check_or_exit dnf_pkg_installed
ci_deps_mode_install_print

if [[ "${mode}" == "install" ]]; then
  PKGS=("${PKG_SPECS[@]}")
  ci_deps_install_packages_with_alternatives \
    dnf_pkg_installed dnf_pkg_available dnf_install_one
fi
