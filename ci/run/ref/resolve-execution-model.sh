#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/ref/lib/mode-model.sh
source "${script_dir}/lib/mode-model.sh"

requested_build_tool=""
goal="verify"
ref_mode="generate"
publish="none"
allow_failure_mode_raw="allow"
github_output=""

usage() {
  cat <<'USAGE' >&2
Usage: resolve-execution-model.sh
  --requested-build-tool auto|make|cmake
  [--goal verify|ref]
  [--ref-mode generate|compare]
  [--publish none|artifact]
  [--allow-failure-mode off|allow|expect_fail|true|false|1|0|yes|no]
  [--github-output PATH]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --requested-build-tool)
      requested_build_tool="${2:-}"
      shift 2
      ;;
    --goal)
      goal="${2:-}"
      shift 2
      ;;
    --ref-mode)
      ref_mode="${2:-}"
      shift 2
      ;;
    --publish)
      publish="${2:-}"
      shift 2
      ;;
    --allow-failure-mode)
      allow_failure_mode_raw="${2:-}"
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

if [[ -z "${requested_build_tool}" ]]; then
  echo "Missing --requested-build-tool" >&2
  usage
fi

allow_failure_mode="$(normalize_allow_failure_mode "${allow_failure_mode_raw}")"

validate_goal_ref_publish "${goal}" "${ref_mode}" "${publish}"
validate_allow_failure_mode "${allow_failure_mode}"
validate_requested_build_tool "${requested_build_tool}"

build_tool="$(resolve_build_tool "${requested_build_tool}" "${goal}" "${ref_mode}")"
dep_mode="$(derive_dep_mode "${goal}" "${ref_mode}")"
purpose="$(derive_purpose "${goal}" "${ref_mode}")"

{
  echo "build_tool=${build_tool}"
  echo "goal=${goal}"
  echo "ref_mode=${ref_mode}"
  echo "publish=${publish}"
  echo "allow_failure_mode=${allow_failure_mode}"
  echo "dep_mode=${dep_mode}"
  echo "purpose=${purpose}"
}

if [[ -n "${github_output}" ]]; then
  {
    echo "build_tool=${build_tool}"
    echo "goal=${goal}"
    echo "ref_mode=${ref_mode}"
    echo "publish=${publish}"
    echo "allow_failure_mode=${allow_failure_mode}"
    echo "dep_mode=${dep_mode}"
    echo "purpose=${purpose}"
  } >> "${github_output}"
fi
