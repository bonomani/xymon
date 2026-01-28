#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${PRESET:-}" || -z "${ENABLE_SSL:-}" || -z "${ENABLE_LDAP:-}" || -z "${XYMON_VARIANT:-}" || -z "${LOCALCLIENT:-}" ]]; then
  echo "PRESET, ENABLE_SSL, ENABLE_LDAP, XYMON_VARIANT, and LOCALCLIENT must be set"
  exit 1
fi

cmake --preset "${PRESET}" \
  -DENABLE_SSL="${ENABLE_SSL}" \
  -DENABLE_LDAP="${ENABLE_LDAP}" \
  -DXYMON_VARIANT="${XYMON_VARIANT}" \
  -DLOCALCLIENT="${LOCALCLIENT}"
