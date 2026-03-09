#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
contract_file="${script_dir}/lane-env-contract.txt"

if [[ ! -f "${contract_file}" ]]; then
  echo "Missing lane env contract file: ${contract_file}" >&2
  exit 2
fi

read_contract_section() {
  local section="$1"
  awk -v section="${section}" '
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
}

runtime_execution="${RUNTIME_EXECUTION:-}"
if [[ -z "${runtime_execution}" ]]; then
  echo "Missing required environment variable: RUNTIME_EXECUTION" >&2
  exit 2
fi

section_suffix=""
case "${runtime_execution}" in
  host)
    section_suffix="host"
    ;;
  container)
    section_suffix="container"
    ;;
  vm)
    section_suffix="vm"
    ;;
  *)
    echo "Unsupported RUNTIME_EXECUTION value: ${runtime_execution}" >&2
    exit 2
    ;;
esac

required_vars=()
while IFS= read -r key; do
  required_vars+=("${key}")
done < <(read_contract_section "lane_exec_required_common")
while IFS= read -r key; do
  required_vars+=("${key}")
done < <(read_contract_section "lane_exec_required_${section_suffix}")

if [[ "${#required_vars[@]}" -eq 0 ]]; then
  echo "No keys found in lane_exec_required sections: ${contract_file}" >&2
  exit 2
fi

seen_required="|"
for var_name in "${required_vars[@]}"; do
  [[ -n "${var_name}" ]] || continue
  case "${seen_required}" in
    *"|${var_name}|"*)
      continue
      ;;
  esac
  seen_required="${seen_required}${var_name}|"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 2
  fi
done

args=(
  bash
  ci/run/ref/run-ref-lane.sh
  --build "${BUILD_TOOL}"
  --compiler "${CI_COMPILER}"
  --profile "${PROFILE}"
  --install-mode "${INSTALL_MODE}"
  --goal "${GOAL}"
  --verify-depth "${VERIFY_DEPTH}"
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

if [[ -n "${REFS_ROOT:-}" ]]; then
  args+=(--refs-root "${REFS_ROOT}")
fi

if [[ -n "${ARTIFACT_ROOT:-}" ]]; then
  args+=(--artifact-root "${ARTIFACT_ROOT}")
fi

if [[ -n "${BASELINE_PREFIX:-}" ]]; then
  args+=(--baseline-prefix "${BASELINE_PREFIX}")
fi

if [[ -n "${CANDIDATE_DIR:-}" ]]; then
  args+=(--candidate-dir "${CANDIDATE_DIR}")
fi

if [[ -n "${LEGACY_HOSTNAME_CONFIG:-}" ]]; then
  args+=(--legacy-hostname-config "${LEGACY_HOSTNAME_CONFIG}")
fi

if [[ -n "${OS_VERSION:-}" ]]; then
  args+=(--version "${OS_VERSION}")
fi

"${args[@]}"
