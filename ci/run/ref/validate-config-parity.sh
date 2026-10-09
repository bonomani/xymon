#!/usr/bin/env bash
set -euo pipefail

legacy_config=""
cmake_config="${XYMON_CONFIG_H:-}"
build_dir="build-cmake"

usage() {
  cat <<'USAGE' >&2
Usage: validate-config-parity.sh --legacy-config PATH [--cmake-config PATH] [--build-dir DIR]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --legacy-config)
      legacy_config="${2:-}"
      shift 2
      ;;
    --cmake-config)
      cmake_config="${2:-}"
      shift 2
      ;;
    --build-dir)
      build_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "${legacy_config}" ]]; then
  usage
fi

if [[ -z "${cmake_config}" || ! -f "${cmake_config}" ]]; then
  cmake_config="$(find "${build_dir}" -path '*/include/config.h' | head -n1 || true)"
fi
if [[ -z "${cmake_config}" || ! -f "${cmake_config}" ]]; then
  cmake_config="$(find "${build_dir}" -name config.h | head -n1 || true)"
fi
if [[ -z "${cmake_config}" || ! -f "${cmake_config}" ]]; then
  echo "No CMake-generated config.h found under ${build_dir}"
  exit 1
fi
if [[ ! -f "${legacy_config}" ]]; then
  echo "Baseline config.h not found at ${legacy_config}"
  exit 1
fi

grep -E '^(#define|#undef) (WORDS_|HAVE_|PATH_MAX|XYMON[A-Z_]*DIR)' "${legacy_config}" \
  | grep -v '^#.*HAVE_RPCENT_H' \
  | sort > /tmp/legacy.config.extract
grep -E '^(#define|#undef) (WORDS_|HAVE_|PATH_MAX|XYMON[A-Z_]*DIR)' "${cmake_config}" \
  | grep -v '^#define XYMON' \
  | sed -E 's/^#define HAVE_BINARY_TREE 0$/#undef HAVE_BINARY_TREE/' \
  | grep -v '^#.*HAVE_RPCENT_H' \
  | sort > /tmp/cmake.config.extract

diff -u /tmp/legacy.config.extract /tmp/cmake.config.extract || true
if ! diff -u /tmp/legacy.config.extract /tmp/cmake.config.extract > /tmp/config.diff; then
  echo "config.h parity diff detected:"
  cat /tmp/config.diff
  exit 1
fi
