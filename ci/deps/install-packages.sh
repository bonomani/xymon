#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-packages.sh --pkgmgr NAME [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --pkgmgr NAME  Package manager key used for installation helpers
  --print        Print package list and exit
  --check-only   Exit 0 if all packages are installed, 1 otherwise
  --install      Install packages (default)
  --family NAME  Dependency family (e.g. rpm, ubuntu)
  --os NAME      OS key (e.g. centos, ubuntu)
  --version NAME Optional version key (e.g. 7, latest)
  --build-tool   Resolve build-specific deps (make|cmake)
USAGE
  exit 2
}

pkgmgr=""
remaining_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkgmgr)
      pkgmgr="$2"
      shift 2
      ;;
    --pkgmgr=*)
      pkgmgr="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      remaining_args+=("$1")
      shift
      ;;
  esac
done

if [[ -z "${pkgmgr}" ]]; then
  echo "Missing required --pkgmgr flag" >&2
  usage
fi

pkgmgr="$(printf '%s' "${pkgmgr}" | tr '[:upper:]' '[:lower:]')"

if ! ci_deps_init_linux_installer "${pkgmgr}" "${remaining_args[@]}"; then
  exit $?
fi

backend_script="${script_dir}/pkgmgr/${pkgmgr}.sh"
if [[ ! -f "${backend_script}" ]]; then
  echo "Unsupported package manager: ${pkgmgr}" >&2
  exit 2
fi

source "${backend_script}"

if ! type pkg_installed >/dev/null 2>&1; then
  echo "Package backend ${pkgmgr} is missing pkg_installed()" >&2
  exit 2
fi

if ! type pkg_install_one >/dev/null 2>&1; then
  echo "Package backend ${pkgmgr} is missing pkg_install_one()" >&2
  exit 2
fi

pkg_available_fn=""
if type pkg_available >/dev/null 2>&1; then
  pkg_available_fn="pkg_available"
fi

pre_install_fn=""
if type pkg_pre_install >/dev/null 2>&1; then
  pre_install_fn="pkg_pre_install"
fi

install_banner="${pkgmgr_install_banner:-}"

ci_deps_run_installer_modes \
  pkg_installed \
  "${pkg_available_fn}" \
  pkg_install_one \
  "${pre_install_fn}" \
  "${install_banner}"
