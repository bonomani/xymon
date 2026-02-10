#!/usr/bin/env bash
set -euo pipefail

OS_NAME=""
OS_VERSION=""
REF_NAME=""
KEYFILES_NAME=""
VARIANT=""
CONFTYPE=""
CLIENTONLY=""
LOCALCLIENT=""
HTTPDGID=""
BUILD_TOOL="make"

while [ $# -gt 0 ]; do
  case "$1" in
    --os)
      OS_NAME="${2:-}"
      shift 2
      ;;
    --version)
      OS_VERSION="${2:-}"
      shift 2
      ;;
    --ref-name)
      REF_NAME="${2:-}"
      shift 2
      ;;
    --keyfiles-name)
      KEYFILES_NAME="${2:-}"
      shift 2
      ;;
    --variant)
      VARIANT="${2:-}"
      shift 2
      ;;
    --conftype)
      CONFTYPE="${2:-}"
      shift 2
      ;;
    --clientonly)
      CLIENTONLY="${2:-}"
      shift 2
      ;;
    --localclient)
      LOCALCLIENT="${2:-}"
      shift 2
      ;;
    --build)
      BUILD_TOOL="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$OS_NAME" ]; then
  echo "Missing --os" >&2
  exit 1
fi
if [ "$OS_NAME" = "ubuntu" ]; then
  OS_NAME="linux"
fi

LEGACY_STAGING="/tmp/xymon-stage"
LEGACY_DESTROOT="/tmp/xymon-stage/var/lib/xymon"
LEGACY_DESTROOT_FALLBACK="/tmp/var/lib/xymon"
DEFAULT_TOP="/var/lib/xymon"
MAKE_BIN="make"
CARES_PREFIX=""

as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

set_variant_flags() {
  VARIANT="${VARIANT:-server}"
  if [ "${VARIANT}" = "server" ]; then
    ENABLE_LDAP=ON
    ENABLE_SNMP=ON
  else
    ENABLE_LDAP=OFF
    ENABLE_SNMP=OFF
  fi
  export VARIANT ENABLE_LDAP ENABLE_SNMP
}

ensure_group() {
  if [ "$OS_NAME" = "freebsd" ]; then
    as_root pw groupadd "$1" 2>/dev/null || true
  else
    as_root groupadd "$1" 2>/dev/null || true
  fi
}

ensure_user() {
  if [ "$OS_NAME" = "freebsd" ]; then
    as_root pw useradd -n xymon -m -s /bin/sh 2>/dev/null || true
  else
    as_root useradd -m -s /bin/sh xymon 2>/dev/null || true
  fi
}

ensure_user_group() {
  ensure_group "$1"
  ensure_user
}

ensure_gmake() {
  if command -v gmake >/dev/null 2>&1; then
    return
  fi
  if command -v make >/dev/null 2>&1; then
    as_root ln -sf "$(command -v make)" /usr/local/bin/gmake
  fi
}

detect_cares_prefix() {
  CARES_PREFIX=""
  local fallback=""
  for candidate in "$@"; do
    [ -n "${candidate}" ] || continue
    if [ -z "${fallback}" ]; then
      fallback="${candidate}"
    fi
    if [ -f "${candidate}/include/ares.h" ]; then
      CARES_PREFIX="${candidate}"
      return
    fi
  done
  if [ -n "${fallback}" ]; then
    CARES_PREFIX="${fallback}"
  fi
}

install_default_packages() {
  bash ci/deps/install-default-packages.sh
}

prepare_os() {
  local http_group="$1"
  shift
  HTTPDGID="$http_group"
  MAKE_BIN="gmake"
  set_variant_flags
  install_default_packages
  ensure_gmake
  detect_cares_prefix "$@"
  ensure_user_group "$HTTPDGID"
}

setup_os() {
  case "$OS_NAME" in
    linux)
      prepare_os "www-data" "/usr/local" "/usr" "/usr/pkg"
      ;;
    freebsd)
      prepare_os "www" "/usr/local" "/usr/pkg"
      ;;
    openbsd)
      prepare_os "www" "/usr/local" "/usr/pkg"
      ;;
    netbsd)
      prepare_os "www" "/usr/pkg" "/usr/local" "/usr/pkg"
      if [ -x /usr/pkg/bin/gmake ]; then
        export PATH="/usr/pkg/bin:${PATH}"
      fi
      ;;
    *)
      echo "Unsupported OS: $OS_NAME" >&2
      exit 1
      ;;
  esac
}

