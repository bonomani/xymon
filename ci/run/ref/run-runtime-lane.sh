#!/usr/bin/env bash
set -euo pipefail

lane_env_file="${LANE_ENV_FILE:-}"
if [[ -n "${lane_env_file}" ]]; then
  if [[ ! -f "${lane_env_file}" ]]; then
    echo "LANE_ENV_FILE not found: ${lane_env_file}" >&2
    exit 2
  fi
  set -a
  # shellcheck disable=SC1090
  source "${lane_env_file}"
  set +a
fi

runtime="${RUNTIME:-}"
if [[ -z "${runtime}" ]]; then
  echo "RUNTIME is required" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_model_path="${script_dir}/runtime-model.json"
if [[ ! -f "${runtime_model_path}" ]]; then
  echo "Missing runtime model: ${runtime_model_path}" >&2
  exit 2
fi

runtime_model_declare=$(
  python3 - <<'PY' "${runtime_model_path}"
import json
import sys
from pathlib import Path

model_path = Path(sys.argv[1])
model = json.loads(model_path.read_text(encoding='utf-8'))
print('declare -A RUNTIME_EXECUTION_BY_KEY=()')
print('declare -A RUNTIME_OUTCOME_CHANNEL_BY_KEY=()')
for entry in model.get('runtimes', []):
    key = entry['key']
    execution = entry['execution']
    outcome = entry['outcome_channel']
    print(f"RUNTIME_EXECUTION_BY_KEY[{key}]={execution}")
    print(f"RUNTIME_OUTCOME_CHANNEL_BY_KEY[{key}]={outcome}")
PY
)
eval "${runtime_model_declare}"

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

mapfile -t COMMON_KEYS < <(read_contract_section "lane_exec_required_common")
mapfile -t HOST_KEYS < <(read_contract_section "lane_exec_required_host")
mapfile -t CONTAINER_KEYS < <(read_contract_section "lane_exec_required_container")
mapfile -t VM_KEYS < <(read_contract_section "lane_exec_required_vm")

runtime_preference_string="${RUNTIME_PREFERENCE:-${runtime}}"
IFS=',' read -r -a runtime_preferences <<< "${runtime_preference_string}"
if [[ ${#runtime_preferences[@]} -eq 0 ]]; then
  runtime_preferences=("${runtime}")
fi

check_env_keys() {
  local execution="$1"
  local keys=("${COMMON_KEYS[@]}")
  case "${execution}" in
    host)
      keys+=("${HOST_KEYS[@]}")
      ;;
    container)
      keys+=("${CONTAINER_KEYS[@]}")
      ;;
    vm)
      keys+=("${VM_KEYS[@]}")
      ;;
    *)
      return 1
      ;;
  esac
  for key in "${keys[@]}"; do
    [[ -n "${key}" ]] || continue
    if [[ -z "${!key:-}" ]]; then
      return 1
    fi
  done
  return 0
}

run_runtime() {
  local runtime_key="$1"
  local execution="${RUNTIME_EXECUTION_BY_KEY[$runtime_key]:-}"
  local outcome="${RUNTIME_OUTCOME_CHANNEL_BY_KEY[$runtime_key]:-}"
  if [[ -z "${execution}" ]]; then
    return 1
  fi
  if ! check_env_keys "${execution}"; then
    return 1
  fi
  export RUNTIME="${runtime_key}"
  export RUNTIME_EXECUTION="${execution}"
  if [[ -n "${outcome}" ]]; then
    export RUNTIME_OUTCOME_CHANNEL="${outcome}"
  fi
  case "${execution}" in
    container)
      bash ci/run/ref/run-host-managed-linux-container.sh \
        bash ci/run/ref/run-ref-lane-command.sh
      ;;
    host|vm)
      bash ci/run/ref/run-ref-lane-command.sh
      ;;
    *)
      echo "Unsupported runtime execution '${execution}' for runtime '${runtime_key}'" >&2
      return 1
      ;;
  esac
}

for runtime_key in "${runtime_preferences[@]}"; do
  runtime_key="${runtime_key//[[:space:]]/}"
  [[ -n "${runtime_key}" ]] || continue
  if run_runtime "${runtime_key}"; then
    exit 0
  fi
done

echo "No viable runtime found in preference list: ${runtime_preference_string}" >&2
exit 2
