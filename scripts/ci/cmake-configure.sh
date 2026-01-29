#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${PRESET:-}" || -z "${ENABLE_SSL:-}" || -z "${ENABLE_LDAP:-}" || -z "${XYMON_VARIANT:-}" ]]; then
  echo "PRESET, ENABLE_SSL, ENABLE_LDAP, and XYMON_VARIANT must be set"
  exit 1
fi

if [[ -z "${LOCALCLIENT:-}" ]]; then
  if [[ "${XYMON_VARIANT}" == "server" ]]; then
    # LOCALCLIENT is only relevant for non-server variants.
    LOCALCLIENT=OFF
  else
    echo "LOCALCLIENT must be set for variant ${XYMON_VARIANT}"
    exit 1
  fi
fi

cmake --preset "${PRESET}" \
  -DENABLE_SSL="${ENABLE_SSL}" \
  -DENABLE_LDAP="${ENABLE_LDAP}" \
  -DXYMON_VARIANT="${XYMON_VARIANT}" \
  -DLOCALCLIENT="${LOCALCLIENT}"
