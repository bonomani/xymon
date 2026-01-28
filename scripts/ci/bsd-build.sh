#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${VARIANT:-}" || -z "${PRESET:-}" || -z "${ENABLE_LDAP:-}" || -z "${LOCALCLIENT:-}" ]]; then
  echo "VARIANT, PRESET, ENABLE_LDAP, and LOCALCLIENT must be set"
  exit 1
fi

case "${VARIANT}" in
  server)
    ENABLE_SSL=ON
    ;;
  client)
    ENABLE_SSL=OFF
    ;;
  *)
    echo "Unknown VARIANT: ${VARIANT}"
    exit 1
    ;;
esac

bash scripts/ci/bsd-setup.sh

export PRESET
export ENABLE_SSL
export ENABLE_LDAP
export XYMON_VARIANT="${VARIANT}"
export LOCALCLIENT

bash scripts/ci/cmake-configure.sh
bash scripts/ci/cmake-build.sh
