#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

COMPILER="${1:-}"
if [[ -z "${COMPILER}" ]]; then
  echo "compiler must be set (expected: gcc or clang)" >&2
  exit 1
fi

case "${COMPILER}" in
  gcc)
    echo "CC=gcc" >> "${GITHUB_ENV}"
    echo "CXX=g++" >> "${GITHUB_ENV}"
    ;;
  clang)
    echo "CC=clang" >> "${GITHUB_ENV}"
    echo "CXX=clang++" >> "${GITHUB_ENV}"
    ;;
  *)
    echo "unsupported compiler '${COMPILER}' (expected: gcc or clang)" >&2
    exit 1
    ;;
esac
