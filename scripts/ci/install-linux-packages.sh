#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-linux-packages.sh [--print] [--check-only] [--install]
                               [--distro-family NAME] [--distro NAME] [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --distro-family NAME  Override distro family (default: debian)
  --distro NAME         Override distro (default: ubuntu)
  --version NAME        Override version (default: latest)
USAGE
}

mode="install"
print_list="0"
distro_family="debian"
distro="ubuntu"
version="latest"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      print_list="1"
      if [[ "${mode}" == "install" ]]; then
        mode="print"
      fi
      shift
      ;;
    --check-only) mode="check"; shift ;;
    --install) mode="install"; shift ;;
    --distro-family) distro_family="$2"; shift 2 ;;
    --distro) distro="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done
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
  missing_pkgs=()
  for pkg in "${ALL_PKGS[@]}"; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
      missing=1
      missing_pkgs+=("${pkg}")
    fi
  done
  if [[ "${print_list}" == "1" && "${missing}" == "1" ]]; then
    printf '%s\n' "${missing_pkgs[@]}"
  fi
  exit "${missing}"
fi

if [[ "${mode}" == "install" && "${print_list}" == "1" ]]; then
  printf '%s\n' "${ALL_PKGS[@]}"
fi

echo "=== Install (Linux packages) ==="

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  "${ALL_PKGS[@]}"
