#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-apk-packages.sh [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. alpine)
  --os NAME       OS key (e.g. alpine)
  --version NAME  Optional version key (e.g. 3)
USAGE
}

ci_deps_init_linux_installer apk "$@"

apk_pkg_installed() {
  apk info -e "$1" >/dev/null 2>&1
}

apk_pkg_available() {
  apk search -x "$1" >/dev/null 2>&1
}

apk_install_one() {
  ci_deps_as_root apk add --no-cache "$1"
}

ci_deps_run_installer_modes \
  apk_pkg_installed "" apk_install_one "" "=== Install (Linux packages) ==="
