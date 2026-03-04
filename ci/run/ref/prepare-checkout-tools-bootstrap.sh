#!/usr/bin/env sh
set -eu

prepare_profile="${PREPARE_PROFILE:-default}"
checkout_mode="${CHECKOUT_MODE:-action}"
install_script_path="ci/deps/install-checkout-tools.sh"
bootstrap_root="/tmp/ci-deps-bootstrap"

usage() {
  cat <<'USAGE' >&2
Usage: prepare-checkout-tools-bootstrap.sh [--prepare-profile PROFILE] [--checkout-mode MODE]

Ensures checkout/runtime tools are available in Linux container lanes.
When repository scripts are not available yet, bootstraps them from
the workflow commit via the GitHub Contents API.

Modes:
  action  Install checkout/runtime tools only.
  git     Install checkout/runtime tools, then perform a manual git checkout.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prepare-profile)
      prepare_profile="${2:-}"
      shift 2
      ;;
    --checkout-mode)
      checkout_mode="${2:-}"
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

run_as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

apt_get_with_retry() {
  ci_deps_retry_attempt=1
  ci_deps_retry_attempts="${CI_DEPS_RETRY_ATTEMPTS:-3}"
  ci_deps_retry_sleep_secs="${CI_DEPS_RETRY_SLEEP_SECS:-5}"
  ci_deps_apt_acquire_retries="${CI_DEPS_APT_ACQUIRE_RETRIES:-5}"

  while :; do
    if run_as_root env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
      apt-get -o "Acquire::Retries=${ci_deps_apt_acquire_retries}" "$@"; then
      return 0
    else
      rc=$?
    fi
    if [ "${ci_deps_retry_attempt}" -ge "${ci_deps_retry_attempts}" ]; then
      return "${rc}"
    fi
    echo "apt-get $* failed with exit ${rc}; retrying (${ci_deps_retry_attempt}/${ci_deps_retry_attempts}) in ${ci_deps_retry_sleep_secs}s" >&2
    sleep "${ci_deps_retry_sleep_secs}"
    ci_deps_retry_attempt=$((ci_deps_retry_attempt + 1))
  done
}

ensure_fetch_client() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v wget >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt_get_with_retry update
    apt_get_with_retry install -y --no-install-recommends ca-certificates curl wget
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive refresh
    run_as_root zypper --non-interactive install ca-certificates curl wget
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add --no-cache ca-certificates curl wget
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf -y install ca-certificates curl wget
  elif command -v microdnf >/dev/null 2>&1; then
    run_as_root microdnf -y install ca-certificates curl wget
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum -y install ca-certificates curl wget
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --noconfirm archlinux-keyring || true
    run_as_root pacman -S --noconfirm ca-certificates curl wget
  else
    return 1
  fi

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

fetch_repo_file() {
  rel_path="$1"
  dest_path="$2"
  url="https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/${rel_path}?ref=${GITHUB_SHA}"

  ensure_fetch_client || {
    echo "Need curl or wget to bootstrap checkout-tools installer" >&2
    return 1
  }

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
}

git_checkout_fallback() {
  repo_server="${GITHUB_SERVER_URL:-https://github.com}"
  repo_url="${repo_server}/${GITHUB_REPOSITORY}.git"
  workdir="${GITHUB_WORKSPACE:-}"

  if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "${GITHUB_SHA:-}" ]; then
    echo "GITHUB_REPOSITORY and GITHUB_SHA must be set for checkout-mode=git" >&2
    exit 1
  fi
  if [ -z "${workdir}" ]; then
    echo "GITHUB_WORKSPACE is not set" >&2
    exit 1
  fi

  mkdir -p "${workdir}"
  cd "${workdir}"
  git config --global --add safe.directory "${workdir}"
  git config --global --add safe.directory "$(pwd)"
  rm -rf .git
  git init .
  git remote add origin "${repo_url}"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth_header="$(printf 'x-access-token:%s' "${GITHUB_TOKEN}" | base64 | tr -d '\r\n')"
    git config http."${repo_server}/".extraheader "AUTHORIZATION: basic ${auth_header}"
  fi
  git fetch --depth=1 origin "${GITHUB_SHA}"
  git checkout --force FETCH_HEAD
}

if [ ! -f "${install_script_path}" ]; then
  if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "${GITHUB_SHA:-}" ]; then
    echo "GITHUB_REPOSITORY and GITHUB_SHA must be set when bootstrap is required" >&2
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

case "${checkout_mode}" in
  action)
    ;;
  git)
    git_checkout_fallback
    ;;
  *)
    echo "Unsupported checkout mode: ${checkout_mode}" >&2
    usage
    exit 2
    ;;
esac
