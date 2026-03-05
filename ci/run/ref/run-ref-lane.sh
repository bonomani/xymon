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

usage() {
  cat <<'USAGE' >&2
Usage: run-ref-lane.sh
  --build TOOL
  --goal verify|ref|package|image
  --variant NAME
  [--ref-mode generate|compare]
  [--publish none|artifact|registry]
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

case "${build_tool}" in
  make|cmake)
    ;;
  *)
    echo "Unsupported --build value: ${build_tool}" >&2
    usage
    ;;
esac

case "${goal}" in
  verify|ref|package|image)
    ;;
  *)
    echo "Unsupported --goal value: ${goal}" >&2
    usage
    ;;
esac

case "${ref_mode}" in
  generate|compare)
    ;;
  *)
    echo "Unsupported --ref-mode value: ${ref_mode}" >&2
    usage
    ;;
esac

case "${publish}" in
  none|artifact|registry)
    ;;
  *)
    echo "Unsupported --publish value: ${publish}" >&2
    usage
    ;;
esac

if [[ -z "${variant}" ]]; then
  echo "Missing --variant" >&2
  usage
fi

if [[ -z "${platform_os}" ]]; then
  platform_os="${ref_os}"
fi
if [[ -z "${artifact_family}" ]]; then
  artifact_family="${ref_os}"
fi
if [[ -z "${platform_id}" ]]; then
  platform_id="${platform_os}"
fi

if [[ -z "${baseline_root}" ]]; then
  baseline_root="make_${ref_os}"
fi

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

report_mode="generate"
if [[ "${goal}" == "ref" && "${ref_mode}" == "compare" ]]; then
  report_mode="compare"
fi
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
  package)
    run_core_build_install
    echo "Package goal selected: core build/install completed. Packaging pipeline not implemented yet."
    ;;
  image)
    run_core_build_install
    echo "Image goal selected: core build/install completed. Container image pipeline not implemented yet."
    ;;
esac

if [[ "${publish}" == "registry" ]]; then
  echo "publish=registry selected: registry publication not implemented yet."
fi
