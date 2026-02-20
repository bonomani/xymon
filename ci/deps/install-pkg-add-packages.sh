#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
# shellcheck source=lib/install-bsd-common.sh
source "${script_dir}/lib/install-bsd-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-pkg-add-packages.sh [--print] [--check-only] [--install]
                                   --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --os NAME       OS key (supported: netbsd, openbsd)
  --version NAME  Optional version key
USAGE
}

ci_deps_init_cli
ci_deps_parse_cli 0 1 "$@"
ci_deps_setup_variant_defaults
bsd_init_os_context "${os_name}" "${version}"
bsd_require_os_for_pkgmgr pkg_add
bsd_resolve_packages pkg_add

pkg_add_pkg_installed() {
  bsd_pkg_installed pkg_add "$1"
}

pkg_add_pkg_available() {
  bsd_pkg_available pkg_add "$1"
}

pkg_add_install_one() {
  local pkg="${1:-}"
  local rc=0
  local -a saved_pkgs=("${PKGS[@]}")

  PKGS=("${pkg}")
  if ! bsd_install_pkg_add; then
    rc=$?
  fi

  PKGS=("${saved_pkgs[@]}")
  return "${rc}"
}

PKG_SPECS=("${PKGS[@]}")
ci_deps_resolve_package_alternatives pkg_add_pkg_installed pkg_add_pkg_available

ci_deps_mode_print_or_exit
ci_deps_mode_check_or_exit pkg_add_pkg_installed
ci_deps_mode_install_print

if [[ "${mode}" == "install" ]]; then
  echo "=== Install (BSD pkg_add packages) ==="
  PKGS=("${PKG_SPECS[@]}")
  ci_deps_install_packages_with_alternatives \
    pkg_add_pkg_installed pkg_add_pkg_available pkg_add_install_one
fi
