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

ci_deps_init_cli
ci_deps_parse_cli 1 1 "$@"
ci_deps_setup_variant_defaults
ci_deps_build_os_key
ci_deps_resolve_packages zypper "${family}" "${os_key}"

zypper_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

ci_deps_mode_print_or_exit
ci_deps_mode_check_or_exit zypper_pkg_installed
ci_deps_mode_install_print

echo "=== Install (Linux packages) ==="
ci_deps_as_root zypper --non-interactive refresh
ci_deps_as_root zypper --non-interactive install "${PKGS[@]}"
