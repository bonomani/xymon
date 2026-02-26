#!/usr/bin/env bash
set -euo pipefail

vars_file="/tmp/xymon-root-vars.sh"
env_file="${GITHUB_ENV:-}"

usage() {
  cat <<'USAGE' >&2
Usage: load-staged-metadata.sh [--vars-file PATH] [--env-file PATH]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      vars_file="${2:-}"
      shift 2
      ;;
    --env-file)
      env_file="${2:-}"
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

if [[ ! -f "${vars_file}" ]]; then
  echo "Staged tree metadata missing" >&2
  exit 1
fi

# shellcheck source=/tmp/xymon-root-vars.sh
source "${vars_file}"
: "${LEGACY_TOPDIR:?missing LEGACY_TOPDIR}"
: "${LEGACY_ROOT:?missing LEGACY_ROOT}"

if [[ -n "${env_file}" ]]; then
  echo "LEGACY_TOPDIR=${LEGACY_TOPDIR}" >> "${env_file}"
  echo "LEGACY_ROOT=${LEGACY_ROOT}" >> "${env_file}"
  echo "XYMON_CONFIG_H=${XYMON_CONFIG_H:-}" >> "${env_file}"
fi
