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

ci_deps_init_linux_installer brew "$@"

brew_pkg_installed() {
  brew list --versions "$1" >/dev/null 2>&1
}

brew_pkg_available() {
  brew info --formula "$1" >/dev/null 2>&1
}

brew_install_one() {
  brew install "$1"
}

brew_pre_install() {
  echo "=== Install (Homebrew packages) ==="
  brew update
}

ci_deps_run_installer_modes \
  brew_pkg_installed brew_pkg_available brew_install_one brew_pre_install