configure_build() {
  export ENABLESSL=y
  export ENABLELDAP=y
  export XYMONUSER=xymon
  export HTTPDGID="${HTTPDGID:-www}"
  export XYMONTOPDIR="${DEFAULT_TOP}"
  export CC=cc
  if [ -z "${CONFTYPE}" ]; then
    if [ -n "${CLIENTONLY}" ] || [ -n "${LOCALCLIENT}" ]; then
      case "${LOCALCLIENT}" in
        yes|YES|on|ON|1|true|TRUE)
          CONFTYPE="client"
          ;;
        *)
          if [ -n "${CLIENTONLY}" ]; then
            CONFTYPE="server"
          fi
          ;;
      esac
    else
      case "${VARIANT:-server}" in
        client)
          CLIENTONLY=yes
          LOCALCLIENT=no
          CONFTYPE="server"
          ;;
        localclient)
          CLIENTONLY=yes
          LOCALCLIENT=yes
          CONFTYPE="client"
          ;;
        *)
          CLIENTONLY=
          LOCALCLIENT=
          ;;
      esac
    fi
  fi
  if [ -n "${CONFTYPE}" ]; then
    export CONFTYPE="${CONFTYPE}"
  fi
  if [ -n "${CLIENTONLY}" ]; then
    export CLIENTONLY="${CLIENTONLY}"
  fi
  if [ -n "${LOCALCLIENT}" ]; then
    export LOCALCLIENT="${LOCALCLIENT}"
  fi

  local cfg_variant="${VARIANT:-server}"
  if [ "$cfg_variant" = "client" ] || [ "$cfg_variant" = "localclient" ]; then
    echo "configure: MAKE=${MAKE_BIN} ./configure.client"
    printf '\n%.0s' {1..40} | MAKE="${MAKE_BIN}" ./configure.client
  else
    echo "configure: MAKE=${MAKE_BIN} ./configure.server"
    printf '\n%.0s' {1..40} | MAKE="${MAKE_BIN}" ./configure.server
  fi
}

build_project() {
  local caresinc=""
  local careslib=""
  if [ -n "$CARES_PREFIX" ]; then
    caresinc="-I${CARES_PREFIX}/include"
    careslib="-L${CARES_PREFIX}/lib -lcares"
  fi
  local base_cflags=""
  if [ "${VARIANT:-server}" = "client" ] || [ "${VARIANT:-server}" = "localclient" ]; then
    base_cflags="$(
      set +o pipefail
      "${MAKE_BIN}" -s -p -n 2>/dev/null | awk -F ' = ' '/^CFLAGS = /{print $2; exit}' || true
    )"
    if [ -z "${base_cflags}" ]; then
      base_cflags="$(awk -F '=' '/^CFLAGS[[:space:]]*=/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}' Makefile 2>/dev/null || true)"
    fi
    if [ "${CONFTYPE:-}" = "server" ]; then
      "${MAKE_BIN}" -j2 CARESINCDIR="${caresinc}" CARESLIBS="${careslib}" \
        CFLAGS="${base_cflags} -DLOCALCLIENT=0" \
        LOCALCLIENT=no \
        PCRELIBS= \
        client
    else
      "${MAKE_BIN}" -j2 CARESINCDIR="${caresinc}" CARESLIBS="${careslib}" \
        CFLAGS="${base_cflags} -DCLIENTONLY=1" \
        LOCALCLIENT=yes \
        client
    fi
  else
    "${MAKE_BIN}" -j2 CARESINCDIR="${caresinc}" CARESLIBS="${careslib}"
  fi
}

install_staged() {
  if [ "${VARIANT:-server}" = "client" ] || [ "${VARIANT:-server}" = "localclient" ]; then
    as_root "${MAKE_BIN}" install-client install-clientmsg \
      CLIENTTARGETS="lib-client common-client" \
      DESTDIR="${LEGACY_STAGING}" \
      INSTALLROOT="${LEGACY_STAGING}"
  else
    as_root "${MAKE_BIN}" install \
      DESTDIR="${LEGACY_STAGING}" \
      INSTALLROOT="${LEGACY_STAGING}"

    as_root "${MAKE_BIN}" install-man \
      DESTDIR="${LEGACY_STAGING}" \
      INSTALLROOT="${LEGACY_STAGING}" \
      MANROOT="${DEFAULT_TOP}/server/man" \
      XYMONUSER="${XYMONUSER:-xymon}" \
      IDTOOL="${IDTOOL:-id}" \
      PKGBUILD="${PKGBUILD:-}"
  fi
}

detect_topdir() {
  local topdir
  topdir=$(awk -F ' = ' '/^XYMONTOPDIR =/ {print $2; exit}' Makefile 2>/dev/null || true)
  if [ -z "$topdir" ]; then
    topdir="${DEFAULT_TOP}"
  fi

  local root="${LEGACY_DESTROOT}"
  if [ ! -d "$root" ]; then
    root="${LEGACY_DESTROOT_FALLBACK}"
  fi
  if [ ! -d "$root" ]; then
    root="${LEGACY_STAGING}${topdir}"
  fi

  if [ ! -d "$root" ]; then
    echo "Missing ${root}" >&2
    exit 1
  fi

  echo "${topdir}:${root}"
}

echo "=== Setup ($OS_NAME) ==="
setup_os
echo "=== Configure ==="
configure_build
echo "=== Build ==="
build_project
echo "=== Install staged tree ==="
install_staged
echo "=== Record staged tree metadata ==="
detect="$(detect_topdir)"
topdir="${detect%%:*}"
root="${detect#*:}"
cat <<EOF >/tmp/xymon-root-vars.sh
export LEGACY_TOPDIR="${topdir}"
export LEGACY_ROOT="${root}"
EOF
