#!/usr/bin/env bash
set -euo pipefail

exec bash ci/run/ref/bootstrap-build-refs.sh --build cmake "$@"
