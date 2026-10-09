#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

BUILD_TOOL="${BUILD_TOOL:?BUILD_TOOL is required}"
BUILD_TOOL="$(printf '%s' "$BUILD_TOOL" | tr '[:upper:]' '[:lower:]')"
VARIANT="server"
LOCALCLIENT="OFF"
ENABLE_SSL="ON"
ENABLE_LDAP="ON"
ENABLE_SNMP="ON"
case "$BUILD_TOOL" in
  cmake)
    PROFILE="packaging"
    ;;
  make)
    PROFILE="default"
    ;;
  *)
    echo "Unsupported BUILD_TOOL=${BUILD_TOOL}" >&2
    exit 1
    ;;
esac

export PROFILE VARIANT LOCALCLIENT ENABLE_SSL ENABLE_LDAP ENABLE_SNMP

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
echo "PROFILE=${PROFILE}"
echo "LOCALCLIENT=${LOCALCLIENT}"
echo "ENABLE_SSL=${ENABLE_SSL}"
echo "ENABLE_LDAP=${ENABLE_LDAP}"
echo "ENABLE_SNMP=${ENABLE_SNMP}"
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
      --build make \
      --profile "$PROFILE"
    ;;
esac
