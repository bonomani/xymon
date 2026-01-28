#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${OS_NAME:-}" || -z "${VARIANT:-}" ]]; then
  echo "OS_NAME and VARIANT must be set"
  exit 1
fi

case "${VARIANT}" in
  server)
    ENABLE_SSL=ON
    ENABLE_LDAP=OFF
    LOCALCLIENT=OFF
    PKG_PKG="gmake cmake c-ares pcre fping openldap26-client"
    PKG_PKGIN="gmake cmake libcares pcre fping"
    PKG_PKG_ADD="gmake cmake cares pcre gcc fping"
    PKG_PKG_ADD_OPENBSD="gmake cmake cares pcre gcc%11 fping"
    ;;
  client)
    ENABLE_SSL=OFF
    ENABLE_LDAP=OFF
    LOCALCLIENT=OFF
    PKG_PKG="gmake cmake pcre fping autotools"
    PKG_PKGIN="gmake cmake pcre fping autoconf automake"
    PKG_PKG_ADD="gmake cmake pcre gcc fping automake autoconf"
    PKG_PKG_ADD_OPENBSD="gmake cmake pcre gcc%11 fping automake%1.16 autoconf%2.71"
    ;;
  *)
    echo "Unknown VARIANT: ${VARIANT}"
    exit 1
    ;;
esac

uname -a
if uname -a | grep -qi freebsd; then
  sudo pw user add -n xymon -c 'xymon' -d /home/xymon -G wheel -m -s /usr/local/bin/bash || true
elif [ -x /usr/sbin/useradd ]; then
  sudo /usr/sbin/useradd xymon || true
elif [ -x /usr/sbin/adduser ]; then
  grep -q xymon /etc/passwd || sudo /usr/sbin/adduser -w no -s /bin/sh -q xymon
fi

if [ -x /usr/sbin/pkg ]; then
  sudo -E ASSUME_ALWAYS_YES=YES pkg install ${PKG_PKG}
elif [ -x /usr/pkg/bin/pkgin ]; then
  sudo -E /usr/pkg/bin/pkgin -y install ${PKG_PKGIN}
elif [ -x /usr/sbin/pkg_add ]; then
  if uname -a | grep -qi openbsd; then
    sudo -E /usr/sbin/pkg_add -I ${PKG_PKG_ADD_OPENBSD}
  else
    sudo -E /usr/sbin/pkg_add ${PKG_PKG_ADD}
  fi
else
  echo "No supported package manager found"
  exit 1
fi

BUILD_DIR=build-bsd-${VARIANT}
cmake -S . -B "${BUILD_DIR}" \
  -G "Unix Makefiles" \
  -DENABLE_SSL="${ENABLE_SSL}" \
  -DENABLE_LDAP="${ENABLE_LDAP}" \
  -DXYMON_VARIANT="${VARIANT}" \
  -DLOCALCLIENT="${LOCALCLIENT}"
cmake --build "${BUILD_DIR}" --parallel 1
