#!/usr/bin/env bash
set -euo pipefail

env_out=""
build_tool=""
ci_compiler="gcc"
profile=""
install_mode="auto"
goal="verify"
verify_depth="install"
ref_mode="off"
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
baseline_prefix=""
candidate_dir=""

profile_ref_suffix() {
  if [[ "$1" == "default" ]]; then
    printf '%s' ""
  else
    printf '.%s' "$1"
  fi
}

profile_artifact_suffix() {
  if [[ "$1" == "default" ]]; then
    printf '%s' ""
  else
    printf -- '-%s' "$1"
  fi
}

default_install_mode() {
  local build="$1"
  local layout="$2"
  if [[ "${build}" == "make" && "${layout}" == "debian" ]]; then
    printf '%s' "package"
  else
    printf '%s' "source"
  fi
}

install_mode_ref_suffix() {
  local build="$1"
  local layout="$2"
  local mode="$3"
  if [[ "${mode}" == "$(default_install_mode "${build}" "${layout}")" ]]; then
    printf '%s' ""
  else
    printf '.%s' "${mode}"
  fi
}

install_mode_artifact_suffix() {
  local build="$1"
  local layout="$2"
  local mode="$3"
  if [[ "${mode}" == "$(default_install_mode "${build}" "${layout}")" ]]; then
    printf '%s' ""
  else
    printf -- '-%s' "${mode}"
  fi
}

usage() {
  cat <<'USAGE' >&2
Usage: run-ref-lane-prepare.sh --env-out PATH [lane args]
  --build make|cmake
  --compiler gcc|clang
  --profile default|debian|gnuinstall|packaging
  --install-mode auto|source|package
  --goal verify|ref
  --verify-depth configure|build|install
  --variant NAME
  [--ref-mode off|generate]
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
  [--baseline-prefix PATH]
  [--candidate-dir DIR]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-out)
      env_out="${2:-}"
      shift 2
      ;;
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
    --install-mode)
      install_mode="${2:-}"
      shift 2
      ;;
    --goal)
      goal="${2:-}"
      shift 2
      ;;
    --verify-depth)
      verify_depth="${2:-}"
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
    --baseline-prefix)
      baseline_prefix="${2:-}"
      shift 2
      ;;
    --candidate-dir)
      candidate_dir="${2:-}"
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

if [[ -z "${env_out}" ]]; then
  echo "Missing --env-out" >&2
  usage
fi
if [[ -z "${build_tool}" ]]; then
  echo "Missing --build" >&2
  usage
fi
case "${ci_compiler}" in
  gcc|clang)
    ;;
  *)
    echo "Unsupported --compiler value: ${ci_compiler}" >&2
    usage
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
# goal/ref_mode/publish consistency is validated upstream by execution_model.py
# before lane execution reaches this script.
if [[ -z "${variant}" ]]; then
  echo "Missing --variant" >&2
  usage
fi

profile="${profile:-default}"
install_mode="${install_mode:-auto}"

case "${build_tool}" in
  make)
    case "${profile}" in
      default|debian)
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
  *)
    echo "Unsupported --build value: ${build_tool}" >&2
    usage
    ;;
esac

case "${install_mode}" in
  auto|"")
    install_mode="$(default_install_mode "${build_tool}" "${profile}")"
    ;;
  source|package)
    ;;
  *)
    echo "Unsupported --install-mode value: ${install_mode}" >&2
    usage
    ;;
esac

if [[ "${build_tool}" == "make" && "${profile}" == "debian" && "${install_mode}" != "package" ]]; then
  echo "make profile=${profile} currently requires --install-mode package" >&2
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

if [[ "${goal}" == "ref" ]]; then
  profile_ref_tag="$(profile_ref_suffix "${profile}")"
  profile_artifact_tag="$(profile_artifact_suffix "${profile}")"
  install_mode_ref_tag="$(install_mode_ref_suffix "${build_tool}" "${profile}" "${install_mode}")"
  install_mode_artifact_tag="$(install_mode_artifact_suffix "${build_tool}" "${profile}" "${install_mode}")"
  baseline_build_tool="${baseline_root%%_*}"
  baseline_runtime_os="${baseline_root#*_}"
  if [[ -z "${baseline_build_tool}" || -z "${baseline_runtime_os}" || "${baseline_runtime_os}" == "${baseline_root}" ]]; then
    echo "Unsupported --baseline-root format: ${baseline_root}" >&2
    usage
  fi
  if [[ -z "${refs_root}" ]]; then
    refs_root=".ci-artifacts/ref-valid-${artifact_family}/refs"
  fi
  if [[ -z "${artifact_root}" ]]; then
    artifact_root=".ci-artifacts/ref-valid-${artifact_family}/${build_tool}${profile_artifact_tag}${install_mode_artifact_tag}-${platform_id}-${variant}"
  fi
  if [[ -z "${legacy_hostname_config}" ]]; then
    legacy_hostname_config="docs/cmake-legacy-migration/refs/ref/${baseline_build_tool}/${baseline_runtime_os}/${platform_id}/server/${artifact_arch}/var/lib/xymon/server/etc/xymonserver.cfg"
  fi
  if [[ -z "${baseline_prefix}" ]]; then
    baseline_prefix="docs/cmake-legacy-migration/refs/ref/${baseline_build_tool}/${baseline_runtime_os}/${platform_id}/${variant}/${artifact_arch}"
  fi
  if [[ -z "${candidate_dir}" ]]; then
    candidate_dir="${refs_root}/${build_tool}${profile_ref_tag}${install_mode_ref_tag}.${ref_os}.${variant}"
  fi
fi

mkdir -p "$(dirname "${env_out}")"
{
  printf 'build_tool=%q\n' "${build_tool}"
  printf 'ci_compiler=%q\n' "${ci_compiler}"
  printf 'profile=%q\n' "${profile}"
  printf 'install_mode=%q\n' "${install_mode}"
  printf 'goal=%q\n' "${goal}"
  printf 'verify_depth=%q\n' "${verify_depth}"
  printf 'ref_mode=%q\n' "${ref_mode}"
  printf 'publish=%q\n' "${publish}"
  printf 'variant=%q\n' "${variant}"
  printf 'baseline_root=%q\n' "${baseline_root}"
  printf 'ref_os=%q\n' "${ref_os}"
  printf 'platform_os=%q\n' "${platform_os}"
  printf 'artifact_family=%q\n' "${artifact_family}"
  printf 'platform_id=%q\n' "${platform_id}"
  printf 'os_version=%q\n' "${os_version}"
  printf 'ref_stage_root=%q\n' "${ref_stage_root}"
  printf 'refs_root=%q\n' "${refs_root}"
  printf 'artifact_root=%q\n' "${artifact_root}"
  printf 'legacy_hostname_config=%q\n' "${legacy_hostname_config}"
  printf 'baseline_prefix=%q\n' "${baseline_prefix}"
  printf 'candidate_dir=%q\n' "${candidate_dir}"
} > "${env_out}"
