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
CMAKE_BIN="${CMAKE_BIN:-cmake}"
CMAKE_BUILD_DIR="${CMAKE_BUILD_DIR:-build-cmake}"
CMAKE_LEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR:-/tmp/cmake-ref-root}"
CMAKE_LEGACY_DESTROOT="${CMAKE_LEGACY_DESTDIR}${DEFAULT_TOP}"

normalize_build_tool() {
  BUILD_TOOL="$(printf '%s' "${BUILD_TOOL:-make}" | tr '[:upper:]' '[:lower:]')"
  case "${BUILD_TOOL}" in
    make|gmake)
      BUILD_TOOL="make"
      ;;
    cmake)
      ;;
    *)
      echo "Unsupported --build value: ${BUILD_TOOL}" >&2
      exit 1
      ;;
  esac
}

as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

set_variant_flags() {
  VARIANT="${VARIANT:-server}"
  if [ "${VARIANT}" = "server" ] || [ "${VARIANT}" = "all" ]; then
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
  if [ "${BUILD_TOOL}" = "make" ]; then
    MAKE_BIN="gmake"
  fi
  set_variant_flags
  install_default_packages
  if [ "${BUILD_TOOL}" = "make" ]; then
    ensure_gmake
    detect_cares_prefix "$@"
  fi
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

configure_build_make() {
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

cmake_onoff() {
  case "${1:-}" in
    ON|on|On|1|yes|YES|true|TRUE)
      echo "ON"
      ;;
    OFF|off|Off|0|no|NO|false|FALSE)
      echo "OFF"
      ;;
    *)
      echo "${2:-OFF}"
      ;;
  esac
}

configure_build_cmake() {
  local cmake_variant="${VARIANT:-server}"
  local cmake_localclient="OFF"
  local cmake_enable_ldap
  local extra_args=()

  case "${cmake_variant}" in
    localclient)
      cmake_variant="client"
      cmake_localclient="ON"
      ;;
    client|server|all)
      cmake_localclient="OFF"
      ;;
    *)
      echo "Unsupported variant for CMake build: ${cmake_variant}" >&2
      exit 1
      ;;
  esac

  cmake_enable_ldap="$(cmake_onoff "${ENABLE_LDAP:-ON}" "ON")"
  if [ -n "${XYMONHOSTNAME:-}" ]; then
    extra_args+=("-DXYMONHOSTNAME=${XYMONHOSTNAME}")
  fi

  echo "configure: ${CMAKE_BIN} -S . -B ${CMAKE_BUILD_DIR}"
  "${CMAKE_BIN}" -S . -B "${CMAKE_BUILD_DIR}" \
    -G Ninja \
    -DUSE_GNUINSTALLDIRS=OFF \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DLEGACY_APPLY_OWNERSHIP=OFF \
    -DLEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR}" \
    -DXYMON_VARIANT="${cmake_variant}" \
    -DLOCALCLIENT="${cmake_localclient}" \
    -DENABLE_LDAP="${cmake_enable_ldap}" \
    -DENABLE_SSL=ON \
    "${extra_args[@]}" 2>&1 | tee /tmp/cmake.configure.log
}

configure_build() {
  if [ "${BUILD_TOOL}" = "cmake" ]; then
    configure_build_cmake
  else
    configure_build_make
  fi
}

build_project_make() {
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

build_project_cmake() {
  "${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" -j2
}

build_project() {
  if [ "${BUILD_TOOL}" = "cmake" ]; then
    build_project_cmake
  else
    build_project_make
  fi
}

install_staged_make() {
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

install_staged_cmake() {
  "${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" --target web_cgi_links docs
  LEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR}" \
    "${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" --target install-legacy-dirs install-legacy-files 2>&1 | tee /tmp/install-cmake-legacy.log
}

install_staged() {
  if [ "${BUILD_TOOL}" = "cmake" ]; then
    install_staged_cmake
  else
    install_staged_make
  fi
}

detect_topdir() {
  if [ "${BUILD_TOOL}" = "cmake" ]; then
    local topdir="${DEFAULT_TOP}"
    local root="${CMAKE_LEGACY_DESTROOT}"
    if [ ! -d "$root" ]; then
      root="${CMAKE_LEGACY_DESTDIR}${topdir}"
    fi
    if [ ! -d "$root" ]; then
      echo "Missing ${root}" >&2
      exit 1
    fi
    echo "${topdir}:${root}"
    return
  fi

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

normalize_build_tool
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
config_h_path=""
if [ "${BUILD_TOOL}" = "cmake" ]; then
  config_h_path="$(find "${CMAKE_BUILD_DIR}" -path '*/include/config.h' | head -n1 || true)"
  if [ -z "${config_h_path}" ]; then
    config_h_path="$(find "${CMAKE_BUILD_DIR}" -name config.h | head -n1 || true)"
  fi
  if [ -n "${config_h_path}" ] && [ "${config_h_path#/}" = "${config_h_path}" ]; then
    config_h_path="$(pwd)/${config_h_path}"
  fi
elif [ -f include/config.h ]; then
  config_h_path="$(pwd)/include/config.h"
fi

cat <<EOF >/tmp/xymon-root-vars.sh
export LEGACY_TOPDIR="${topdir}"
export LEGACY_ROOT="${root}"
export XYMON_CONFIG_H="${config_h_path}"
EOF
