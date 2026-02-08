#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-apt-packages.sh [--print] [--check-only] [--install]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
USAGE
}

mode="install"
print_list="0"
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
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

PKGS=(
  build-essential
  cmake
  ninja-build
  git
  findutils
  libc-ares-dev
  libpcre3-dev
  libldap2-dev
  librrd-dev
  libssl-dev
  libtirpc-dev
  zlib1g-dev
)

if [[ "${mode}" == "print" ]]; then
  printf '%s\n' "${PKGS[@]}"
  exit 0
fi

if [[ "${mode}" == "check" ]]; then
  missing=0
  missing_pkgs=()
  for pkg in "${PKGS[@]}"; do
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
  printf '%s\n' "${PKGS[@]}"
fi

as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

echo "=== Install (Linux packages) ==="
as_root apt-get update
as_root DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
