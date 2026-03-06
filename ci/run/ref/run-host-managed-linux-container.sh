#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: run-host-managed-linux-container.sh <command> [args...]" >&2
  exit 2
fi

CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
CONTAINER_OPTIONS="${CONTAINER_OPTIONS:-}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-}"
LANE_ENV_FILE="${LANE_ENV_FILE:-}"

if [[ -z "${CONTAINER_IMAGE}" ]]; then
  echo "CONTAINER_IMAGE is required" >&2
  exit 2
fi

if [[ -z "${GITHUB_WORKSPACE}" ]]; then
  echo "GITHUB_WORKSPACE is required" >&2
  exit 2
fi

if [[ -z "${LANE_ENV_FILE}" ]]; then
  echo "LANE_ENV_FILE is required" >&2
  exit 2
fi

if [[ ! -f "${LANE_ENV_FILE}" ]]; then
  echo "LANE_ENV_FILE not found: ${LANE_ENV_FILE}" >&2
  exit 2
fi

container_opts=()
if [[ -n "${CONTAINER_OPTIONS}" ]]; then
  read -r -a container_opts <<< "${CONTAINER_OPTIONS}"
fi

docker_args=(run --rm)
docker_args+=("${container_opts[@]}")
docker_args+=(
  -e "HOME=/tmp/github-home"
  -v "${GITHUB_WORKSPACE}:${GITHUB_WORKSPACE}"
  -v "/tmp:/tmp"
  -w "${GITHUB_WORKSPACE}"
)

lane_env_keys=()
while IFS= read -r line; do
  if [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    lane_env_keys+=("${BASH_REMATCH[1]}")
  fi
done < "${LANE_ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${LANE_ENV_FILE}"
set +a

allow_container_token=0
if [[ "${CHECKOUT_MODE:-action}" == "git" ]]; then
  allow_container_token=1
fi

for docker_key in "${lane_env_keys[@]}"; do
  if [[ "${docker_key}" == "GITHUB_TOKEN" && "${allow_container_token}" != "1" ]]; then
    continue
  fi
  if [[ -v "${docker_key}" ]]; then
    docker_args+=(-e "${docker_key}=${!docker_key}")
  fi
done

docker_args+=(
  "${CONTAINER_IMAGE}"
  sh
  -lc
  'set -eu
   mkdir -p /tmp/github-home
   # The repository is already checked out on the host; the container only
   # needs runtime tools installed before running the requested command.
   sh ci/run/ref/prepare-checkout-tools-bootstrap.sh \
     --prepare-profile "${PREPARE_PROFILE:-default}" \
     --checkout-mode "${CHECKOUT_MODE:-action}"
   exec "$@"'
  sh
  "$@"
)

docker "${docker_args[@]}"
