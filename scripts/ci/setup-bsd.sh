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

PKG_COMMON=(gmake cmake pcre fping)
PKG_SERVER_PKG=(c-ares)
PKG_SERVER_PKGIN=(libcares)
PKG_SERVER_PKG_ADD=(libcares)

PKG_MGR=""
case "${OS_NAME}" in
  FreeBSD) PKG_MGR="pkg" ;;
  NetBSD) PKG_MGR="pkgin" ;;
  OpenBSD) PKG_MGR="pkg_add" ;;
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

PKG_PKG=("${PKG_COMMON[@]}")
PKG_PKGIN=("${PKG_COMMON[@]}")
PKG_PKG_ADD=("${PKG_COMMON[@]}")

if [[ "${VARIANT}" == "server" ]]; then
  PKG_PKG+=("${PKG_SERVER_PKG[@]}")
  PKG_PKGIN+=("${PKG_SERVER_PKGIN[@]}")
  PKG_PKG_ADD+=("${PKG_SERVER_PKG_ADD[@]}")
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

echo "No supported package manager found"
exit 1
