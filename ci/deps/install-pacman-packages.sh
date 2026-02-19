#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-pacman-packages.sh [--print] [--check-only] [--install]
                                  --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. arch)
  --os NAME       OS key (e.g. archlinux)
  --version NAME  Optional version key (e.g. latest)
USAGE
}

ci_deps_init_cli
ci_deps_parse_cli 1 1 "$@"
ci_deps_setup_variant_defaults
ci_deps_build_os_key
ci_deps_resolve_packages pacman "${family}" "${os_key}"

pacman_pkg_installed() {
  pacman -Q "$1" >/dev/null 2>&1
}

pacman_pkg_available() {
  pacman -Si "$1" >/dev/null 2>&1
}

pacman_install_one() {
  ci_deps_as_root pacman -S --noconfirm --needed "$1"
}

if [[ "${mode}" == "install" ]]; then
  echo "=== Install (Linux packages) ==="
  ci_deps_as_root pacman -Sy --noconfirm archlinux-keyring
  ci_deps_as_root pacman -Syu --noconfirm
fi

PKG_SPECS=("${PKGS[@]}")
ci_deps_resolve_package_alternatives pacman_pkg_installed pacman_pkg_available

ci_deps_mode_print_or_exit
ci_deps_mode_check_or_exit pacman_pkg_installed
ci_deps_mode_install_print

if [[ "${mode}" == "install" ]]; then
  PKGS=("${PKG_SPECS[@]}")
  ci_deps_install_packages_with_alternatives \
    pacman_pkg_installed pacman_pkg_available pacman_install_one
fi
