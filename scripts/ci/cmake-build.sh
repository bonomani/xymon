#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${PRESET:-}" ]]; then
  echo "PRESET must be set"
  exit 1
fi

CMAKE_BUILD_PARALLEL_LEVEL=1
export CMAKE_BUILD_PARALLEL_LEVEL
cmake --build --preset "${PRESET}" --parallel 1
