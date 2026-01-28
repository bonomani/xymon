#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -n "${DEBUG:-}" ]]; then
  set -x
fi

if [[ -z "${VARIANT:-}" || -z "${ENABLE_LDAP:-}" ]]; then
  echo "VARIANT and ENABLE_LDAP must be set"
  exit 1
fi

BASE_PKGS=(gmake cmake pcre fping)
BASE_PKGIN=(gmake cmake pcre fping)
BASE_PKG_ADD=(gmake cmake pcre gcc fping)
BASE_PKG_ADD_OPENBSD=(gmake cmake pcre gcc%11 fping)

case "${VARIANT}" in
  server)
    PKG_PKG=("${BASE_PKGS[@]}" c-ares)
    PKG_PKGIN=("${BASE_PKGIN[@]}" libcares)
    PKG_PKG_ADD=("${BASE_PKG_ADD[@]}" cares)
    PKG_PKG_ADD_OPENBSD=("${BASE_PKG_ADD_OPENBSD[@]}" __CARES_PKG__)
    if [[ "${ENABLE_LDAP}" == "ON" ]]; then
      PKG_PKG+=("openldap26-client")
    fi
    ;;
  client)
    PKG_PKG=("${BASE_PKGS[@]}")
    PKG_PKGIN=("${BASE_PKGIN[@]}")
    PKG_PKG_ADD=("${BASE_PKG_ADD[@]}")
    PKG_PKG_ADD_OPENBSD=("${BASE_PKG_ADD_OPENBSD[@]}")
    ;;
  *)
    echo "Unknown VARIANT: ${VARIANT}"
    exit 1
    ;;
esac

if [[ ${#PKG_PKG[@]} -eq 0 || ${#PKG_PKGIN[@]} -eq 0 || ${#PKG_PKG_ADD[@]} -eq 0 || ${#PKG_PKG_ADD_OPENBSD[@]} -eq 0 ]]; then
  echo "Package lists are not fully defined for VARIANT=${VARIANT}"
  exit 1
fi

OS_NAME="$(uname -s)"
OS_RELEASE="$(uname -r)"
OS_ARCH="$(uname -m)"
echo "$(uname -a)"

if [ -x /usr/sbin/pkg ]; then
  sudo -E ASSUME_ALWAYS_YES=YES pkg install "${PKG_PKG[@]}"
elif [ -x /usr/pkg/bin/pkgin ]; then
  sudo -E /usr/pkg/bin/pkgin -y install "${PKG_PKGIN[@]}"
elif [ -x /usr/sbin/pkg_add ]; then
  if [[ "${OS_NAME}" == "OpenBSD" ]]; then
    MIRRORS=(
      https://cdn.openbsd.org/pub/OpenBSD
      https://cloudflare.cdn.openbsd.org/pub/OpenBSD
      https://openbsd.as250.net/pub/OpenBSD
      https://ftp2.eu.openbsd.org/pub/OpenBSD
    )
    CARES_CANDIDATES=(c-ares cares)

    INSTALL_OK=0
    for mirror in "${MIRRORS[@]}"; do
      export PKG_PATH="${mirror}/${OS_RELEASE}/packages/${OS_ARCH}/"
      for cares in "${CARES_CANDIDATES[@]}"; do
        PKG_PKG_ADD_OPENBSD=("${PKG_PKG_ADD_OPENBSD[@]/__CARES_PKG__/${cares}}")
        if sudo -E /usr/sbin/pkg_add -I "${PKG_PKG_ADD_OPENBSD[@]}"; then
          INSTALL_OK=1
          break 2
        fi
      done
    done
    if [[ "${INSTALL_OK}" -ne 1 ]]; then
      echo "Failed to install packages from OpenBSD mirrors"
      exit 1
    fi
  else
    sudo -E /usr/sbin/pkg_add "${PKG_PKG_ADD[@]}"
  fi
else
  echo "No supported package manager found"
  exit 1
fi
