#!/usr/bin/env bash
set -euo pipefail

build_tool="${build_tool:-}"
ci_compiler="${ci_compiler:-}"
profile="${profile:-}"
install_mode="${install_mode:-}"
goal="${goal:-}"
verify_depth="${verify_depth:-}"
ref_mode="${ref_mode:-}"
publish="${publish:-}"
variant="${variant:-}"
baseline_root="${baseline_root:-}"
ref_os="${ref_os:-}"
platform_os="${platform_os:-}"
artifact_family="${artifact_family:-}"
platform_id="${platform_id:-}"
os_version="${os_version:-}"
refs_root="${refs_root:-}"
artifact_root="${artifact_root:-}"
legacy_hostname_config="${legacy_hostname_config:-}"
baseline_prefix="${baseline_prefix:-}"
candidate_dir="${candidate_dir:-}"

if [[ -z "${build_tool}" ]]; then
  echo "Missing prepared variable: build_tool" >&2
  exit 2
fi
if [[ -z "${goal}" ]]; then
  echo "Missing prepared variable: goal" >&2
  exit 2
fi
if [[ -z "${verify_depth}" ]]; then
  echo "Missing prepared variable: verify_depth" >&2
  exit 2
fi
if [[ -z "${ci_compiler}" ]]; then
  echo "Missing prepared variable: ci_compiler" >&2
  exit 2
fi
if [[ -z "${profile}" ]]; then
  echo "Missing prepared variable: profile" >&2
  exit 2
fi
if [[ -z "${install_mode}" ]]; then
  echo "Missing prepared variable: install_mode" >&2
  exit 2
fi
if [[ -z "${variant}" ]]; then
  echo "Missing prepared variable: variant" >&2
  exit 2
fi
if [[ -z "${ref_os}" ]]; then
  echo "Missing prepared variable: ref_os" >&2
  exit 2
fi
if [[ -z "${platform_os}" ]]; then
  echo "Missing prepared variable: platform_os" >&2
  exit 2
fi
if [[ -z "${platform_id}" ]]; then
  echo "Missing prepared variable: platform_id" >&2
  exit 2
fi

if [[ "${goal}" == "ref" ]]; then
  for var_name in \
    baseline_root artifact_family refs_root artifact_root \
    baseline_prefix candidate_dir legacy_hostname_config; do
    if [[ -z "${!var_name:-}" ]]; then
      echo "Missing prepared variable for goal=ref: ${var_name}" >&2
      exit 2
    fi
  done
fi

if [[ -z "${CI_DEPS_REPORT_JSON:-}" ]]; then
  echo "Missing CI_DEPS_REPORT_JSON" >&2
  exit 2
fi
mkdir -p "$(dirname "${CI_DEPS_REPORT_JSON}")"

case "${ci_compiler}" in
  gcc|clang)
    ;;
  *)
    echo "Unsupported prepared compiler value: ${ci_compiler}" >&2
    exit 2
    ;;
esac

case "${build_tool}" in
  make)
    case "${profile}" in
      default|debian|packaging)
        ;;
      *)
        echo "Unsupported prepared profile value for make: ${profile}" >&2
        exit 2
        ;;
    esac
    ;;
  cmake)
    case "${profile}" in
      default|gnuinstall|packaging)
        ;;
      *)
        echo "Unsupported prepared profile value for cmake: ${profile}" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "Unsupported prepared build_tool value: ${build_tool}" >&2
    exit 2
    ;;
esac

case "${install_mode}" in
  source|package)
    ;;
  *)
    echo "Unsupported prepared install_mode value: ${install_mode}" >&2
    exit 2
    ;;
esac

case "${verify_depth}" in
  configure|build|install)
    ;;
  *)
    echo "Unsupported prepared verify_depth value: ${verify_depth}" >&2
    exit 2
    ;;
esac
if [[ "${goal}" == "ref" ]]; then
  verify_depth="install"
fi

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
    --compiler "${ci_compiler}"
    --profile "${profile}"
    --install-mode "${install_mode}"
    --verify-depth "${verify_depth}"
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
    --compiler "${ci_compiler}"
    --profile "${profile}"
    --install-mode "${install_mode}"
    --verify-depth "${verify_depth}"
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

echo "=== Lane execution ==="
echo "ref_mode=${ref_mode} (goal=${goal}) verify_depth=${verify_depth} publish=${publish}"
echo "build=${build_tool} compiler=${ci_compiler} profile=${profile} install_mode=${install_mode} ref_os=${ref_os} platform_os=${platform_os} variant=${variant}"

case "${goal}" in
  verify)
    run_core_build_install
    ;;
  ref)
    if [[ "${ref_mode}" != "generate" ]]; then
      echo "Unsupported ref_mode for goal=ref in lane runtime: ${ref_mode}" >&2
      exit 2
    fi
    run_ref_snapshot
    ;;
  *)
    echo "Unsupported goal value: ${goal}" >&2
    exit 2
    ;;
esac
