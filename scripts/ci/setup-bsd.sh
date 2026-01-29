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
  local probe_out=""

  case "${pkgmgr}" in
    pkg)
      if [ -x /usr/sbin/pkg ]; then
        found="$(
          /usr/sbin/pkg search -q '^openldap.*client' 2>/dev/null \
            | sed 's/-[0-9].*$//' \
            | sort -u \
            | sort -V \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkgin)
      if [ -x /usr/pkg/bin/pkgin ]; then
        found="$(/usr/pkg/bin/pkgin search '^openldap.*-client$' 2>/dev/null | awk '{print $1}' | sort -V | tail -n 1 || true)"
      fi
      ;;
    pkg_add)
      if [ -x /usr/sbin/pkg_add ]; then
        probe_out="$(/usr/sbin/pkg_add -n openldap-client 2>&1 || true)"
        if echo "${probe_out}" | grep -q '^Ambiguous:'; then
          found="$(
            echo "${probe_out}" \
              | tr ' ' '\n' \
              | grep '^openldap-client-' \
              | grep -v 'gssapi' \
              | head -n 1 || true
          )"
          if [[ -z "${found}" ]]; then
            found="$(
              echo "${probe_out}" \
                | tr ' ' '\n' \
                | grep '^openldap-client-' \
                | head -n 1 || true
            )"
          fi
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

  echo "${fallback}"
}

PKG_PKG=(gmake cmake pcre fping)
PKG_PKGIN=(gmake cmake pcre fping)
PKG_PKG_ADD=(gmake cmake pcre gcc fping)
PKG_PKG_ADD_OPENBSD=(gmake cmake pcre gcc%11 fping)
PKG_MGR=""
case "${OS_NAME}" in
  FreeBSD) PKG_MGR="pkg" ;;
  NetBSD) PKG_MGR="pkgin" ;;
  OpenBSD) PKG_MGR="pkg_add" ;;
esac

if [[ "${VARIANT}" == "server" ]]; then
  PKG_PKG+=(c-ares)
  PKG_PKGIN+=(libcares)
  PKG_PKG_ADD+=(cares)
  PKG_PKG_ADD_OPENBSD+=(libcares)
  if [[ "${ENABLE_LDAP}" == "ON" ]]; then
    LDAP_PKG="$(pick_ldap_pkg "${PKG_MGR}")"
    if [[ -n "${LDAP_PKG}" ]]; then
      PKG_PKG+=("${LDAP_PKG}")
      PKG_PKGIN+=("${LDAP_PKG}")
      PKG_PKG_ADD+=("${LDAP_PKG}")
      PKG_PKG_ADD_OPENBSD+=("${LDAP_PKG}")
    fi
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
