#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKE_PROFILE_EXPORTER="${SCRIPT_DIR}/run/export-make-profile-env.sh"

OS_NAME=""
PLATFORM_OS=""
OS_VERSION=""
REF_NAME=""
KEYFILES_NAME=""
VARIANT=""
CONFTYPE=""
CLIENTONLY=""
LOCALCLIENT=""
HTTPDGID=""
BUILD_TOOL="make"
CI_COMPILER="${CI_COMPILER:-gcc}"
BUILD_PROFILE="${PROFILE:-default}"
BUILD_INSTALL_MODE="${INSTALL_MODE:-auto}"
CMAKE_PRESET=""
VERIFY_DEPTH="${VERIFY_DEPTH:-install}"
XYMONUSER="${XYMONUSER:-xymon}"
XYMONGROUP="${XYMONGROUP:-${XYMONUSER}}"

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
    --platform-os)
      PLATFORM_OS="${2:-}"
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
    --compiler)
      CI_COMPILER="${2:-}"
      shift 2
      ;;
    --profile)
      BUILD_PROFILE="${2:-}"
      shift 2
      ;;
    --install-mode)
      BUILD_INSTALL_MODE="${2:-}"
      shift 2
      ;;
    --verify-depth)
      VERIFY_DEPTH="${2:-}"
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
if [ -z "${PLATFORM_OS}" ]; then
  PLATFORM_OS="${OS_NAME}"
fi

LEGACY_STAGING="/tmp/xymon-stage"
LEGACY_DESTROOT="/tmp/xymon-stage/var/lib/xymon"
LEGACY_DESTROOT_FALLBACK="/tmp/var/lib/xymon"
DEFAULT_TOP="/var/lib/xymon"
MAKE_BIN="make"
CARES_PREFIX=""
CMAKE_BIN="${CMAKE_BIN:-cmake}"
if [ -n "${CMAKE_BUILD_DIR:-}" ]; then
  CMAKE_BUILD_DIR_USER_SET=1
else
  CMAKE_BUILD_DIR_USER_SET=0
fi
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

normalize_compiler() {
  CI_COMPILER="$(printf '%s' "${CI_COMPILER:-gcc}" | tr '[:upper:]' '[:lower:]')"
  case "${CI_COMPILER}" in
    gcc|clang)
      ;;
    *)
      echo "Unsupported --compiler value: ${CI_COMPILER}" >&2
      exit 1
      ;;
  esac
}

normalize_profile() {
  BUILD_PROFILE="$(printf '%s' "${BUILD_PROFILE:-}" | tr '[:upper:]' '[:lower:]')"
  if [ -z "${BUILD_PROFILE}" ]; then
    BUILD_PROFILE="default"
  fi

  case "${BUILD_TOOL}" in
    make)
      case "${BUILD_PROFILE}" in
        default|debian|packaging)
          ;;
        gnuinstall)
          echo "Unsupported --profile value for make: ${BUILD_PROFILE}" >&2
          exit 1
          ;;
        *)
          echo "Unsupported --profile value: ${BUILD_PROFILE}" >&2
          exit 1
          ;;
      esac
      CMAKE_PRESET=""
      ;;
    cmake)
      case "${BUILD_PROFILE}" in
        default|gnuinstall|packaging)
          ;;
        *)
          echo "Unsupported --profile value for cmake: ${BUILD_PROFILE}" >&2
          exit 1
          ;;
      esac
      CMAKE_PRESET="${BUILD_PROFILE}"
      ;;
  esac
}

default_install_mode() {
  case "${BUILD_TOOL}" in
    make)
      case "${BUILD_PROFILE}" in
        debian|packaging)
          echo "package"
          ;;
        *)
          echo "source"
          ;;
      esac
      ;;
    *)
      echo "source"
      ;;
  esac
}

