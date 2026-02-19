#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-brew-packages.sh [--print] [--check-only] [--install]
                                --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. macos)
  --os NAME       OS key (e.g. macos)
  --version NAME  Optional version key (e.g. latest)
USAGE
}

ci_deps_init_cli
ci_deps_parse_cli 1 1 "$@"
ci_deps_setup_variant_defaults
ci_deps_build_os_key
ci_deps_resolve_packages brew "${family}" "${os_key}"

brew_pkg_installed() {
  brew list --versions "$1" >/dev/null 2>&1
}

brew_pkg_available() {
  brew info --formula "$1" >/dev/null 2>&1
}

if [[ "${mode}" == "install" ]]; then
  echo "=== Install (Homebrew packages) ==="
  brew update
fi

ci_deps_resolve_package_alternatives brew_pkg_installed brew_pkg_available

ci_deps_mode_print_or_exit
ci_deps_mode_check_or_exit brew_pkg_installed
ci_deps_mode_install_print

if [[ "${mode}" == "install" ]]; then
  brew install "${PKGS[@]}"
fi
