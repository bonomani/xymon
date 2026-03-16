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

contract_file="${script_dir}/lane-env-contract.txt"
if [[ ! -f "${contract_file}" ]]; then
  echo "Missing lane env contract file: ${contract_file}" >&2
  exit 2
fi

# shellcheck source=ci/run/ref/lane-contract-helpers.sh
source "${script_dir}/lane-contract-helpers.sh"

runtime_preference_string="${RUNTIME_PREFERENCE:-${runtime}}"
IFS=',' read -r -a runtime_preferences <<< "${runtime_preference_string}"
if [[ ${#runtime_preferences[@]} -eq 0 ]]; then
  runtime_preferences=("${runtime}")
fi
runtime_not_viable_status=125

check_required_section_keys() {
  local section="$1"
  local key=""
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    if [[ -z "${!key:-}" ]]; then
      return 1
    fi
  done < <(read_contract_section "${section}")
  return 0
}

check_env_keys() {
  local execution="$1"
  local section=""
  case "${execution}" in
    host)
      section="lane_exec_required_host"
      ;;
    container)
      section="lane_exec_required_container"
      ;;
    vm)
      section="lane_exec_required_vm"
      ;;
    *)
      return 1
      ;;
  esac
  check_required_section_keys "lane_exec_required_common" || return 1
  check_required_section_keys "${section}"
}

resolve_runtime_metadata() {
  local runtime_key="$1"
  local execution=""
  local outcome=""

  case "${runtime_key}" in
    linux_host)
      execution="host"
      outcome="host_container"
      ;;
    linux_container)
      execution="container"
      outcome="host_container"
      ;;
    bsd_vm)
      execution="vm"
      outcome="bsd_vm"
      ;;
    macos_host)
      execution="host"
      outcome="host_container"
      ;;
    *)
      echo "Unsupported runtime: ${runtime_key}" >&2
      return 1
      ;;
  esac

  if [[ "${runtime_key}" == "${RUNTIME:-}" ]]; then
    if [[ -n "${RUNTIME_EXECUTION:-}" ]]; then
      execution="${RUNTIME_EXECUTION}"
    fi
    if [[ -n "${RUNTIME_OUTCOME_CHANNEL:-}" ]]; then
      outcome="${RUNTIME_OUTCOME_CHANNEL}"
    fi
  fi

  printf 'execution=%s\n' "${execution}"
  printf 'outcome_channel=%s\n' "${outcome}"
}

run_runtime() {
  local runtime_key="$1"
  local execution outcome key value metadata
  execution=""
  outcome=""
  metadata="$(resolve_runtime_metadata "${runtime_key}")" || return $?
  while IFS='=' read -r key value; do
    case "${key}" in
      execution)
        execution="${value}"
        ;;
      outcome_channel)
        outcome="${value}"
        ;;
    esac
  done <<< "${metadata}"
  if [[ -z "${execution}" ]]; then
    return "${runtime_not_viable_status}"
  fi
  if ! check_env_keys "${execution}"; then
    return "${runtime_not_viable_status}"
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
  status=0
  runtime_key="${runtime_key//[[:space:]]/}"
  [[ -n "${runtime_key}" ]] || continue
  if run_runtime "${runtime_key}"; then
    exit 0
  else
    status=$?
  fi
  if [[ "${status}" -ne "${runtime_not_viable_status}" ]]; then
    exit "${status}"
  fi
done

echo "No viable runtime found in preference list: ${runtime_preference_string}" >&2
exit 2
