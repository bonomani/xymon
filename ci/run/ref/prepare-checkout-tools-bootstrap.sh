#!/usr/bin/env sh
set -eu

prepare_profile="${PREPARE_PROFILE:-default}"
install_script_path="ci/deps/install-checkout-tools.sh"
bootstrap_root="/tmp/ci-deps-bootstrap"

usage() {
  cat <<'USAGE' >&2
Usage: prepare-checkout-tools-bootstrap.sh [--prepare-profile PROFILE]

Ensures checkout/runtime tools are available in Linux container lanes.
When repository scripts are not available yet, bootstraps them from
the workflow commit via the GitHub Contents API.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prepare-profile)
      prepare_profile="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

fetch_repo_file() {
  rel_path="$1"
  dest_path="$2"
  url="https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${rel_path}?ref=${GITHUB_SHA}"

  if command -v curl >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.raw" \
        "${url}" \
        -o "${dest_path}"
    else
      curl -fsSL \
        -H "Accept: application/vnd.github.raw" \
        "${url}" \
        -o "${dest_path}"
    fi
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget -qO "${dest_path}" \
        --header="Authorization: Bearer ${GITHUB_TOKEN}" \
        --header="Accept: application/vnd.github.raw" \
        "${url}"
    else
      wget -qO "${dest_path}" \
        --header="Accept: application/vnd.github.raw" \
        "${url}"
    fi
    return 0
  fi

  return 1
}

if [ ! -f "${install_script_path}" ]; then
  if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "${GITHUB_SHA:-}" ]; then
    echo "GITHUB_REPOSITORY and GITHUB_SHA must be set when bootstrap is required" >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "Need curl or wget to bootstrap checkout-tools installer" >&2
    exit 1
  fi

  rm -rf "${bootstrap_root}"
  mkdir -p "${bootstrap_root}/lib"

  fetch_repo_file "ci/deps/install-checkout-tools.sh" "${bootstrap_root}/install-checkout-tools.sh"
  fetch_repo_file "ci/deps/lib/install-common.sh" "${bootstrap_root}/lib/install-common.sh"

  chmod +x "${bootstrap_root}/install-checkout-tools.sh"
  install_script_path="${bootstrap_root}/install-checkout-tools.sh"
fi

sh "${install_script_path}" --prepare-profile "${prepare_profile}"
