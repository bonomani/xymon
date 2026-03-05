#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: run-host-managed-linux-container.sh <command> [args...]" >&2
  exit 2
fi

CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
CONTAINER_OPTIONS="${CONTAINER_OPTIONS:-}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-}"

if [[ -z "${CONTAINER_IMAGE}" ]]; then
  echo "CONTAINER_IMAGE is required" >&2
  exit 2
fi

if [[ -z "${GITHUB_WORKSPACE}" ]]; then
  echo "GITHUB_WORKSPACE is required" >&2
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

forward_envs=(
  BUILD_TOOL
  REF_OS
  PLATFORM_OS
  PLATFORM_ID
  VARIANT
  PREPARE_PROFILE
  CHECKOUT_MODE
  UPLOAD_ARTIFACTS
  REF_STAGE_ROOT
  ENABLE_LDAP
  ENABLE_SNMP
  LEGACY_APPLY_OWNERSHIP
  CMAKE_BIN
  BASELINE_ROOT
  ARTIFACT_FAMILY
  OS_VERSION
  GITHUB_ACTIONS
  CI
  GITHUB_WORKSPACE
  GITHUB_REPOSITORY
  GITHUB_SHA
  GITHUB_SERVER_URL
  GITHUB_TOKEN
)

for var_name in "${forward_envs[@]}"; do
  if [[ -v "${var_name}" ]]; then
    docker_args+=(-e "${var_name}=${!var_name}")
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
