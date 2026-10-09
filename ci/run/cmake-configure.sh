#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/cmake-profile-helpers.sh
source "${script_dir}/cmake-profile-helpers.sh"

PROFILE="${PROFILE:-packaging}"
ENABLE_SSL="${ENABLE_SSL:-}"
ENABLE_LDAP="${ENABLE_LDAP:-}"
VARIANT="${VARIANT:-}"
LOCALCLIENT="${LOCALCLIENT:-}"
platform_os="$(resolve_cmake_platform_os "${PLATFORM_OS:-}")"
cmake_preset="$(resolve_cmake_effective_profile "${PROFILE}" "${platform_os}")"
CMAKE="${CMAKE:-$(command -v cmake 2>/dev/null || command -v cmake3 2>/dev/null || true)}"
if [[ -z "$CMAKE" ]]; then
  echo "cmake or cmake3 not found in PATH" >&2
  exit 1
fi

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

cmake_version_raw="$("$CMAKE" --version | head -n1 | awk '{print $3}')"
cmake_major="${cmake_version_raw%%.*}"
cmake_minor_tmp="${cmake_version_raw#*.}"
cmake_minor="${cmake_minor_tmp%%.*}"

echo "CMAKE_VERSION=$cmake_version_raw"

append_local_profile_cache_args() {
  local profile="$1"
  local arg=""
  while IFS= read -r arg; do
    if [[ -n "${arg}" ]]; then
      cmake_cmd+=("${arg}")
    fi
  done < <(emit_local_cmake_profile_cache_args "${profile}")
}

use_presets=1
if (( cmake_major < 3 )) || (( cmake_major == 3 && cmake_minor < 23 )); then
  use_presets=0
fi

echo "USE_PRESETS=$use_presets"

if (( use_presets )); then
  cmake_cmd=(
    "$CMAKE"
    --preset "$cmake_preset"
    -DENABLE_SSL="$ENABLE_SSL"
    -DENABLE_LDAP="$ENABLE_LDAP"
    -DXYMON_VARIANT="$VARIANT"
    -DLOCALCLIENT="$LOCALCLIENT"
  )
  append_local_profile_cache_args "${cmake_preset}"
  "${cmake_cmd[@]}"
else
  if ! is_supported_local_cmake_profile "${cmake_preset}"; then
    echo "Unsupported PROFILE=${PROFILE} (effective preset=${cmake_preset})" >&2
    exit 1
  fi
  cmake_use_gnuinstalldirs=""
  cmake_install_prefix=""
  cmake_httpdgid_chgrp=""
  cmake_layout=""
  build_dir="$(resolve_cmake_build_dir "${cmake_preset}")"
  cmake_use_gnuinstalldirs="$(resolve_cmake_use_gnuinstalldirs "${cmake_preset}")"
  cmake_install_prefix="$(resolve_cmake_install_prefix "${cmake_preset}")"
  cmake_httpdgid_chgrp="$(resolve_cmake_httpdgid_chgrp "${cmake_preset}")"
  cmake_layout="$(resolve_cmake_layout "${cmake_preset}" "${platform_os}")"
  cmake_cmd=(
    "$CMAKE"
    -S .
    -B "$build_dir"
    -G "Unix Makefiles"
    -DUSE_GNUINSTALLDIRS="$cmake_use_gnuinstalldirs"
    -DXYMON_LAYOUT="$cmake_layout"
    -DCMAKE_INSTALL_PREFIX="$cmake_install_prefix"
    -DHTTPDGID_CHGRP="$cmake_httpdgid_chgrp"
    -DENABLE_SSL="$ENABLE_SSL"
    -DENABLE_LDAP="$ENABLE_LDAP"
    -DXYMON_VARIANT="$VARIANT"
    -DLOCALCLIENT="$LOCALCLIENT"
  )
  append_local_profile_cache_args "${cmake_preset}"
  "${cmake_cmd[@]}"
fi
