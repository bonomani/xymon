#!/usr/bin/env bash
set -euo pipefail

build_tool=""
os_name=""
os_version=""
variant=""
ref_prefix=""
refs_root=""
artifact_root=""

usage() {
  cat <<'USAGE' >&2
Usage: bootstrap-build-refs.sh --build TOOL --os NAME --variant NAME --ref-prefix PATH --refs-root DIR --artifact-root DIR [--version VERSION]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      build_tool="${2:-}"
      shift 2
      ;;
    --os)
      os_name="${2:-}"
      shift 2
      ;;
    --version)
      os_version="${2:-}"
      shift 2
      ;;
    --variant)
      variant="${2:-}"
      shift 2
      ;;
    --ref-prefix)
      ref_prefix="${2:-}"
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

if [[ -z "${os_name}" || -z "${variant}" || -z "${ref_prefix}" || -z "${refs_root}" || -z "${artifact_root}" ]]; then
  usage
fi

mkdir -p "${refs_root}" "${artifact_root}"

stage_if_present() {
  local src="$1"
  if [[ -f "${src}" ]]; then
    cp -fp "${src}" "${artifact_root}/$(basename "${src}")"
  fi
}

trap '
  stage_if_present /tmp/legacy.config.extract
  stage_if_present /tmp/cmake.config.extract
  stage_if_present /tmp/config.diff
  stage_if_present /tmp/install-make-legacy.log
  stage_if_present /tmp/make.configure.log
  stage_if_present /tmp/install-cmake-legacy.log
  stage_if_present /tmp/cmake.configure.log
  stage_if_present /tmp/cmake.trace.json
  stage_if_present /tmp/cmake.trace.log
  stage_if_present /tmp/xymon-root-vars.sh
' EXIT

echo "Running bootstrap-install (${build_tool} / ${os_name} ${os_version:-unknown} / ${variant})"
bootstrap_args=(
  bash
  ci/bootstrap-install.sh
  --os "${os_name}"
  --variant "${variant}"
  --build "${build_tool}"
)
if [[ -n "${os_version}" ]]; then
  bootstrap_args+=(--version "${os_version}")
fi
"${bootstrap_args[@]}"

if [[ ! -f /tmp/xymon-root-vars.sh ]]; then
  echo "Staged tree metadata missing" >&2
  exit 1
fi

# shellcheck disable=SC1091
# shellcheck source=/tmp/xymon-root-vars.sh
source /tmp/xymon-root-vars.sh
: "${LEGACY_TOPDIR:?missing LEGACY_TOPDIR}"
: "${LEGACY_ROOT:?missing LEGACY_ROOT}"

if [[ "${build_tool}" == "cmake" ]]; then
  bash ci/run/ref/validate-config-parity.sh \
    --legacy-config "${ref_prefix}/meta/config.h"
fi

bash ci/generate-refs.sh \
  --os "${os_name}" \
  --variant "${variant}" \
  --build "${build_tool}" \
  --root "${LEGACY_ROOT}" \
  --topdir "${LEGACY_TOPDIR}" \
  --config-h "${XYMON_CONFIG_H:-}" \
  --refs-root "${refs_root}"
