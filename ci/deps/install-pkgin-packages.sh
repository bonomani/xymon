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
Usage: install-pkgin-packages.sh [--print] [--check-only] [--install]
                                 --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --os NAME       OS key (supported: netbsd)
  --version NAME  Optional version key
USAGE
}

ci_deps_init_cli
ci_deps_parse_cli 0 1 "$@"
ci_deps_setup_variant_defaults
# Populated by ci_deps_parse_cli from install-common.sh.
os_name="${os_name:-}"
version="${version:-}"
bsd_init_os_context "${os_name}" "${version}"
bsd_require_os_for_pkgmgr pkgin

# pkgin currently reuses the NetBSD pkg_add dependency set in deps YAML.
bsd_resolve_packages pkgin pkg_add
export report_pkgmgr="pkgin"

pkgin_pkg_installed() {
  bsd_pkg_installed pkgin "$1"
}

pkgin_pkg_available() {
  bsd_pkg_available pkgin "$1"
}

pkgin_install_one() {
  ci_deps_as_root /usr/pkg/bin/pkgin -y install "$1"
}

ci_deps_run_installer_modes \
  pkgin_pkg_installed pkgin_pkg_available pkgin_install_one "" "=== Install (BSD pkgin packages) ==="
