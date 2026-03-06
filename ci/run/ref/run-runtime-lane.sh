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

runtime_execution="${RUNTIME_EXECUTION:-}"
if [[ -z "${runtime_execution}" ]]; then
  echo "RUNTIME_EXECUTION is required" >&2
  exit 2
fi

case "${runtime_execution}" in
  container)
    bash ci/run/ref/run-host-managed-linux-container.sh \
      bash ci/run/ref/run-ref-lane-command.sh
    ;;
  host|vm)
    bash ci/run/ref/run-ref-lane-command.sh
    ;;
  *)
    echo "Unsupported runtime execution '${runtime_execution}' for runtime '${runtime}'" >&2
    exit 2
    ;;
esac
