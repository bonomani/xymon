#!/usr/bin/env bash
set -euo pipefail

exec bash ci/bootstrap-install-and-refs.sh "$@"
