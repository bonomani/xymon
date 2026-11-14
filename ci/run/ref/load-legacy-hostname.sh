#!/usr/bin/env bash
set -euo pipefail

legacy_cfg=""
env_file="${GITHUB_ENV:-}"

usage() {
  cat <<'USAGE' >&2
Usage: load-legacy-hostname.sh --config PATH [--env-file PATH]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      legacy_cfg="${2:-}"
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

if [[ -z "${legacy_cfg}" ]]; then
  echo "Missing --config" >&2
  usage
fi

echo "Legacy hostname: checking ${legacy_cfg}"
if [[ ! -f "${legacy_cfg}" ]]; then
  echo "Legacy hostname: skipped (missing ${legacy_cfg})"
  exit 0
fi

legacy_host="$(
  tr -d '\r' < "${legacy_cfg}" \
    | awk -F'"' '/^XYMONSERVERHOSTNAME=/{if(!found){print $2; found=1}} END{if(!found) exit 1}' \
    || true
)"

if [[ -z "${legacy_host}" ]]; then
  legacy_host="$(
    tr -d '\r' < "${legacy_cfg}" \
      | awk '/^XYMONSERVERHOSTNAME=/{sub(/^.*=/,""); sub(/[[:space:]]*#.*/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); gsub(/^"|"$/,""); if(!found){print; found=1}} END{if(!found) exit 1}' \
      || true
  )"
fi

if [[ -z "${legacy_host}" ]]; then
  echo "Legacy hostname: skipped (no XYMONSERVERHOSTNAME in ${legacy_cfg})"
  echo "Legacy hostname: first 5 non-comment lines for debug:"
  tr -d '\r' < "${legacy_cfg}" \
    | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    | head -n5
  exit 0
fi

if [[ -n "${env_file}" ]]; then
  echo "XYMONHOSTNAME=${legacy_host}" >> "${env_file}"
else
  export XYMONHOSTNAME="${legacy_host}"
fi

echo "Using legacy hostname: ${legacy_host}"
