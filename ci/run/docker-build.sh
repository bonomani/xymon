#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

BUILD_TOOL="${BUILD_TOOL:-cmake}"
BUILD_TOOL="$(printf '%s' "$BUILD_TOOL" | tr '[:upper:]' '[:lower:]')"
VARIANT="${VARIANT:-server}"
LOCALCLIENT="${LOCALCLIENT:-OFF}"
PRESET="${PRESET:-packaging}"

normalize_yesno() {
  case "${1,,}" in
    on|yes|y|true|1)
      printf 'yes'
      ;;
    off|no|n|false|0)
      printf 'no'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

echo "=== Docker build context ==="
echo "BUILD_TOOL=${BUILD_TOOL}"
echo "VARIANT=${VARIANT}"
echo "PRESET=${PRESET}"
echo "LOCALCLIENT=${LOCALCLIENT}"
echo "ENABLE_SSL=${ENABLE_SSL:-ON}"
echo "ENABLE_LDAP=${ENABLE_LDAP:-ON}"
echo "ENABLE_SNMP=${ENABLE_SNMP:-ON}"
echo "==========================="

case "$BUILD_TOOL" in
  cmake)
    bash ci/run/cmake-configure.sh
    bash ci/run/cmake-build.sh
    ;;
  make)
    localclient_flag="$(normalize_yesno "$LOCALCLIENT")"
    bash ci/bootstrap-install.sh \
      --os linux \
      --variant "$VARIANT" \
      --localclient "$localclient_flag" \
      --build make
    ;;
  *)
    echo "Unsupported BUILD_TOOL=${BUILD_TOOL}" >&2
    exit 1
    ;;
esac
