#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  BUILD_TOOL
  GOAL
  REF_MODE
  PUBLISH
  DEP_MODE
  CI_DEPS_REPORT_JSON
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

args=(
  bash
  ci/run/ref/run-ref-lane.sh
  --build "${BUILD_TOOL}"
  --goal "${GOAL}"
  --ref-mode "${REF_MODE}"
  --publish "${PUBLISH}"
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
