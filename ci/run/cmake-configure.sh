#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/cmake-profile-helpers.sh
source "${script_dir}/cmake-profile-helpers.sh"

sanitize() {
  printf '%s' "$1"
}

PROFILE="$(sanitize "${PROFILE:-packaging}")"
ENABLE_SSL="$(sanitize "${ENABLE_SSL:-}")"
ENABLE_LDAP="$(sanitize "${ENABLE_LDAP:-}")"
VARIANT="$(sanitize "${VARIANT:-}")"
LOCALCLIENT="$(sanitize "${LOCALCLIENT:-}")"
platform_os="$(resolve_cmake_platform_os "${PLATFORM_OS:-}")"
cmake_preset="$(resolve_cmake_effective_profile "${PROFILE}" "${platform_os}")"

echo "=== CMake configure context ==="
echo "PROFILE=$PROFILE"
echo "PLATFORM_OS=$platform_os"
echo "CMAKE_PRESET=$cmake_preset"
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
  case "${cmake_preset}" in
    default|macostree|gnuinstall|packaging)
      build_dir="$(resolve_cmake_build_dir "${cmake_preset}")"
      cmake_use_gnuinstalldirs="$(resolve_cmake_use_gnuinstalldirs "${cmake_preset}")"
      cmake_install_prefix="$(resolve_cmake_install_prefix "${cmake_preset}")"
      cmake_httpdgid_chgrp="$(resolve_cmake_httpdgid_chgrp "${cmake_preset}")"
      cmake_layout="$(resolve_cmake_layout "${cmake_preset}" "${platform_os}")"
      ;;
    *)
      echo "Unsupported PROFILE=${PROFILE} (effective preset=${cmake_preset})" >&2
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
