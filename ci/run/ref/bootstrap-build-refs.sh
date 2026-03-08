#!/usr/bin/env bash
set -euo pipefail

build_tool=""
ci_compiler="gcc"
profile=""
verify_depth="install"
os_name=""
os_version=""
platform_os="${PLATFORM_OS:-}"
variant=""
ref_prefix=""
refs_root=""
artifact_root=""
CI_DEPS_REPORT_JSON="${CI_DEPS_REPORT_JSON:-}"
DEP_MODE="${DEP_MODE:-}"

usage() {
  cat <<'USAGE' >&2
Usage: bootstrap-build-refs.sh --build TOOL --os NAME --variant NAME --ref-prefix PATH --refs-root DIR --artifact-root DIR [--compiler COMPILER] [--profile PROFILE] [--verify-depth DEPTH] [--version VERSION]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      build_tool="${2:-}"
      shift 2
      ;;
    --compiler)
      ci_compiler="${2:-}"
      shift 2
      ;;
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --verify-depth)
      verify_depth="${2:-}"
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
    --platform-os)
      platform_os="${2:-}"
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

case "${ci_compiler}" in
  gcc|clang)
    ;;
  *)
    echo "Unsupported --compiler value: ${ci_compiler}" >&2
    usage
    ;;
esac

profile="${profile:-default}"

case "${build_tool}" in
  make)
    case "${profile}" in
      default|debian|packaging)
        ;;
      *)
        echo "Unsupported --profile value for make: ${profile}" >&2
        usage
        ;;
    esac
    ;;
  cmake)
    case "${profile}" in
      default|gnuinstall|packaging)
        ;;
      *)
        echo "Unsupported --profile value for cmake: ${profile}" >&2
        usage
        ;;
    esac
    ;;
esac

case "${verify_depth}" in
  configure|build|install)
    ;;
  *)
    echo "Unsupported --verify-depth value: ${verify_depth}" >&2
    usage
    ;;
esac
if [[ "${verify_depth}" != "install" ]]; then
  echo "bootstrap-build-refs requires --verify-depth install (got: ${verify_depth})" >&2
  exit 2
fi

if [[ -z "${os_name}" || -z "${variant}" || -z "${ref_prefix}" || -z "${refs_root}" || -z "${artifact_root}" ]]; then
  usage
fi
if [[ -z "${platform_os}" ]]; then
  platform_os="${os_name}"
fi

# Keep per-build-tool artifact roots to avoid make/cmake collisions.
artifact_root_base="$(basename "${artifact_root}")"
if [[ "${artifact_root_base}" != "${build_tool}-"* ]]; then
  echo "artifact-root basename must start with '${build_tool}-' to avoid path collisions: ${artifact_root}" >&2
  exit 2
fi

mkdir -p "${refs_root}" "${artifact_root}"

if [[ -z "${CI_DEPS_REPORT_JSON}" ]]; then
  CI_DEPS_REPORT_JSON="${artifact_root}/deps-report.json"
fi
mkdir -p "$(dirname "${CI_DEPS_REPORT_JSON}")"
export CI_DEPS_REPORT_JSON
if [[ -n "${DEP_MODE}" ]]; then
  export DEP_MODE
fi

stage_if_present() {
  local src="$1"
  if [[ -f "${src}" ]]; then
    cp -fp "${src}" "${artifact_root}/$(basename "${src}")"
  fi
}

validate_ref_stage_layout() {
  local root="$1"
  local topdir="$2"
  local variant_name="$3"
  local required_rel=()
  local missing=()
  local rel=""

  case "${variant_name}" in
    server)
      required_rel=(
        "server/download"
        "server/bin"
        "server/etc"
        "server/ext"
        "server/tmp"
        "server/web"
        "server/www"
        "client/bin"
        "client/etc"
        "client/ext"
        "client/local"
        "client/logs"
        "client/tmp"
        "data"
        "cgi-bin"
        "cgi-secure"
      )
      ;;
    client)
      required_rel=(
        "bin"
        "etc"
        "ext"
        "logs"
        "tmp"
      )
      ;;
    localclient)
      required_rel=(
        "bin"
        "etc"
        "ext"
        "local"
        "logs"
        "tmp"
      )
      ;;
    *)
      echo "Unsupported variant for ref layout validation: ${variant_name}" >&2
      exit 1
      ;;
  esac

  for rel in "${required_rel[@]}"; do
    if [[ ! -e "${root}/${rel}" ]]; then
      missing+=("${topdir}/${rel}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "Ref generation requires the staged tree to contain all required paths under XYMONTOPDIR=${topdir}; refusing to generate incomplete refs." >&2
  printf 'Missing staged paths:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "This usually means one or more install paths were configured outside XYMONTOPDIR." >&2
  exit 1
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

echo "Running bootstrap-install (${build_tool} / compiler=${ci_compiler} / profile=${profile} / ref_os=${os_name} / platform_os=${platform_os} ${os_version:-unknown} / ${variant})"
bootstrap_args=(
  bash
  ci/bootstrap-install.sh
  --os "${os_name}"
  --platform-os "${platform_os}"
  --variant "${variant}"
  --build "${build_tool}"
  --compiler "${ci_compiler}"
  --profile "${profile}"
  --verify-depth "${verify_depth}"
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

validate_ref_stage_layout "${LEGACY_ROOT}" "${LEGACY_TOPDIR}" "${variant}"

if [[ "${build_tool}" == "cmake" ]]; then
  bash ci/run/ref/validate-config-parity.sh \
    --legacy-config "${ref_prefix}/meta/config.h"
fi

bash ci/generate-refs.sh \
  --os "${os_name}" \
  --variant "${variant}" \
  --build "${build_tool}" \
  --profile "${profile}" \
  --root "${LEGACY_ROOT}" \
  --topdir "${LEGACY_TOPDIR}" \
  --config-h "${XYMON_CONFIG_H:-}" \
  --refs-root "${refs_root}"
