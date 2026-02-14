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
Usage: install-bsd-packages.sh [--print] [--check-only] [--install]
                               [--os NAME] [--version NAME] [--pkgmgr NAME]

Options:
  --print          Print package list and exit
  --check-only     Exit 0 if all packages are installed, 1 otherwise
  --install        Install packages (default)
  --os NAME        Override OS (default: detected)
  --version NAME   Override version (default: detected)
  --pkgmgr NAME    Override package manager (pkg|pkg_add|pkgin)
USAGE
}

mode="install"
print_list="0"
os_override=""
version_override=""
pkgmgr_override="${BSD_PKGMGR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      print_list="1"
      if [[ "${mode}" == "install" ]]; then
        mode="print"
      fi
      shift
      ;;
    --check-only)
      mode="check"
      shift
      ;;
    --install)
      mode="install"
      shift
      ;;
    --os)
      os_override="$2"
      shift 2
      ;;
    --version)
      version_override="$2"
      shift 2
      ;;
    --pkgmgr)
      pkgmgr_override="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

ci_deps_setup_variant_defaults

bsd_init_os_context "${os_override:-$(uname -s)}" "${version_override}"
default_pkgmgr="$(bsd_default_pkgmgr_for_os "${BSD_OS_LOWER}")"
selected_pkgmgr="${pkgmgr_override:-${default_pkgmgr}}"

case "${selected_pkgmgr}" in
  pkg)
    target_script="${script_dir}/install-pkg-packages.sh"
    ;;
  pkg_add)
    target_script="${script_dir}/install-pkg-add-packages.sh"
    ;;
  pkgin)
    target_script="${script_dir}/install-pkgin-packages.sh"
    ;;
  *)
    echo "Unsupported BSD package manager: ${selected_pkgmgr}" >&2
    exit 2
    ;;
esac

forward_args=()
case "${mode}" in
  print)
    forward_args+=(--print)
    ;;
  check)
    if [[ "${print_list}" == "1" ]]; then
      forward_args+=(--print)
    fi
    forward_args+=(--check-only)
    ;;
  install)
    if [[ "${print_list}" == "1" ]]; then
      forward_args+=(--print --install)
    fi
    ;;
  *)
    echo "Unsupported mode: ${mode}" >&2
    exit 2
    ;;
esac

forward_args+=(--os "${BSD_OS_LOWER}")
if [[ -n "${BSD_OS_VERSION}" ]]; then
  forward_args+=(--version "${BSD_OS_VERSION}")
fi

exec "${target_script}" "${forward_args[@]}"
