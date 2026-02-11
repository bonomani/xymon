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

LEGACY_CONFTYPE=""
LEGACY_CLIENTONLY=""
LEGACY_LOCALCLIENT=""
CMAKE_VARIANT="server"
CMAKE_LOCALCLIENT="OFF"

RUN_CONFIGURE_FN=""
RUN_BUILD_FN=""
RUN_INSTALL_FN=""
DETECT_TOPDIR_ROOT_FN=""
DETECT_CONFIG_H_FN=""

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

if [ -z "${OS_NAME}" ]; then
  echo "Missing --os" >&2
  exit 1
fi
if [ "${OS_NAME}" = "ubuntu" ]; then
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

as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

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

normalize_variant() {
  VARIANT="${VARIANT:-server}"
  case "${VARIANT}" in
    server|client|localclient)
      ;;
    *)
      echo "Unsupported --variant value: ${VARIANT}" >&2
      exit 1
      ;;
  esac

  LEGACY_CONFTYPE="${CONFTYPE:-}"
  LEGACY_CLIENTONLY="${CLIENTONLY:-}"
  LEGACY_LOCALCLIENT="${LOCALCLIENT:-}"

  if [ -z "${LEGACY_CONFTYPE}" ]; then
    if [ -n "${LEGACY_CLIENTONLY}" ] || [ -n "${LEGACY_LOCALCLIENT}" ]; then
      case "${LEGACY_LOCALCLIENT}" in
        yes|YES|on|ON|1|true|TRUE)
          LEGACY_CONFTYPE="client"
          ;;
        *)
          if [ -n "${LEGACY_CLIENTONLY}" ]; then
            LEGACY_CONFTYPE="server"
          fi
          ;;
      esac
    else
      case "${VARIANT}" in
        client)
          LEGACY_CLIENTONLY=yes
          LEGACY_LOCALCLIENT=no
          LEGACY_CONFTYPE="server"
          ;;
        localclient)
          LEGACY_CLIENTONLY=yes
          LEGACY_LOCALCLIENT=yes
          LEGACY_CONFTYPE="client"
          ;;
        *)
          LEGACY_CLIENTONLY=""
          LEGACY_LOCALCLIENT=""
          ;;
      esac
    fi
  fi

  CMAKE_VARIANT="${VARIANT}"
  CMAKE_LOCALCLIENT="OFF"
  case "${VARIANT}" in
    localclient)
      CMAKE_VARIANT="client"
      CMAKE_LOCALCLIENT="ON"
      ;;
    client|server)
      CMAKE_LOCALCLIENT="OFF"
      ;;
  esac
}

set_feature_flags() {
  if [ "${VARIANT}" = "server" ]; then
    ENABLE_LDAP=ON
    ENABLE_SNMP=ON
  else
    ENABLE_LDAP=OFF
    ENABLE_SNMP=OFF
  fi
  export VARIANT ENABLE_LDAP ENABLE_SNMP
}

select_build_adapter() {
  case "${BUILD_TOOL}" in
    make)
      RUN_CONFIGURE_FN="configure_build_make"
      RUN_BUILD_FN="build_project_make"
      RUN_INSTALL_FN="install_staged_make"
      DETECT_TOPDIR_ROOT_FN="detect_topdir_root_make"
      DETECT_CONFIG_H_FN="detect_config_h_make"
      ;;
    cmake)
      RUN_CONFIGURE_FN="configure_build_cmake"
      RUN_BUILD_FN="build_project_cmake"
      RUN_INSTALL_FN="install_staged_cmake"
      DETECT_TOPDIR_ROOT_FN="detect_topdir_root_cmake"
      DETECT_CONFIG_H_FN="detect_config_h_cmake"
      ;;
  esac
}

ensure_group() {
  local group_name="$1"
  if getent group "${group_name}" >/dev/null 2>&1 || grep -q "^${group_name}:" /etc/group 2>/dev/null; then
    return
  fi

  if [ "${OS_NAME}" = "freebsd" ]; then
    as_root pw groupadd "${group_name}" 2>/dev/null || true
  elif command -v groupadd >/dev/null 2>&1; then
    as_root groupadd "${group_name}" 2>/dev/null || true
  elif command -v addgroup >/dev/null 2>&1; then
    # Alpine/busybox path
    as_root addgroup -S "${group_name}" 2>/dev/null || as_root addgroup "${group_name}" 2>/dev/null || true
  else
    true
  fi
}

