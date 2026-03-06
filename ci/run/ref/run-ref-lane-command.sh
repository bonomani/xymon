#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/ref/lib/mode-model.sh
source "${script_dir}/lib/mode-model.sh"

required_vars=(
  BUILD_TOOL
  GOAL
  REF_MODE
  PUBLISH
  VARIANT
  REF_OS
  PLATFORM_OS
  PLATFORM_ID
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 2
  fi
done

# shellcheck disable=SC2153
validate_lane_build_tool "${BUILD_TOOL}"
# shellcheck disable=SC2153
validate_goal_ref_publish "${GOAL}" "${REF_MODE}" "${PUBLISH}"
# shellcheck disable=SC2153
dep_mode="$(derive_dep_mode "${GOAL}" "${REF_MODE}")"

args=(
  bash
  ci/run/ref/run-ref-lane.sh
  --build "${BUILD_TOOL}"
  --goal "${GOAL}"
  --ref-mode "${REF_MODE}"
  --publish "${PUBLISH}"
  --dep-mode "${dep_mode}"
  --variant "${VARIANT}"
  --ref-os "${REF_OS}"
  --platform-os "${PLATFORM_OS}"
  --platform-id "${PLATFORM_ID}"
)

if [[ -n "${BASELINE_ROOT:-}" ]]; then
  args+=(--baseline-root "${BASELINE_ROOT}")
fi

if [[ -n "${ARTIFACT_FAMILY:-}" ]]; then
  args+=(--artifact-family "${ARTIFACT_FAMILY}")
fi

if [[ -n "${OS_VERSION:-}" ]]; then
  args+=(--version "${OS_VERSION}")
fi

"${args[@]}"