normalize_install_mode() {
  BUILD_INSTALL_MODE="$(printf '%s' "${BUILD_INSTALL_MODE:-}" | tr '[:upper:]' '[:lower:]')"
  case "${BUILD_INSTALL_MODE}" in
    ""|auto)
      BUILD_INSTALL_MODE="$(default_install_mode)"
      ;;
    source|package)
      ;;
    *)
      echo "Unsupported --install-mode value: ${BUILD_INSTALL_MODE}" >&2
      exit 1
      ;;
  esac

  if [ "${BUILD_TOOL}" = "make" ] && { [ "${BUILD_PROFILE}" = "debian" ] || [ "${BUILD_PROFILE}" = "packaging" ]; } && [ "${BUILD_INSTALL_MODE}" != "package" ]; then
    echo "make profile=${BUILD_PROFILE} currently requires --install-mode package" >&2
    exit 1
  fi
}

normalize_verify_depth() {
  VERIFY_DEPTH="$(printf '%s' "${VERIFY_DEPTH:-install}" | tr '[:upper:]' '[:lower:]')"
  case "${VERIFY_DEPTH}" in
    configure|build|install)
      ;;
    *)
      echo "Unsupported --verify-depth value: ${VERIFY_DEPTH}" >&2
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
  local group_name="${1:-${XYMONGROUP}}"
  if getent group "${group_name}" >/dev/null 2>&1 || grep -q "^${group_name}:" /etc/group 2>/dev/null; then
    return
  fi

  if [ "${OS_NAME}" = "freebsd" ]; then
    as_root pw groupadd "${group_name}" 2>/dev/null || true
  elif [ "${OS_NAME}" = "netbsd" ] && [ -x /usr/sbin/groupadd ]; then
    as_root /usr/sbin/groupadd "${group_name}" 2>/dev/null || true
  elif command -v groupadd >/dev/null 2>&1; then
    as_root groupadd "${group_name}" 2>/dev/null || true
  elif [ -x /usr/sbin/groupadd ]; then
    as_root /usr/sbin/groupadd "${group_name}" 2>/dev/null || true
  elif command -v addgroup >/dev/null 2>&1; then
    as_root addgroup -S "${group_name}" 2>/dev/null || as_root addgroup "${group_name}" 2>/dev/null || true
  else
    true
  fi
}

ensure_user() {
  if id -u "${XYMONUSER}" >/dev/null 2>&1; then
    return
  fi

  if [ "${OS_NAME}" = "freebsd" ]; then
    as_root pw useradd -n "${XYMONUSER}" -m -g "${XYMONGROUP}" -s /bin/sh 2>/dev/null || true
  elif [ "${OS_NAME}" = "netbsd" ] && [ -x /usr/sbin/useradd ]; then
    as_root /usr/sbin/useradd -m -g "${XYMONGROUP}" -s /bin/sh "${XYMONUSER}" 2>/dev/null || true
  elif command -v useradd >/dev/null 2>&1; then
    as_root useradd -m -g "${XYMONGROUP}" -s /bin/sh "${XYMONUSER}" 2>/dev/null || true
  elif [ -x /usr/sbin/useradd ]; then
    as_root /usr/sbin/useradd -m -g "${XYMONGROUP}" -s /bin/sh "${XYMONUSER}" 2>/dev/null || true
  elif command -v adduser >/dev/null 2>&1; then
    as_root adduser -S -D -s /bin/sh -G "${XYMONGROUP}" "${XYMONUSER}" 2>/dev/null \
      || as_root adduser -D -s /bin/sh -G "${XYMONGROUP}" "${XYMONUSER}" 2>/dev/null \
      || as_root adduser -D -s /bin/sh "${XYMONUSER}" 2>/dev/null \
      || true
  elif [ -x /usr/sbin/adduser ]; then
    as_root /usr/sbin/adduser -D -s /bin/sh -G "${XYMONGROUP}" "${XYMONUSER}" 2>/dev/null \
      || as_root /usr/sbin/adduser -D -s /bin/sh "${XYMONUSER}" 2>/dev/null \
      || true
  else
    true
  fi
}

