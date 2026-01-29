#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" || -n "${DEBUG:-}" ]] && set -x

VARIANT="${VARIANT:-}"
ENABLE_LDAP="${ENABLE_LDAP:-}"
if [[ -z "${VARIANT}" || -z "${ENABLE_LDAP}" ]]; then
  echo "VARIANT and ENABLE_LDAP must be set"
  exit 1
fi

OS_NAME="$(uname -s)"
echo "$(uname -a)"

pick_ldap_pkg() {
  local pkgmgr="${1:-}"
  local fallback="openldap-client"
  local found=""

  case "${pkgmgr}" in
    pkg)
      found="$(/usr/sbin/pkg search -q '^openldap.*-client$' 2>/dev/null | sort -V | tail -n 1 || true)"
      ;;
    pkgin)
      found="$(/usr/pkg/bin/pkgin search '^openldap.*-client$' 2>/dev/null | awk '{print $1}' | sort -V | tail -n 1 || true)"
      ;;
    pkg_add)
      found="$(/usr/sbin/pkg_info -Q openldap\\*-client 2>/dev/null | sort -V | tail -n 1 || true)"
      ;;
  esac

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi

  if [[ "${OS_NAME}" == "OpenBSD" ]]; then
    echo "openldap26-client"
  else
    echo "${fallback}"
  fi
}

PKG_PKG=(gmake cmake pcre fping)
PKG_PKGIN=(gmake cmake pcre fping)
PKG_PKG_ADD=(gmake cmake pcre gcc fping)
PKG_PKG_ADD_OPENBSD=(gmake cmake pcre gcc%11 fping)

if [[ "${VARIANT}" == "server" ]]; then
  PKG_PKG+=(c-ares)
  PKG_PKGIN+=(libcares)
  PKG_PKG_ADD+=(cares)
  PKG_PKG_ADD_OPENBSD+=(libcares)
  if [[ "${ENABLE_LDAP}" == "ON" ]]; then
    PKG_PKG+=("$(pick_ldap_pkg pkg)")
    PKG_PKGIN+=("$(pick_ldap_pkg pkgin)")
    PKG_PKG_ADD+=("$(pick_ldap_pkg pkg_add)")
    PKG_PKG_ADD_OPENBSD+=("$(pick_ldap_pkg pkg_add)")
  fi
elif [[ "${VARIANT}" != "client" ]]; then
  echo "Unknown VARIANT: ${VARIANT}"
  exit 1
fi

if [ -x /usr/sbin/pkg ]; then
  sudo -E ASSUME_ALWAYS_YES=YES pkg install "${PKG_PKG[@]}"
  exit 0
fi

if [ -x /usr/pkg/bin/pkgin ]; then
  sudo -E /usr/pkg/bin/pkgin -y install "${PKG_PKGIN[@]}"
  exit 0
fi

if [ -x /usr/sbin/pkg_add ]; then
  if [[ "${OS_NAME}" == "OpenBSD" ]]; then
    sudo -E /usr/sbin/pkg_add -I "${PKG_PKG_ADD_OPENBSD[@]}"
  else
    sudo -E /usr/sbin/pkg_add "${PKG_PKG_ADD[@]}"
  fi
  exit 0
fi

echo "No supported package manager found"
exit 1
