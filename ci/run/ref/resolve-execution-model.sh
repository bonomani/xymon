#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Keep this shell entrypoint for callers that execute the resolver from shell
# contexts (including container bootstrap scripts) and expect a `.sh` command.
exec python3 "${script_dir}/resolve-execution-model.py" "$@"
