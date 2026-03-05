#!/usr/bin/env bash
set -euo pipefail

build_tool=""
variant=""
baseline_root=""
ref_os="linux"
artifact_family=""
platform_id=""
platform_os=""
run_compare="1"
publish="none"

usage() {
  cat <<'USAGE' >&2
Usage: run-linux-ref-validation.sh --build TOOL --variant NAME --baseline-root ROOT --artifact-family FAMILY --platform-id ID [--ref-os OS] [--platform-os OS] [--run-compare 1|0] [--publish none|artifact|registry]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      build_tool="${2:-}"
      shift 2
      ;;
    --variant)
      variant="${2:-}"
      shift 2
      ;;
    --baseline-root)
      baseline_root="${2:-}"
      shift 2
      ;;
    --ref-os)
      ref_os="${2:-}"
      shift 2
      ;;
    --artifact-family)
      artifact_family="${2:-}"
      shift 2
      ;;
    --platform-id)
      platform_id="${2:-}"
      shift 2
      ;;
    --platform-os)
      platform_os="${2:-}"
      shift 2
      ;;
    --run-compare)
      run_compare="${2:-}"
      shift 2
      ;;
    --publish)
      publish="${2:-}"
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

case "${build_tool}" in
  make|cmake)
    ;;
  *)
    echo "Unsupported --build value: ${build_tool}" >&2
    usage
    ;;
esac

case "$(printf '%s' "${run_compare}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)
    run_compare="1"
    ;;
  0|false|no|off)
    run_compare="0"
    ;;
  *)
    echo "Unsupported --run-compare value: ${run_compare}" >&2
    usage
    ;;
esac

if [[ -z "${variant}" || -z "${baseline_root}" || -z "${artifact_family}" || -z "${platform_id}" ]]; then
  usage
fi

if [[ -z "${platform_os}" ]]; then
  platform_os="${ref_os}"
fi

bash ci/run/ref/run-ref-lane.sh \
  --build "${build_tool}" \
  --goal ref \
  --ref-mode compare \
  --publish "${publish}" \
  --platform-os "${platform_os}" \
  --ref-os "${ref_os}" \
  --variant "${variant}" \
  --baseline-root "${baseline_root}" \
  --artifact-family "${artifact_family}" \
  --platform-id "${platform_id}" \
  --run-compare "${run_compare}"
