#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${PRESET:-}" ]]; then
  echo "PRESET must be set"
  exit 1
fi

parallel_level="${PARALLEL_OVERRIDE:-${CMAKE_BUILD_PARALLEL_LEVEL:-1}}"
CMAKE_BUILD_PARALLEL_LEVEL="${parallel_level}"
export CMAKE_BUILD_PARALLEL_LEVEL
cmake --build --preset "${PRESET}" --parallel "${parallel_level}"
