#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${PRESET:-}" || -z "${ENABLE_SSL:-}" || -z "${ENABLE_LDAP:-}" || -z "${VARIANT:-}" ]]; then
  echo "PRESET, ENABLE_SSL, ENABLE_LDAP, and VARIANT must be set"
  exit 1
fi

if [[ -z "${LOCALCLIENT:-}" ]]; then
  if [[ "${VARIANT}" == "server" ]]; then
    # LOCALCLIENT is only relevant for non-server variants.
    LOCALCLIENT=OFF
  else
    echo "LOCALCLIENT must be set for variant ${VARIANT}"
    exit 1
  fi
fi

cmake --preset "${PRESET}" \	
  -DENABLE_SSL="${ENABLE_SSL}" \
  -DENABLE_LDAP="${ENABLE_LDAP}" \
  -DXYMON_VARIANT="${VARIANT}" \
  -DLOCALCLIENT="${LOCALCLIENT}"
