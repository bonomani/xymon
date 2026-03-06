#!/usr/bin/env bash
set -euo pipefail

build_tool=""
goal="verify"
ref_mode="generate"
publish="none"
variant=""
baseline_root=""
ref_os="linux"
platform_os=""
artifact_family=""
platform_id=""
os_version=""

ref_stage_root="${REF_STAGE_ROOT:-${GITHUB_WORKSPACE:-$(pwd)}/tmp/xymon-refs}"
refs_root=""
artifact_root=""
legacy_hostname_config=""

validate_lane_build_tool() {
  local value="${1:-}"
  case "${value}" in
    make|cmake)
      return 0
      ;;
    *)
      echo "Unsupported lane build_tool: ${value}" >&2
      return 2
      ;;
  esac
}

validate_goal_ref_publish() {
  local lane_goal="${1:-}"
  local lane_ref_mode="${2:-}"
  local lane_publish="${3:-}"

  case "${lane_goal}" in
    verify|ref)
      ;;
    *)
      echo "Unsupported goal: ${lane_goal}" >&2
      return 2
      ;;
  esac

  case "${lane_ref_mode}" in
    generate|compare)
      ;;
    *)
      echo "Unsupported ref_mode: ${lane_ref_mode}" >&2
      return 2
      ;;
  esac

  case "${lane_publish}" in
    none|artifact)
      ;;
    *)
      echo "Unsupported publish: ${lane_publish}" >&2
      return 2
      ;;
  esac

  if [[ "${lane_goal}" != "ref" && "${lane_ref_mode}" == "compare" ]]; then
    echo "ref_mode=compare is only valid when goal=ref" >&2
    return 2
  fi
  if [[ "${lane_goal}" == "verify" && "${lane_ref_mode}" != "generate" ]]; then
    echo "goal=verify requires ref_mode=generate" >&2
    return 2
  fi
  if [[ "${lane_goal}" == "verify" && "${lane_publish}" != "none" ]]; then
    echo "goal=verify requires publish=none" >&2
    return 2
  fi

  return 0
}

derive_dep_mode() {
  local lane_goal="${1:-}"
  local lane_ref_mode="${2:-}"
  if [[ "${lane_goal}" == "ref" && "${lane_ref_mode}" == "compare" ]]; then
    printf 'compare\n'
  else
    printf 'generate\n'
  fi
}

usage() {
  cat <<'USAGE' >&2
Usage: run-ref-lane.sh
  --build make|cmake
  --goal verify|ref
  --variant NAME
  [--ref-mode generate|compare]
  [--publish none|artifact]
  [--baseline-root ROOT]
  [--ref-os OS]
  [--platform-os OS]
  [--artifact-family FAMILY]
  [--platform-id ID]
  [--version VERSION]
  [--refs-root DIR]
  [--artifact-root DIR]
  [--legacy-hostname-config PATH]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      build_tool="${2:-}"
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
    --variant)
      variant="${2:-}"
      shift 2
      ;;
    --baseline-root)
      baseline_root="${2:-}"
      shift 2
      ;;
    --ref-os)
      ref_os="${2:-}"
      shift 2
      ;;
    --platform-os)
      platform_os="${2:-}"
      shift 2
      ;;
    --artifact-family)
      artifact_family="${2:-}"
      shift 2
      ;;
    --platform-id)
      platform_id="${2:-}"
      shift 2
      ;;
    --version)
      os_version="${2:-}"
      shift 2
      ;;
    --refs-root)
      refs_root="${2:-}"
      shift 2
      ;;
    --artifact-root)
      artifact_root="${2:-}"
      shift 2
      ;;
    --legacy-hostname-config)
      legacy_hostname_config="${2:-}"
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

if [[ -z "${build_tool}" ]]; then
  echo "Missing --build" >&2
  usage
fi
if ! validate_lane_build_tool "${build_tool}"; then
  usage
fi
if ! validate_goal_ref_publish "${goal}" "${ref_mode}" "${publish}"; then
  usage
fi
dep_mode="$(derive_dep_mode "${goal}" "${ref_mode}")"

if [[ -z "${variant}" ]]; then
  echo "Missing --variant" >&2
  usage
fi

if [[ -z "${platform_os}" ]]; then
  platform_os="${ref_os}"
fi
if [[ -z "${platform_id}" ]]; then
  platform_id="${platform_os}"
fi

