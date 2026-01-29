#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

COMPILER="${1:-}"
if [[ -z "${COMPILER}" ]]; then
  echo "compiler must be set"
  exit 1
fi

if [[ "${COMPILER}" == "clang" ]]; then
  echo "CC=clang" >> "${GITHUB_ENV}"
  echo "CXX=clang++" >> "${GITHUB_ENV}"
else
  echo "CC=gcc" >> "${GITHUB_ENV}"
  echo "CXX=g++" >> "${GITHUB_ENV}"
fi
