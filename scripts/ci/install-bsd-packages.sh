#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" || -n "${DEBUG:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-bsd-packages.sh [--print] [--check-only] [--install]

Options:
  --print    Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install  Install packages (default)
USAGE
}

mode="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) mode="print"; shift ;;
    --check-only) mode="check"; shift ;;
    --install) mode="install"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

VARIANT="${VARIANT:-}"
ENABLE_LDAP="${ENABLE_LDAP:-}"
if [[ -z "${VARIANT}" || -z "${ENABLE_LDAP}" ]]; then
  echo "VARIANT and ENABLE_LDAP must be set"
  exit 1
fi

OS_NAME="$(uname -s)"
echo "$(uname -a)"
echo "=== Install (BSD packages) ==="

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packages-bsd.sh
source "${script_dir}/packages-bsd.sh"

PKG_MGR=""
case "${OS_NAME}" in
  FreeBSD) PKG_MGR="pkg" ;;
  NetBSD) PKG_MGR="pkgin" ;;
  OpenBSD) PKG_MGR="pkg_add" ;;
  *)
    echo "Unsupported BSD OS: ${OS_NAME}"
    exit 1
    ;;
esac

pick_ldap_pkg() {
  local pkgmgr="${1:-}"
  local found=""
  local probe_out=""

  normalize_pkg_name() {
    sed 's/-[0-9].*$//'
  }

  pick_openldap_variant() {
    local ambiguous="${1:-}"
    local picked=""

    picked="$(
      echo "${ambiguous}" \
        | tr ' ' '\n' \
        | grep '^openldap-client-' \
        | grep -v 'gssapi' \
        | head -n 1 || true
    )"
    if [[ -z "${picked}" ]]; then
      picked="$(
        echo "${ambiguous}" \
          | tr ' ' '\n' \
          | grep '^openldap-client-' \
          | head -n 1 || true
      )"
    fi

    echo "${picked}"
  }

  case "${pkgmgr}" in
    pkg)
      if [ -x /usr/sbin/pkg ]; then
        found="$(
          /usr/sbin/pkg search -q '^openldap.*client' 2>/dev/null \
            | normalize_pkg_name \
            | sort -V \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkgin)
      if [ -x /usr/pkg/bin/pkgin ]; then
        found="$(
          /usr/pkg/bin/pkgin search '^openldap.*-client' 2>/dev/null \
            | awk '{print $1}' \
            | normalize_pkg_name \
            | sort -V \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkg_add)
      if [ -x /usr/sbin/pkg_add ]; then
        set +e
        probe_out="$(/usr/sbin/pkg_add -n openldap-client 2>&1)"
        set -e
        if echo "${probe_out}" | grep -q '^Ambiguous:'; then
          found="$(pick_openldap_variant "${probe_out}")"
        elif /usr/sbin/pkg_add -n openldap-client >/dev/null 2>&1; then
          found="openldap-client"
        fi
      fi
      ;;
  esac

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi
}

mapfile -t PKG_PKG < <(ci_bsd_packages pkg "${VARIANT}")
mapfile -t PKG_PKGIN < <(ci_bsd_packages pkgin "${VARIANT}")
mapfile -t PKG_PKG_ADD < <(ci_bsd_packages pkg_add "${VARIANT}")

if [[ "${VARIANT}" == "server" ]]; then
  :
elif [[ "${VARIANT}" != "client" ]]; then
  echo "Unknown VARIANT: ${VARIANT}"
  exit 1
fi

if [[ "${ENABLE_LDAP}" == "ON" && "${VARIANT}" == "server" ]]; then
  LDAP_PKG="$(pick_ldap_pkg "${PKG_MGR}")"
  if [[ -n "${LDAP_PKG}" ]]; then
    PKG_PKG+=("${LDAP_PKG}")
    PKG_PKGIN+=("${LDAP_PKG}")
    PKG_PKG_ADD+=("${LDAP_PKG}")
  fi
fi

case "${mode}" in
  print)
    case "${PKG_MGR}" in
      pkg) printf '%s\n' "${PKG_PKG[@]}" ;;
      pkgin) printf '%s\n' "${PKG_PKGIN[@]}" ;;
      pkg_add) printf '%s\n' "${PKG_PKG_ADD[@]}" ;;
    esac
    exit 0
    ;;
  check)
    case "${PKG_MGR}" in
      pkg)
        missing=0
        for pkg in "${PKG_PKG[@]}"; do
          if ! /usr/sbin/pkg info -e "${pkg}" >/dev/null 2>&1; then
            missing=1
            break
          fi
        done
        exit "${missing}"
        ;;
      pkgin)
        missing=0
        for pkg in "${PKG_PKGIN[@]}"; do
          if ! /usr/pkg/bin/pkg_info -e "${pkg}" >/dev/null 2>&1; then
            missing=1
            break
          fi
        done
        exit "${missing}"
        ;;
      pkg_add)
        missing=0
        for pkg in "${PKG_PKG_ADD[@]}"; do
          if ! /usr/sbin/pkg_info -e "${pkg}" >/dev/null 2>&1; then
            missing=1
            break
          fi
        done
        exit "${missing}"
        ;;
    esac
    ;;
  install)
    case "${PKG_MGR}" in
      pkg)
        sudo -E ASSUME_ALWAYS_YES=YES pkg install "${PKG_PKG[@]}"
        exit 0
        ;;
      pkgin)
        sudo -E /usr/pkg/bin/pkgin -y install "${PKG_PKGIN[@]}"
        exit 0
        ;;
      pkg_add)
        sudo -E /usr/sbin/pkg_add -I "${PKG_PKG_ADD[@]}"
        exit 0
        ;;
    esac
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "No supported package manager found"
exit 1
