#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/cmake-profile-helpers.sh
source "${script_dir}/cmake-profile-helpers.sh"

if [[ -z "${PROFILE:-}" ]]; then
  echo "PROFILE must be set"
  exit 1
fi

platform_os="$(resolve_cmake_platform_os "${PLATFORM_OS:-}")"
effective_profile="$(resolve_cmake_effective_profile "${PROFILE}" "${platform_os}")"
build_dir="$(resolve_cmake_build_dir "${effective_profile}")"
CMAKE="${CMAKE:-$(command -v cmake 2>/dev/null || command -v cmake3 2>/dev/null || true)}"
if [[ -z "$CMAKE" ]]; then
  echo "cmake or cmake3 not found in PATH" >&2
  exit 1
fi

if [[ ! -d "${build_dir}" ]]; then
  echo "Build directory not found: ${build_dir}"
  exit 1
fi

parallel_level="${PARALLEL_OVERRIDE:-${CMAKE_BUILD_PARALLEL_LEVEL:-1}}"
export CMAKE_BUILD_PARALLEL_LEVEL="${parallel_level}"

echo "=== CMake build ==="
echo "PROFILE=${PROFILE}"
echo "PLATFORM_OS=${platform_os}"
echo "EFFECTIVE_PROFILE=${effective_profile}"
echo "BUILD_DIR=${build_dir}"
echo "PARALLEL=${parallel_level}"
echo "==================="

"$CMAKE" --build "${build_dir}" --parallel "${parallel_level}"
