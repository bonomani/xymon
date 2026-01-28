#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${VARIANT:-}" ]]; then
  echo "VARIANT must be set"
  exit 1
fi

case "${VARIANT}" in
  server)
    ENABLE_SSL=ON
    ENABLE_LDAP=OFF
    LOCALCLIENT=OFF
    PKG_PKG=(gmake cmake c-ares pcre fping openldap26-client)
    PKG_PKGIN=(gmake cmake libcares pcre fping)
    PKG_PKG_ADD=(gmake cmake cares pcre gcc fping)
    PKG_PKG_ADD_OPENBSD=(gmake cmake cares pcre gcc%11 fping)
    ;;
  client)
    ENABLE_SSL=OFF
    ENABLE_LDAP=OFF
    LOCALCLIENT=OFF
    PKG_PKG=(gmake cmake pcre fping)
    PKG_PKGIN=(gmake cmake pcre fping)
    PKG_PKG_ADD=(gmake cmake pcre gcc fping)
    PKG_PKG_ADD_OPENBSD=(gmake cmake pcre gcc%11 fping)
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

BUILD_DIR=build-bsd-${VARIANT}
CMAKE_BUILD_PARALLEL_LEVEL=1
export CMAKE_BUILD_PARALLEL_LEVEL
cmake -S . -B "${BUILD_DIR}" \
  -G "Unix Makefiles" \
  -DENABLE_SSL="${ENABLE_SSL}" \
  -DENABLE_LDAP="${ENABLE_LDAP}" \
  -DXYMON_VARIANT="${VARIANT}" \
  -DLOCALCLIENT="${LOCALCLIENT}"
cmake --build "${BUILD_DIR}" --parallel 1
