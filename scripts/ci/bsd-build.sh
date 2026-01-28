#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${VARIANT:-}" ]]; then
  echo "VARIANT must be set"
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

BUILD_DIR=build-bsd-${VARIANT}
CMAKE_BUILD_PARALLEL_LEVEL=1
export CMAKE_BUILD_PARALLEL_LEVEL
cmake -S . -B "${BUILD_DIR}" \
  -G "Unix Makefiles" \
  -DENABLE_SSL="${ENABLE_SSL}" \
  -DENABLE_LDAP=OFF \
  -DXYMON_VARIANT="${VARIANT}" \
  -DLOCALCLIENT=OFF
cmake --build "${BUILD_DIR}" --parallel 1
