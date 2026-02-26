#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-apt-packages.sh [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. gh-debian, debian, ubuntu)
  --os NAME       OS key (e.g. ubuntu, debian)
  --version NAME  Optional version key (e.g. latest, local, 20, bookworm)
USAGE
}

ci_deps_init_linux_installer apt "$@"

apt_pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

apt_pkg_available() {
  local candidate=""
  candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')"
  [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
}

apt_install_one() {
  ci_deps_as_root env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    apt-get install -y --no-install-recommends "$1"
}

apt_pre_install() {
  echo "=== Install (Linux packages) ==="
  ci_deps_as_root env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get update
}

ci_deps_run_installer_modes \
  apt_pkg_installed apt_pkg_available apt_install_one apt_pre_install
