#!/usr/bin/env bash
set -euo pipefail

runtime="${RUNTIME:-}"
if [[ -z "${runtime}" ]]; then
  echo "RUNTIME is required" >&2
  exit 2
fi

case "${runtime}" in
  linux_container)
    bash ci/run/ref/run-host-managed-linux-container.sh \
      bash ci/run/ref/run-ref-lane-command.sh
    ;;
  linux_host|macos_host)
    if [[ "${runtime}" == "macos_host" ]]; then
      export XYMONUSER="${XYMONUSER:-_www}"
      export XYMONGROUP="${XYMONGROUP:-_www}"
    fi
    bash ci/run/ref/run-ref-lane-command.sh
    ;;
  *)
    echo "Unsupported runtime for run-runtime-lane.sh: ${runtime}" >&2
    exit 2
    ;;
esac
