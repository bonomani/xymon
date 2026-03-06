#!/usr/bin/env bash
set -euo pipefail

runtime=""
outcome_channel=""
outcome_host_container=""
outcome_bsd_vm=""
github_output="${GITHUB_OUTPUT:-}"

usage() {
  cat <<'USAGE' >&2
Usage: resolve-lane-outcome.sh
  --runtime RUNTIME
  --outcome-channel CHANNEL
  --outcome-host-container OUTCOME
  --outcome-bsd-vm OUTCOME
  [--github-output PATH]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      runtime="${2:-}"
      shift 2
      ;;
    --outcome-channel)
      outcome_channel="${2:-}"
      shift 2
      ;;
    --outcome-host-container)
      outcome_host_container="${2:-}"
      shift 2
      ;;
    --outcome-bsd-vm)
      outcome_bsd_vm="${2:-}"
      shift 2
      ;;
    --github-output)
      github_output="${2:-}"
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

if [[ -z "${runtime}" ]]; then
  echo "Missing --runtime" >&2
  usage
fi
if [[ -z "${outcome_channel}" ]]; then
  echo "Missing --outcome-channel" >&2
  usage
fi

outcome=""
case "${outcome_channel}" in
  bsd_vm)
    outcome="${outcome_bsd_vm}"
    ;;
  host_container)
    outcome="${outcome_host_container}"
    ;;
  *)
    echo "Unsupported outcome channel '${outcome_channel}' for runtime '${runtime}'" >&2
    exit 2
    ;;
esac

if [[ -z "${outcome}" ]]; then
  echo "Missing lane outcome for runtime '${runtime}'" >&2
  exit 2
fi

if [[ -n "${github_output}" ]]; then
  printf 'value=%s\n' "${outcome}" >> "${github_output}"
else
  printf 'value=%s\n' "${outcome}"
fi