ensure_user() {
  if id -u xymon >/dev/null 2>&1; then
    return
  fi

  if [ "${OS_NAME}" = "freebsd" ]; then
    as_root pw useradd -n xymon -m -g xymon -s /bin/sh 2>/dev/null || true
  elif command -v useradd >/dev/null 2>&1; then
    as_root useradd -m -g xymon -s /bin/sh xymon 2>/dev/null || true
  elif command -v adduser >/dev/null 2>&1; then
    # Alpine/busybox path
    as_root adduser -S -D -s /bin/sh -G xymon xymon 2>/dev/null \
      || as_root adduser -D -s /bin/sh -G xymon xymon 2>/dev/null \
      || as_root adduser -D -s /bin/sh xymon 2>/dev/null \
      || true
  else
    true
  fi
}

ensure_user_group() {
  ensure_group "$1"
  ensure_group "xymon"
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
  install_default_packages
  if [ "${BUILD_TOOL}" = "make" ]; then
    ensure_gmake
    detect_cares_prefix "$@"
  fi
  ensure_user_group "${HTTPDGID}"
}

setup_os() {
  case "${OS_NAME}" in
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
      if [ "${BUILD_TOOL}" = "make" ] && [ -x /usr/pkg/bin/gmake ]; then
        export PATH="/usr/pkg/bin:${PATH}"
      fi
      ;;
    *)
      echo "Unsupported OS: ${OS_NAME}" >&2
      exit 1
      ;;
  esac
}

onoff_to_yesno() {
  case "${1:-}" in
    ON|on|On|1|yes|YES|true|TRUE)
      echo "y"
      ;;
    OFF|off|Off|0|no|NO|false|FALSE)
      echo "n"
      ;;
    *)
      echo "${2:-n}"
      ;;
  esac
}

onoff_to_cmake() {
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

configure_build_make() {
  export ENABLESSL=y
  export ENABLELDAP
  ENABLELDAP="$(onoff_to_yesno "${ENABLE_LDAP:-ON}" "y")"
  export XYMONUSER=xymon
  export HTTPDGID="${HTTPDGID:-www}"
  export XYMONTOPDIR="${DEFAULT_TOP}"
  export CC=cc
  if [ -n "${LEGACY_CONFTYPE}" ]; then
    export CONFTYPE="${LEGACY_CONFTYPE}"
  fi
  if [ -n "${LEGACY_CLIENTONLY}" ]; then
    export CLIENTONLY="${LEGACY_CLIENTONLY}"
  fi
  if [ -n "${LEGACY_LOCALCLIENT}" ]; then
    export LOCALCLIENT="${LEGACY_LOCALCLIENT}"
  fi

  if [ "${VARIANT}" = "client" ] || [ "${VARIANT}" = "localclient" ]; then
    echo "configure: MAKE=${MAKE_BIN} ./configure.client"
    printf '\n%.0s' {1..40} | MAKE="${MAKE_BIN}" ./configure.client 2>&1 | tee /tmp/make.configure.log
  else
    echo "configure: MAKE=${MAKE_BIN} ./configure.server"
    printf '\n%.0s' {1..40} | MAKE="${MAKE_BIN}" ./configure.server 2>&1 | tee /tmp/make.configure.log
  fi
}

configure_build_cmake() {
  local cmake_enable_ldap
  local cmake_apply_ownership
  local extra_args=()

  cmake_enable_ldap="$(onoff_to_cmake "${ENABLE_LDAP:-ON}" "ON")"
  cmake_apply_ownership="$(onoff_to_cmake "${LEGACY_APPLY_OWNERSHIP:-OFF}" "OFF")"
  if [ -n "${XYMONHOSTNAME:-}" ]; then
    extra_args+=("-DXYMONHOSTNAME=${XYMONHOSTNAME}")
  fi

  echo "configure: ${CMAKE_BIN} -S . -B ${CMAKE_BUILD_DIR}"
  "${CMAKE_BIN}" -S . -B "${CMAKE_BUILD_DIR}" \
    -G Ninja \
    -DUSE_GNUINSTALLDIRS=OFF \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DLEGACY_APPLY_OWNERSHIP="${cmake_apply_ownership}" \
    -DHTTPDGID="${HTTPDGID}" \
    -DLEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR}" \
    -DXYMON_VARIANT="${CMAKE_VARIANT}" \
    -DLOCALCLIENT="${CMAKE_LOCALCLIENT}" \
    -DENABLE_LDAP="${cmake_enable_ldap}" \
    -DENABLE_SSL=ON \
    "${extra_args[@]}" 2>&1 | tee /tmp/cmake.configure.log
}

