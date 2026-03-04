#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOL="${BUILD_TOOL:-make}"
REF_OS="${REF_OS:-}"
PLATFORM_OS="${PLATFORM_OS:-${REF_OS:-}}"
VARIANT="${VARIANT:-}"
OS_VERSION="${OS_VERSION:-}"
REF_STAGE_ROOT="${REF_STAGE_ROOT:-${GITHUB_WORKSPACE:-$(pwd)}/tmp/xymon-refs}"
CI_DEPS_REPORT_JSON="${CI_DEPS_REPORT_JSON:-}"

if [[ -z "${REF_OS}" ]]; then
  echo "REF_OS is required" >&2
  exit 2
fi

if [[ -z "${VARIANT}" ]]; then
  echo "VARIANT is required" >&2
  exit 2
fi

uname -a || true
gcc --version || true
if ! ld -v 2>/dev/null; then
  ld --version || true
fi

mkdir -p "${REF_STAGE_ROOT}"

if [[ -z "${CI_DEPS_REPORT_JSON}" ]]; then
  CI_DEPS_REPORT_JSON="${REF_STAGE_ROOT}/${BUILD_TOOL}.${REF_OS}.${VARIANT}/meta/deps-report.json"
fi
mkdir -p "$(dirname "${CI_DEPS_REPORT_JSON}")"
export CI_DEPS_REPORT_JSON

bootstrap_args=(
  --os "${REF_OS}"
  --platform-os "${PLATFORM_OS}"
  --variant "${VARIANT}"
  --build "${BUILD_TOOL}"
)

if [[ -n "${OS_VERSION}" ]]; then
  bootstrap_args+=(--version "${OS_VERSION}")
fi

bash ci/bootstrap-install.sh "${bootstrap_args[@]}"

if [[ ! -f /tmp/xymon-root-vars.sh ]]; then
  echo "Staged tree metadata missing" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /tmp/xymon-root-vars.sh

bash ci/generate-refs.sh \
  --os "${REF_OS}" \
  --variant "${VARIANT}" \
  --root "${LEGACY_ROOT}" \
  --topdir "${LEGACY_TOPDIR}" \
  --build "${BUILD_TOOL}" \
  --refs-root "${REF_STAGE_ROOT}"
