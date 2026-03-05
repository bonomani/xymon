#!/usr/bin/env bash
set -euo pipefail

build_tool=""
variant=""
baseline_root=""
ref_os="linux"
artifact_family=""
platform_id=""
run_compare="1"

usage() {
  cat <<'USAGE' >&2
Usage: run-linux-ref-validation.sh --build TOOL --variant NAME --baseline-root ROOT --artifact-family FAMILY --platform-id ID [--ref-os OS] [--run-compare 1|0]
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
    --run-compare)
      run_compare="${2:-}"
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

baseline_prefix="docs/cmake-legacy-migration/refs/${baseline_root}/${variant}"
refs_root=".ci-artifacts/ref-valid-${artifact_family}/refs"
artifact_root=".ci-artifacts/ref-valid-${artifact_family}/${build_tool}-${platform_id}-${variant}"
candidate_dir="${refs_root}/${build_tool}.${ref_os}.${variant}"

bash ci/run/ref/load-legacy-hostname.sh \
  --config "docs/cmake-legacy-migration/refs/${baseline_root}/server/var/lib/xymon/server/etc/xymonserver.cfg"

bash ci/run/ref/seed-legacy-identities.sh \
  --passwd "docs/cmake-legacy-migration/refs/${baseline_root}/${variant}/owners.passwd" \
  --group "docs/cmake-legacy-migration/refs/${baseline_root}/${variant}/owners.group"

bash ci/run/ref/bootstrap-build-refs.sh \
  --build "${build_tool}" \
  --os "${ref_os}" \
  --variant "${variant}" \
  --ref-prefix "${baseline_prefix}" \
  --refs-root "${refs_root}" \
  --artifact-root "${artifact_root}"

if [[ "${run_compare}" == "1" ]]; then
  # This helper must run in the current shell so LEGACY_ROOT and friends remain available.
  # shellcheck source=ci/run/ref/load-staged-metadata.sh
  source ci/run/ref/load-staged-metadata.sh

  bash ci/compare-refs.sh \
    --baseline-prefix "${baseline_prefix}" \
    --candidate-dir "${candidate_dir}" \
    --candidate-root "${LEGACY_ROOT}"
else
  echo "Skipping compare step (--run-compare=0)."
fi