if [[ "${goal}" == "ref" ]]; then
  if [[ -z "${baseline_root}" ]]; then
    echo "Missing --baseline-root" >&2
    usage
  fi
  if [[ -z "${artifact_family}" ]]; then
    echo "Missing --artifact-family" >&2
    usage
  fi
fi

baseline_prefix=""
candidate_dir=""
if [[ "${goal}" == "ref" ]]; then
  if [[ -z "${refs_root}" ]]; then
    refs_root=".ci-artifacts/ref-valid-${artifact_family}/refs"
  fi
  if [[ -z "${artifact_root}" ]]; then
    artifact_root=".ci-artifacts/ref-valid-${artifact_family}/${build_tool}-${platform_id}-${variant}"
  fi
  if [[ -z "${legacy_hostname_config}" ]]; then
    legacy_hostname_config="docs/cmake-legacy-migration/refs/${baseline_root}/server/var/lib/xymon/server/etc/xymonserver.cfg"
  fi
  baseline_prefix="docs/cmake-legacy-migration/refs/${baseline_root}/${variant}"
  candidate_dir="${refs_root}/${build_tool}.${ref_os}.${variant}"
fi

report_mode="${dep_mode}"
export CI_DEPS_REPORT_MODE="${CI_DEPS_REPORT_MODE:-${report_mode}}"

if [[ -z "${CI_DEPS_REPORT_JSON:-}" ]]; then
  if [[ "${report_mode}" == "compare" ]]; then
    export CI_DEPS_REPORT_JSON="${artifact_root}/deps-report.json"
  else
    export CI_DEPS_REPORT_JSON="${ref_stage_root}/${build_tool}.${ref_os}.${variant}/meta/deps-report.json"
  fi
fi
mkdir -p "$(dirname "${CI_DEPS_REPORT_JSON}")"

load_legacy_hostname_in_process() {
  local env_file=""
  env_file="$(mktemp /tmp/xymon-legacy-hostname.XXXXXX)"

  bash ci/run/ref/load-legacy-hostname.sh \
    --config "${legacy_hostname_config}" \
    --env-file "${env_file}"

  if [[ -s "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
    if [[ -n "${XYMONHOSTNAME:-}" ]]; then
      export XYMONHOSTNAME
      echo "Using legacy hostname in-process: ${XYMONHOSTNAME}"
    fi
  else
    echo "Legacy hostname: no in-process override loaded."
  fi

  rm -f "${env_file}"
}

run_core_build_install() {
  local args=(
    bash
    ci/bootstrap-install.sh
    --os "${ref_os}"
    --platform-os "${platform_os}"
    --variant "${variant}"
    --build "${build_tool}"
  )
  if [[ -n "${os_version}" ]]; then
    args+=(--version "${os_version}")
  fi
  "${args[@]}"
}

run_ref_snapshot() {
  local args=(
    bash
    ci/run/ref/bootstrap-build-refs.sh
    --build "${build_tool}"
    --os "${ref_os}"
    --platform-os "${platform_os}"
    --variant "${variant}"
    --ref-prefix "${baseline_prefix}"
    --refs-root "${refs_root}"
    --artifact-root "${artifact_root}"
  )
  if [[ -n "${os_version}" ]]; then
    args+=(--version "${os_version}")
  fi
  "${args[@]}"
}

run_ref_compare() {
  # shellcheck disable=SC1091
  # shellcheck source=ci/run/ref/load-staged-metadata.sh
  source ci/run/ref/load-staged-metadata.sh

  bash ci/compare-refs.sh \
    --baseline-prefix "${baseline_prefix}" \
    --candidate-dir "${candidate_dir}" \
    --candidate-root "${LEGACY_ROOT}"
}

echo "=== Lane execution ==="
echo "goal=${goal} ref_mode=${ref_mode} publish=${publish}"
echo "build=${build_tool} ref_os=${ref_os} platform_os=${platform_os} variant=${variant}"

case "${goal}" in
  verify)
    run_core_build_install
    ;;
  ref)
    if [[ "${ref_mode}" == "compare" ]]; then
      load_legacy_hostname_in_process
      bash ci/run/ref/seed-legacy-identities.sh \
        --passwd "docs/cmake-legacy-migration/refs/${baseline_root}/${variant}/owners.passwd" \
        --group "docs/cmake-legacy-migration/refs/${baseline_root}/${variant}/owners.group"
    fi
    run_ref_snapshot
    if [[ "${ref_mode}" == "compare" ]]; then
      run_ref_compare
    fi
    ;;
esac
