#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

sanitize() {
  printf '%s' "$1"
}

PROFILE="$(sanitize "${PROFILE:-packaging}")"
ENABLE_SSL="$(sanitize "${ENABLE_SSL:-}")"
ENABLE_LDAP="$(sanitize "${ENABLE_LDAP:-}")"
VARIANT="$(sanitize "${VARIANT:-}")"
LOCALCLIENT="$(sanitize "${LOCALCLIENT:-}")"
cmake_preset="${PROFILE}"

echo "=== CMake configure context ==="
echo "PROFILE=$PROFILE"
echo "ENABLE_SSL=$ENABLE_SSL"
echo "ENABLE_LDAP=$ENABLE_LDAP"
echo "VARIANT=$VARIANT"
echo "LOCALCLIENT=$LOCALCLIENT"
echo "PWD=$(pwd)"
echo "==============================="

if [[ -z "$PROFILE" || -z "$ENABLE_SSL" || -z "$ENABLE_LDAP" || -z "$VARIANT" ]]; then
  echo "PROFILE, ENABLE_SSL, ENABLE_LDAP, and VARIANT must be set"
  exit 1
fi

if [[ -z "$LOCALCLIENT" ]]; then
  if [[ "$VARIANT" == "server" ]]; then
    LOCALCLIENT=OFF
  else
    echo "LOCALCLIENT must be set for VARIANT=$VARIANT"
    exit 1
  fi
fi

cmake_version_raw="$(cmake --version | head -n1 | awk '{print $3}')"
cmake_major="${cmake_version_raw%%.*}"
cmake_minor_tmp="${cmake_version_raw#*.}"
cmake_minor="${cmake_minor_tmp%%.*}"

echo "CMAKE_VERSION=$cmake_version_raw"

use_presets=1
if (( cmake_major < 3 )) || (( cmake_major == 3 && cmake_minor < 23 )); then
  use_presets=0
fi

echo "USE_PRESETS=$use_presets"

if (( use_presets )); then
  cmake --preset "$cmake_preset" \
    -DENABLE_SSL="$ENABLE_SSL" \
    -DENABLE_LDAP="$ENABLE_LDAP" \
    -DXYMON_VARIANT="$VARIANT" \
    -DLOCALCLIENT="$LOCALCLIENT"
else
  cmake_use_gnuinstalldirs=""
  cmake_install_prefix=""
  cmake_httpdgid_chgrp=""
  cmake_layout=""
  system_name="$(uname -s)"
  case "${PROFILE}" in
    default)
      build_dir="build-cmake"
      cmake_use_gnuinstalldirs="OFF"
      cmake_install_prefix="/"
      cmake_httpdgid_chgrp="ON"
      if [[ "$system_name" == "FreeBSD" || "$system_name" == "NetBSD" ]]; then
        cmake_layout="home_tree"
      else
        cmake_layout="var_tree"
      fi
      ;;
    gnuinstall)
      build_dir="build-cmake-gnu"
      cmake_use_gnuinstalldirs="ON"
      cmake_install_prefix="/"
      cmake_httpdgid_chgrp="ON"
      cmake_layout="fhs"
      ;;
    packaging)
      build_dir="build-cmake-packaging"
      cmake_use_gnuinstalldirs="ON"
      cmake_install_prefix="/usr"
      cmake_httpdgid_chgrp="OFF"
      cmake_layout="fhs"
      ;;
    *)
      echo "Unsupported PROFILE=${PROFILE}" >&2
      exit 1
      ;;
  esac
  cmake -S . -B "$build_dir" \
    -G "Unix Makefiles" \
    -DUSE_GNUINSTALLDIRS="$cmake_use_gnuinstalldirs" \
    -DXYMON_LAYOUT="$cmake_layout" \
    -DCMAKE_INSTALL_PREFIX="$cmake_install_prefix" \
    -DHTTPDGID_CHGRP="$cmake_httpdgid_chgrp" \
    -DENABLE_SSL="$ENABLE_SSL" \
    -DENABLE_LDAP="$ENABLE_LDAP" \
    -DXYMON_VARIANT="$VARIANT" \
    -DLOCALCLIENT="$LOCALCLIENT"
fi
