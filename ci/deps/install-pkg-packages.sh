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
Usage: install-pkg-packages.sh [--print] [--check-only] [--install]
                               --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --os NAME       OS key (supported: freebsd)
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
bsd_require_os_for_pkgmgr pkg
bsd_resolve_packages pkg
export report_pkgmgr="pkg"

pkg_pkg_installed() {
  bsd_pkg_installed pkg "$1"
}

pkg_pkg_available() {
  bsd_pkg_available pkg "$1"
}

pkg_install_one() {
  ci_deps_as_root env ASSUME_ALWAYS_YES=YES pkg install "$1"
}

ci_deps_run_installer_modes \
  pkg_pkg_installed pkg_pkg_available pkg_install_one "" "=== Install (BSD pkg packages) ==="
