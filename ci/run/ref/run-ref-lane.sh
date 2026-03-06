#!/usr/bin/env bash
set -euo pipefail

tmp_env="$(mktemp /tmp/run-ref-lane.XXXXXX)"
cleanup() {
  rm -f "${tmp_env}"
}
trap cleanup EXIT

bash ci/run/ref/run-ref-lane-prepare.sh --env-out "${tmp_env}" "$@"

set -a
# shellcheck disable=SC1090
source "${tmp_env}"
set +a

exec bash ci/run/ref/run-ref-lane-execute.sh

