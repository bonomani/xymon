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
  local -a candidates=()

  if [[ "${OS_NAME}" == "OpenBSD" ]]; then
    candidates=(openldap-client openldap27-client openldap26-client)
  else
    candidates=(openldap-client openldap26-client openldap27-client)
  fi

  case "${pkgmgr}" in
    pkg)
      if [ -x /usr/sbin/pkg ]; then
        for pkg in "${candidates[@]}"; do
          if /usr/sbin/pkg search -q -e "${pkg}" >/dev/null 2>&1; then
            found="${pkg}"
            break
          fi
        done
      fi
      ;;
    pkgin)
      if [ -x /usr/pkg/bin/pkgin ]; then
        found="$(/usr/pkg/bin/pkgin search '^openldap.*-client$' 2>/dev/null | awk '{print $1}' | sort -V | tail -n 1 || true)"
      fi
      ;;
    pkg_add)
      if [ -x /usr/sbin/pkg_add ]; then
        for pkg in "${candidates[@]}"; do
          probe_out="$(
            /usr/sbin/pkg_add -n "${pkg}" 2>&1 || true
          )"
          if echo "${probe_out}" | grep -q '^Ambiguous:'; then
            found="$(echo "${probe_out}" | tr ' ' '\n' | grep '^openldap-client-' | head -n 1 || true)"
            if [[ -n "${found}" ]]; then
              break
            fi
          elif /usr/sbin/pkg_add -n "${pkg}" >/dev/null 2>&1; then
            found="${pkg}"
            break
          fi
        done
      fi
      ;;
  esac

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi

  if [[ "${OS_NAME}" == "OpenBSD" ]]; then
    echo "${candidates[0]}"
  else
    echo "${fallback}"
  fi
}

PKG_PKG=(gmake cmake pcre fping)
PKG_PKGIN=(gmake cmake pcre fping)
PKG_PKG_ADD=(gmake cmake pcre gcc fping)
PKG_PKG_ADD_OPENBSD=(gmake cmake pcre gcc%11 fping)
PKG_MGR=""

if [ -x /usr/sbin/pkg ]; then
  PKG_MGR="pkg"
elif [ -x /usr/pkg/bin/pkgin ]; then
  PKG_MGR="pkgin"
elif [ -x /usr/sbin/pkg_add ]; then
  PKG_MGR="pkg_add"
fi

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