ensure_user_group() {
  ensure_group "$1"
  ensure_group "${XYMONGROUP}"
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
  CI_DEPS_BUILD_TOOL="${BUILD_TOOL}" CI_COMPILER="${CI_COMPILER}" \
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
    macos)
      prepare_os "_www" "/opt/homebrew" "/usr/local" "/usr"
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
  export XYMONUSER="${XYMONUSER:-xymon}"
  export HTTPDGID="${HTTPDGID:-www}"
if [ ! -f "${MAKE_PROFILE_EXPORTER}" ]; then
  echo "Missing make profile exporter: ${MAKE_PROFILE_EXPORTER}" >&2
  exit 1
fi
  legacy_layout_profile="${BUILD_PROFILE}"
  if [ "${legacy_layout_profile}" = "packaging" ]; then
    legacy_layout_profile="debian"
  fi
  eval "$(bash "${MAKE_PROFILE_EXPORTER}" --profile "${legacy_layout_profile}")"
  echo "Bootstrap make profile '${BUILD_PROFILE}' environment before configure:"
  for var in XYMONTOPDIR XYMONVAR XYMONHOSTURL CGIDIR XYMONCGIURL SECURECGIDIR SECUREXYMONCGIURL XYMONLOGDIR XYMONHOSTNAME XYMONHOSTIP MANROOT INSTALLBINDIR INSTALLETCDIR INSTALLWEBDIR INSTALLEXTDIR INSTALLTMPDIR INSTALLWWWDIR XYMONUSER HTTPDGID USEXYMONPING ENABLESSL ENABLELDAP ENABLELDAPSSL; do
    printf '  %s=%s\n' "$var" "${!var:-<unset>}"
  done
  export CC="${CC:-${CI_COMPILER}}"
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
  local cmake_use_gnuinstalldirs
  local cmake_install_prefix
  local cmake_httpdgid_chgrp
  local -a cmake_args

  cmake_enable_ldap="$(onoff_to_cmake "${ENABLE_LDAP:-ON}" "ON")"
  if [ -n "${LEGACY_APPLY_OWNERSHIP:-}" ]; then
    cmake_apply_ownership="$(onoff_to_cmake "${LEGACY_APPLY_OWNERSHIP}" "OFF")"
  elif [ "${BUILD_INSTALL_MODE}" = "package" ]; then
    cmake_apply_ownership="OFF"
  else
    cmake_apply_ownership="ON"
  fi
  case "${CMAKE_PRESET}" in
    default)
      cmake_use_gnuinstalldirs="OFF"
      cmake_install_prefix="/"
      cmake_httpdgid_chgrp="ON"
      if [ "${CMAKE_BUILD_DIR_USER_SET}" != "1" ]; then
        CMAKE_BUILD_DIR="build-cmake"
      fi
      ;;
    gnuinstall)
      cmake_use_gnuinstalldirs="ON"
      cmake_install_prefix="/"
      cmake_httpdgid_chgrp="ON"
      if [ "${CMAKE_BUILD_DIR_USER_SET}" != "1" ]; then
        CMAKE_BUILD_DIR="build-cmake-gnu"
      fi
      ;;
    packaging)
      cmake_use_gnuinstalldirs="ON"
      cmake_install_prefix="/usr"
      cmake_httpdgid_chgrp="OFF"
      if [ "${CMAKE_BUILD_DIR_USER_SET}" != "1" ]; then
        CMAKE_BUILD_DIR="build-cmake-packaging"
      fi
      ;;
  esac
  case "${CI_COMPILER}" in
    gcc)
      export CC="${CC:-gcc}"
      export CXX="${CXX:-g++}"
      ;;
    clang)
      export CC="${CC:-clang}"
      export CXX="${CXX:-clang++}"
      ;;
  esac
  cmake_args=(
    -G Ninja
    -DUSE_GNUINSTALLDIRS="${cmake_use_gnuinstalldirs}"
    -DCMAKE_INSTALL_PREFIX="${cmake_install_prefix}"
    -DHTTPDGID_CHGRP="${cmake_httpdgid_chgrp}"
    -DLEGACY_APPLY_OWNERSHIP="${cmake_apply_ownership}"
    -DXYMONUSER="${XYMONUSER}"
    -DHTTPDGID="${HTTPDGID}"
    -DLEGACY_DESTDIR="${CMAKE_LEGACY_DESTDIR}"
    -DXYMON_VARIANT="${CMAKE_VARIANT}"
    -DLOCALCLIENT="${CMAKE_LOCALCLIENT}"
    -DENABLE_LDAP="${cmake_enable_ldap}"
    -DENABLE_SSL=ON
  )
  if [ -n "${XYMONHOSTNAME:-}" ]; then
    cmake_args+=("-DXYMONHOSTNAME=${XYMONHOSTNAME}")
  fi

  echo "configure: ${CMAKE_BIN} -S . -B ${CMAKE_BUILD_DIR}"
  "${CMAKE_BIN}" -S . -B "${CMAKE_BUILD_DIR}" \
    "${cmake_args[@]}" 2>&1 | tee /tmp/cmake.configure.log
}

