#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-linux-packages.sh [--print] [--check-only] [--install] [profile] [distro_family distro version]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  profile       linux|debian (default: linux)
  distro_family distro version  Override distro metadata (default: debian ubuntu latest)
USAGE
}

mode="install"
profile="linux"
distro_family="debian"
distro="ubuntu"
version="latest"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) mode="print"; shift ;;
    --check-only) mode="check"; shift ;;
    --install) mode="install"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ "${profile}" == "linux" && ( "$1" == "linux" || "$1" == "debian" ) ]]; then
        profile="$1"
        shift
      else
        if [[ $# -lt 3 ]]; then
          echo "Expected distro_family distro version (got: $*)" >&2
          exit 1
        fi
        distro_family="$1"
        distro="$2"
        version="$3"
        shift 3
      fi
      ;;
  esac
done

PROFILE="${profile:-linux}"
if [[ "${PROFILE}" == "linux" ]]; then
  PROFILE="debian"
fi
ENABLE_LDAP="${ENABLE_LDAP:-ON}"
VARIANT="${VARIANT:-all}"
CI_COMPILER="${CI_COMPILER:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packages-linux.sh
source "${script_dir}/packages-linux.sh"

mapfile -t ALL_PKGS < <(ci_linux_packages "${distro_family}" "${distro}" "${version}" "${VARIANT}" "${ENABLE_LDAP}" "${CI_COMPILER}")

if [[ "${mode}" == "print" ]]; then
  printf '%s\n' "${ALL_PKGS[@]}"
  exit 0
fi

if [[ "${mode}" == "check" ]]; then
  missing=0
  for pkg in "${ALL_PKGS[@]}"; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
      missing=1
      break
    fi
  done
  exit "${missing}"
fi

echo "=== Install (Linux packages) ==="

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  "${ALL_PKGS[@]}"
