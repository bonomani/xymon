#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

usage() {
  cat <<'USAGE'
Usage: lint.sh [--changed [BASE_REF]]

Run local CI linters:
  - actionlint for GitHub workflows/actions
  - shellcheck for shell scripts

Options:
  --changed [BASE_REF]  Lint only changed shell scripts against BASE_REF (default: main)
  -h, --help            Show this help text

Environment:
  LINT_ACTIONLINT_WITH_SHELLCHECK=1  Enable actionlint's shellcheck integration
                                      for workflow "run:" blocks.
  LINT_SHELLCHECK_SEVERITY=error|warning|style|info
                                      Set shellcheck severity threshold
                                      (default: error).
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"
cd "${root_dir}"

changed_mode=0
base_ref="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --changed)
      changed_mode=1
      if [[ $# -gt 1 && "${2:0:1}" != "-" ]]; then
        base_ref="$2"
        shift
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_tool() {
  local tool="$1"
  local hint="$2"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    echo "${hint}" >&2
    exit 2
  fi
}

require_tool "actionlint" "Install: https://github.com/rhysd/actionlint#installation"
require_tool "shellcheck" "Install: https://github.com/koalaman/shellcheck#installing"

echo "=== actionlint ==="
if [[ "${LINT_ACTIONLINT_WITH_SHELLCHECK:-0}" == "1" ]]; then
  actionlint
else
  # Keep workflow structure/expression lint strict by default while avoiding
  # blocking on style-only shellcheck findings inside workflow run blocks.
  actionlint -shellcheck=
fi

declare -a shell_files
if (( changed_mode )); then
  if ! git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null; then
    echo "Unknown BASE_REF: ${base_ref}" >&2
    exit 2
  fi
  mapfile -t shell_files < <(git diff --name-only "${base_ref}" -- '*.sh')
  echo "=== shellcheck (changed vs ${base_ref}) ==="
else
  mapfile -t shell_files < <(git ls-files '*.sh')
  echo "=== shellcheck (all tracked .sh) ==="
fi

if [[ ${#shell_files[@]} -eq 0 ]]; then
  echo "No shell scripts to lint."
  exit 0
fi

shellcheck_severity="${LINT_SHELLCHECK_SEVERITY:-error}"
shellcheck -x -S "${shellcheck_severity}" "${shell_files[@]}"
