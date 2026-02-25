#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

if [[ -z "${PRESET:-}" ]]; then
  echo "PRESET must be set"
  exit 1
fi

case "${PRESET}" in
  default)
    build_dir="build-cmake"
    ;;
  gnuinstall)
    build_dir="build-cmake-gnu"
    ;;
  packaging)
    build_dir="build-cmake-packaging"
    ;;
  *)
    build_dir="build-cmake/${PRESET}"
    ;;
esac

if [[ ! -d "${build_dir}" ]]; then
  echo "Build directory not found: ${build_dir}"
  exit 1
fi

parallel_level="${PARALLEL_OVERRIDE:-${CMAKE_BUILD_PARALLEL_LEVEL:-1}}"
export CMAKE_BUILD_PARALLEL_LEVEL="${parallel_level}"

echo "=== CMake build ==="
echo "PRESET=${PRESET}"
echo "BUILD_DIR=${build_dir}"
echo "PARALLEL=${parallel_level}"
echo "==================="

cmake --build "${build_dir}" --parallel "${parallel_level}"