build_project_make() {
  local caresinc=""
  local careslib=""
  if [ -n "${CARES_PREFIX}" ]; then
    caresinc="-I${CARES_PREFIX}/include"
    careslib="-L${CARES_PREFIX}/lib -lcares"
  fi
  local base_cflags=""
  if [ "${VARIANT}" = "client" ] || [ "${VARIANT}" = "localclient" ]; then
    base_cflags="$(
      set +o pipefail
      "${MAKE_BIN}" -s -p -n 2>/dev/null | awk -F ' = ' '/^CFLAGS = /{print $2; exit}' || true
    )"
    if [ -z "${base_cflags}" ]; then
      base_cflags="$(awk -F '=' '/^CFLAGS[[:space:]]*=/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}' Makefile 2>/dev/null || true)"
    fi
    if [ "${LEGACY_CONFTYPE}" = "server" ]; then
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

install_staged_make() {
  if [ "${VARIANT}" = "client" ] || [ "${VARIANT}" = "localclient" ]; then
    as_root "${MAKE_BIN}" install-client install-clientmsg \
      CLIENTTARGETS="lib-client common-client" \
      DESTDIR="${LEGACY_STAGING}" \
      INSTALLROOT="${LEGACY_STAGING}" 2>&1 | tee /tmp/install-make-legacy.log
  else
    {
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
    } 2>&1 | tee /tmp/install-make-legacy.log
  fi
}

install_staged_cmake() {
  local cmake_apply_ownership
  cmake_apply_ownership="$(onoff_to_cmake "${LEGACY_APPLY_OWNERSHIP:-OFF}" "OFF")"

  if [ "${cmake_apply_ownership}" = "ON" ]; then
    as_root env LEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR}" \
      "${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" --target install-legacy-dirs install-legacy-files 2>&1 | tee /tmp/install-cmake-legacy.log
  else
    LEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR}" \
      "${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" --target install-legacy-dirs install-legacy-files 2>&1 | tee /tmp/install-cmake-legacy.log
  fi
}

detect_topdir_root_make() {
  local topdir
  topdir=$(awk -F ' = ' '/^XYMONTOPDIR =/ {print $2; exit}' Makefile 2>/dev/null || true)
  if [ -z "${topdir}" ]; then
    topdir="${DEFAULT_TOP}"
  fi

  local root="${LEGACY_DESTROOT}"
  if [ ! -d "${root}" ]; then
    root="${LEGACY_DESTROOT_FALLBACK}"
  fi
  if [ ! -d "${root}" ]; then
    root="${LEGACY_STAGING}${topdir}"
  fi

  if [ ! -d "${root}" ]; then
    echo "Missing ${root}" >&2
    exit 1
  fi

  echo "${topdir}:${root}"
}

detect_topdir_root_cmake() {
  local topdir="${DEFAULT_TOP}"
  local root="${CMAKE_LEGACY_DESTROOT}"
  if [ ! -d "${root}" ]; then
    root="${CMAKE_LEGACY_DESTDIR}${topdir}"
  fi
  if [ ! -d "${root}" ]; then
    echo "Missing ${root}" >&2
    exit 1
  fi
  echo "${topdir}:${root}"
}

detect_config_h_make() {
  if [ -f include/config.h ]; then
    printf '%s\n' "$(pwd)/include/config.h"
  fi
}

detect_config_h_cmake() {
  local config_h_path
  config_h_path="$(find "${CMAKE_BUILD_DIR}" -path '*/include/config.h' | head -n1 || true)"
  if [ -z "${config_h_path}" ]; then
    config_h_path="$(find "${CMAKE_BUILD_DIR}" -name config.h | head -n1 || true)"
  fi
  if [ -n "${config_h_path}" ] && [ "${config_h_path#/}" = "${config_h_path}" ]; then
    config_h_path="$(pwd)/${config_h_path}"
  fi
  printf '%s\n' "${config_h_path:-}"
}

write_staged_metadata() {
  local detect topdir root config_h_path
  detect="$(${DETECT_TOPDIR_ROOT_FN})"
  topdir="${detect%%:*}"
  root="${detect#*:}"
  config_h_path="$(${DETECT_CONFIG_H_FN})"

  cat <<EOF >/tmp/xymon-root-vars.sh
export LEGACY_TOPDIR="${topdir}"
export LEGACY_ROOT="${root}"
export XYMON_CONFIG_H="${config_h_path}"
EOF
}

normalize_build_tool
normalize_variant
set_feature_flags
select_build_adapter

echo "=== Setup (${OS_NAME}) ==="
setup_os
echo "=== Configure ==="
"${RUN_CONFIGURE_FN}"
echo "=== Build ==="
"${RUN_BUILD_FN}"
echo "=== Install staged tree ==="
"${RUN_INSTALL_FN}"
echo "=== Record staged tree metadata ==="
write_staged_metadata
