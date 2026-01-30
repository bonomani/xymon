#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Wrapper to keep a stable CLI while the checks live in Python.
python3 "${root_dir}/scripts/ci/check-deps.py"
