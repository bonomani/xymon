#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-zypper-packages.sh [--print] [--check-only] [--install]
                                  --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. suse)
  --os NAME       OS key (e.g. opensuse_leap)
  --version NAME  Optional version key (e.g. 15_6)
USAGE
}

ci_deps_init_linux_installer zypper "$@"

zypper_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

zypper_pkg_available() {
  zypper --non-interactive info "$1" >/dev/null 2>&1
}

zypper_install_one() {
  ci_deps_as_root zypper --non-interactive install "$1"
}

zypper_pre_install() {
  echo "=== Install (Linux packages) ==="
  ci_deps_as_root zypper --non-interactive refresh
}

ci_deps_run_installer_modes \
  zypper_pkg_installed zypper_pkg_available zypper_install_one zypper_pre_install
