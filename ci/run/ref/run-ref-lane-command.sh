#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  BUILD_TOOL
  GOAL
  REF_MODE
  PUBLISH
  DEP_MODE
  VARIANT
  BASELINE_ROOT
  REF_OS
  PLATFORM_OS
  ARTIFACT_FAMILY
  PLATFORM_ID
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 2
  fi
done

args=(
  bash
  ci/run/ref/run-ref-lane.sh
  --build "${BUILD_TOOL}"
  --goal "${GOAL}"
  --ref-mode "${REF_MODE}"
  --publish "${PUBLISH}"
  --dep-mode "${DEP_MODE}"
  --variant "${VARIANT}"
  --baseline-root "${BASELINE_ROOT}"
  --ref-os "${REF_OS}"
  --platform-os "${PLATFORM_OS}"
  --artifact-family "${ARTIFACT_FAMILY}"
  --platform-id "${PLATFORM_ID}"
)

if [[ -n "${OS_VERSION:-}" ]]; then
  args+=(--version "${OS_VERSION}")
fi

"${args[@]}"