build_project_make() {
  local caresinc=""
  local careslib=""
  # Legacy makefiles have ordering races in multiple lanes; keep make builds
  # single-threaded in CI for deterministic behavior.
  local make_jobs=1
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
      "${MAKE_BIN}" -j"${make_jobs}" CARESINCDIR="${caresinc}" CARESLIBS="${careslib}" \
        CLIENTTARGETS="lib-client common-client" \
        CFLAGS="${base_cflags} -ULOCALCLIENT" \
        LOCALCLIENT=no \
        PCRELIBS= \
        client
    else
      "${MAKE_BIN}" -j"${make_jobs}" CARESINCDIR="${caresinc}" CARESLIBS="${careslib}" \
        CLIENTTARGETS="lib-client common-client build-build" \
        CFLAGS="${base_cflags} -DCLIENTONLY=1" \
        LOCALCLIENT=yes \
        client
    fi
  else
    "${MAKE_BIN}" -j"${make_jobs}" CARESINCDIR="${caresinc}" CARESLIBS="${careslib}"
  fi
}

build_project_cmake() {
  "${CMAKE_BIN}" --build "${CMAKE_BUILD_DIR}" -j2
}

install_staged_make() {
  local make_pkgbuild="${PKGBUILD:-}"
  if [ -z "${make_pkgbuild}" ] && [ "${BUILD_INSTALL_MODE}" = "package" ]; then
    make_pkgbuild="1"
  fi

  if [ "${VARIANT}" = "client" ] || [ "${VARIANT}" = "localclient" ]; then
    local install_clienttargets="lib-client common-client"
    as_root "${MAKE_BIN}" -j2 -C build merge-lines merge-sects
    if [ "${VARIANT}" = "localclient" ]; then
      install_clienttargets="lib-client common-client build-build"
    fi
    as_root "${MAKE_BIN}" install-client install-clientmsg \
      CLIENTTARGETS="${install_clienttargets}" \
      PKGBUILD="${make_pkgbuild}" \
      DESTDIR="${LEGACY_STAGING}" \
      INSTALLROOT="${LEGACY_STAGING}" 2>&1 | tee /tmp/install-make-legacy.log
  else
    {
      as_root "${MAKE_BIN}" install \
        PKGBUILD="${make_pkgbuild}" \
        DESTDIR="${LEGACY_STAGING}" \
        INSTALLROOT="${LEGACY_STAGING}"

      as_root "${MAKE_BIN}" install-man \
        DESTDIR="${LEGACY_STAGING}" \
        INSTALLROOT="${LEGACY_STAGING}" \
        MANROOT="${MANROOT:-${DEFAULT_TOP}/server/man}" \
        XYMONUSER="${XYMONUSER:-xymon}" \
        IDTOOL="${IDTOOL:-id}" \
        PKGBUILD="${make_pkgbuild}"
    } 2>&1 | tee /tmp/install-make-legacy.log
  fi
}

