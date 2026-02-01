#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

sanitize() {
  printf '%s' "$1"
}

PRESET="$(sanitize "${PRESET:-packaging}")"
ENABLE_SSL="$(sanitize "${ENABLE_SSL:-}")"
ENABLE_LDAP="$(sanitize "${ENABLE_LDAP:-}")"
VARIANT="$(sanitize "${VARIANT:-}")"
LOCALCLIENT="$(sanitize "${LOCALCLIENT:-}")"

echo "=== CMake configure context ==="
echo "PRESET=$PRESET"
echo "ENABLE_SSL=$ENABLE_SSL"
echo "ENABLE_LDAP=$ENABLE_LDAP"
echo "VARIANT=$VARIANT"
echo "LOCALCLIENT=$LOCALCLIENT"
echo "PWD=$(pwd)"
echo "==============================="

if [[ -z "$PRESET" || -z "$ENABLE_SSL" || -z "$ENABLE_LDAP" || -z "$VARIANT" ]]; then
  echo "PRESET, ENABLE_SSL, ENABLE_LDAP, and VARIANT must be set"
  exit 1
fi

if [[ -z "$LOCALCLIENT" ]]; then
  if [[ "$VARIANT" == "server" ]]; then
    LOCALCLIENT=OFF
  else
    echo "LOCALCLIENT must be set for variant $VARIANT"
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
  cmake --preset "$PRESET" \
    -DENABLE_SSL="$ENABLE_SSL" \
    -DENABLE_LDAP="$ENABLE_LDAP" \
    -DXYMON_VARIANT="$VARIANT" \
    -DLOCALCLIENT="$LOCALCLIENT"
else
  build_dir="build-cmake-$PRESET"
  cmake -S . -B "$build_dir" \
    -G "Unix Makefiles" \
    -DUSE_GNUINSTALLDIRS=ON \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DHTTPDGID_CHGRP=OFF \
    -DENABLE_SSL="$ENABLE_SSL" \
    -DENABLE_LDAP="$ENABLE_LDAP" \
    -DXYMON_VARIANT="$VARIANT" \
    -DLOCALCLIENT="$LOCALCLIENT"
fi

