#!/usr/bin/env bash
set -euo pipefail

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

case "${allow_failure_mode_raw}" in
  false|0|no)
    allow_failure_mode="off"
    ;;
  true|1|yes)
    allow_failure_mode="allow"
    ;;
  *)
    allow_failure_mode="${allow_failure_mode_raw}"
    ;;
esac

case "${goal}" in
  verify|ref)
    ;;
  *)
    echo "Unsupported goal: ${goal}" >&2
    exit 2
    ;;
esac

case "${ref_mode}" in
  generate|compare)
    ;;
  *)
    echo "Unsupported ref_mode: ${ref_mode}" >&2
    exit 2
    ;;
esac

case "${publish}" in
  none|artifact)
    ;;
  *)
    echo "Unsupported publish: ${publish}" >&2
    exit 2
    ;;
esac

case "${allow_failure_mode}" in
  off|allow|expect_fail)
    ;;
  *)
    echo "Unsupported allow_failure_mode: ${allow_failure_mode}" >&2
    exit 2
    ;;
esac

case "${requested_build_tool}" in
  auto|make|cmake)
    ;;
  *)
    echo "Unsupported requested_build_tool: ${requested_build_tool}" >&2
    exit 2
    ;;
esac

if [[ "${goal}" != "ref" && "${ref_mode}" == "compare" ]]; then
  echo "ref_mode=compare is only valid when goal=ref" >&2
  exit 2
fi
if [[ "${goal}" == "verify" && "${ref_mode}" != "generate" ]]; then
  echo "goal=verify requires ref_mode=generate" >&2
  exit 2
fi
if [[ "${goal}" == "verify" && "${publish}" != "none" ]]; then
  echo "goal=verify requires publish=none" >&2
  exit 2
fi

build_tool="${requested_build_tool}"
if [[ "${build_tool}" == "auto" ]]; then
  if [[ "${goal}" == "ref" && "${ref_mode}" == "compare" ]]; then
    build_tool="cmake"
  else
    build_tool="make"
  fi
fi

dep_mode="generate"
purpose="generation"
if [[ "${goal}" == "ref" && "${ref_mode}" == "compare" ]]; then
  dep_mode="compare"
  purpose="validation"
fi

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
