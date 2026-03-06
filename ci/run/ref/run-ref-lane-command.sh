#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
contract_file="${script_dir}/lane-env-contract.txt"

if [[ ! -f "${contract_file}" ]]; then
  echo "Missing lane env contract file: ${contract_file}" >&2
  exit 2
fi

required_vars=()
while IFS= read -r key; do
  required_vars+=("${key}")
done < <(
  awk -v section="lane_exec_required" '
    BEGIN { in_section = 0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^\[[^]]+\][[:space:]]*$/ {
      name = $0
      sub(/^\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      in_section = (name == section)
      next
    }
    in_section { print $0 }
  ' "${contract_file}"
)

if [[ "${#required_vars[@]}" -eq 0 ]]; then
  echo "No keys found in [lane_exec_required] section: ${contract_file}" >&2
  exit 2
fi

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
