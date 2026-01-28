#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${VARIANT:-}" ]]; then
  echo "VARIANT must be set"
  exit 1
fi

PKG_PKG_BASE=(gmake cmake pcre fping)
PKG_PKGIN_BASE=(gmake cmake pcre fping)
PKG_PKG_ADD_BASE=(gmake cmake pcre gcc fping)
PKG_PKG_ADD_OPENBSD_BASE=(gmake cmake pcre gcc%11 fping)

case "${VARIANT}" in
  server)
    PKG_PKG=("${PKG_PKG_BASE[@]}" c-ares openldap26-client)
    PKG_PKGIN=("${PKG_PKGIN_BASE[@]}" libcares)
    PKG_PKG_ADD=("${PKG_PKG_ADD_BASE[@]}" cares)
    PKG_PKG_ADD_OPENBSD=("${PKG_PKG_ADD_OPENBSD_BASE[@]}" cares)
    ;;
  client)
    PKG_PKG=("${PKG_PKG_BASE[@]}")
    PKG_PKGIN=("${PKG_PKGIN_BASE[@]}")
    PKG_PKG_ADD=("${PKG_PKG_ADD_BASE[@]}")
    PKG_PKG_ADD_OPENBSD=("${PKG_PKG_ADD_OPENBSD_BASE[@]}")
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
echo "$(uname -a)"

if [ -x /usr/sbin/pkg ]; then
  sudo -E ASSUME_ALWAYS_YES=YES pkg install "${PKG_PKG[@]}"
elif [ -x /usr/pkg/bin/pkgin ]; then
  sudo -E /usr/pkg/bin/pkgin -y install "${PKG_PKGIN[@]}"
elif [ -x /usr/sbin/pkg_add ]; then
  if [[ "${OS_NAME}" == "OpenBSD" ]]; then
    sudo -E /usr/sbin/pkg_add -I "${PKG_PKG_ADD_OPENBSD[@]}"
  else
    sudo -E /usr/sbin/pkg_add "${PKG_PKG_ADD[@]}"
  fi
else
  echo "No supported package manager found"
  exit 1
fi