install_staged_cmake() {
  local cmake_apply_ownership
  if [ -n "${LEGACY_APPLY_OWNERSHIP:-}" ]; then
    cmake_apply_ownership="$(onoff_to_cmake "${LEGACY_APPLY_OWNERSHIP}" "OFF")"
  elif [ "${BUILD_INSTALL_MODE}" = "package" ]; then
    cmake_apply_ownership="OFF"
  else
    cmake_apply_ownership="ON"
  fi

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
  local expected_root
  local root
  topdir=$(awk -F ' = ' '/^XYMONTOPDIR =/ {print $2; exit}' Makefile 2>/dev/null || true)
  if [ -z "${topdir}" ]; then
    topdir="${DEFAULT_TOP}"
  fi

  expected_root="${LEGACY_STAGING}${topdir}"
  root="${expected_root}"
  if [ ! -d "${root}" ] && [ "${topdir}" = "${DEFAULT_TOP}" ] && [ -d "${LEGACY_DESTROOT_FALLBACK}" ]; then
    root="${LEGACY_DESTROOT_FALLBACK}"
  fi

  if [ ! -d "${root}" ]; then
    echo "Missing ${expected_root}" >&2
    exit 1
  fi

  echo "${topdir}:${root}"
}

detect_topdir_root_cmake() {
  local topdir=""
  local root=""
  local config_h_path
  config_h_path="$(detect_config_h_cmake)"
  if [ -n "${config_h_path}" ] && [ -f "${config_h_path}" ]; then
    topdir="$(awk '
      $1 == "#define" && $2 == "XYMONTOPDIR" {
        value = $0
        sub(/^[^\"]*\"/, "", value)
        sub(/\".*$/, "", value)
        print value
        exit
      }
    ' "${config_h_path}" 2>/dev/null || true)"
  fi
  if [ -z "${topdir}" ]; then
    topdir="${DEFAULT_TOP}"
  fi
  root="${CMAKE_LEGACY_DESTDIR}${topdir}"
  if [ ! -d "${root}" ] && [ -d "${CMAKE_LEGACY_DESTROOT}" ]; then
    root="${CMAKE_LEGACY_DESTROOT}"
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

print_generated_makefile() {
  if [ "${BUILD_TOOL}" != "make" ]; then
    return
  fi
  if [ ! -f Makefile ]; then
    echo "Generated Makefile not found after configure" >&2
    return
  fi
  echo "=== Generated Makefile ==="
  cat Makefile
}

normalize_build_tool
normalize_compiler
normalize_profile
normalize_install_mode
normalize_verify_depth
normalize_variant
set_feature_flags
select_build_adapter

if [ "${PLATFORM_OS}" = "${OS_NAME}" ]; then
  echo "=== Setup (${OS_NAME}) ==="
else
  echo "=== Setup (${OS_NAME} on ${PLATFORM_OS}) ==="
fi
echo "=== Verify depth: ${VERIFY_DEPTH} ==="
setup_os
echo "=== Configure ==="
"${RUN_CONFIGURE_FN}"
if [ "${VERIFY_DEPTH}" = "configure" ]; then
  echo "=== Skip build/install for verify depth: configure ==="
  exit 0
fi
print_generated_makefile
echo "=== Build ==="
"${RUN_BUILD_FN}"
if [ "${VERIFY_DEPTH}" = "build" ]; then
  echo "=== Skip install for verify depth: build ==="
  exit 0
fi
echo "=== Install staged tree ==="
"${RUN_INSTALL_FN}"
echo "=== Record staged tree metadata ==="
write_staged_metadata
