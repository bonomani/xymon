#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-zypper-packages.sh [--print] [--check-only] [--install]

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
  gcc
  gcc-c++
  make
  cmake
  ninja
  git
  findutils
  c-ares-devel
  pcre-devel
  openldap2-devel
  libopenssl-devel
  libtirpc-devel
  zlib-devel
  rrdtool-devel
)

if [[ "${mode}" == "print" ]]; then
  printf '%s\n' "${PKGS[@]}"
  exit 0
fi

if [[ "${mode}" == "check" ]]; then
  missing=0
  missing_pkgs=()
  for pkg in "${PKGS[@]}"; do
    if ! rpm -q "${pkg}" >/dev/null 2>&1; then
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

echo "=== Install (Linux packages) ==="
zypper --non-interactive refresh
zypper --non-interactive install "${PKGS[@]}"
