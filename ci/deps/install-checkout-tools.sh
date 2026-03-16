#!/usr/bin/env sh
set -eu

prepare_profile="${PREPARE_PROFILE:-default}"
checkout_mode="${CHECKOUT_MODE:-action}"

usage() {
  cat <<'USAGE' >&2
Usage: install-checkout-tools.sh [--prepare-profile PROFILE] [--checkout-mode MODE]

Installs basic checkout/runtime tools used by ref-validation Linux containers:
tar bash gawk ca-certificates (+ git when checkout-mode=git).
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

case "${checkout_mode}" in
  action|git)
    ;;
  *)
    echo "Unsupported checkout mode: ${checkout_mode}" >&2
    exit 2
    ;;
esac

need_install=0
command -v tar >/dev/null 2>&1 || need_install=1
command -v bash >/dev/null 2>&1 || need_install=1
command -v awk >/dev/null 2>&1 || need_install=1
command -v update-ca-certificates >/dev/null 2>&1 || need_install=1
[ "${checkout_mode}" != "git" ] || command -v git >/dev/null 2>&1 || need_install=1
[ "${need_install}" -eq 1 ] || exit 0

run_bootstrap_as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

apt_bootstrap_with_retry() {
  ci_deps_retry_attempt=1
  ci_deps_retry_attempts="${CI_DEPS_RETRY_ATTEMPTS:-3}"
  ci_deps_retry_sleep_secs="${CI_DEPS_RETRY_SLEEP_SECS:-5}"
  ci_deps_apt_acquire_retries="${CI_DEPS_APT_ACQUIRE_RETRIES:-5}"

  while :; do
    if run_bootstrap_as_root env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
      apt-get -o "Acquire::Retries=${ci_deps_apt_acquire_retries}" "$@"; then
      return 0
    else
      ci_deps_rc=$?
    fi
    if [ "${ci_deps_retry_attempt}" -ge "${ci_deps_retry_attempts}" ]; then
      return "${ci_deps_rc}"
    fi
    echo "apt-get $* failed with exit ${ci_deps_rc}; retrying (${ci_deps_retry_attempt}/${ci_deps_retry_attempts}) in ${ci_deps_retry_sleep_secs}s" >&2
    sleep "${ci_deps_retry_sleep_secs}"
    ci_deps_retry_attempt=$((ci_deps_retry_attempt + 1))
  done
}

# install-common.sh is Bash-only. Re-exec once under Bash after bootstrapping
# it, even when /bin/sh is actually Bash running in POSIX mode.
if [ "${CI_DEPS_REEXECED_WITH_BASH:-0}" != "1" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt_bootstrap_with_retry update
      apt_bootstrap_with_retry install -y --no-install-recommends bash
    elif command -v zypper >/dev/null 2>&1; then
      run_bootstrap_as_root zypper --non-interactive refresh
      run_bootstrap_as_root zypper --non-interactive install bash
    elif command -v apk >/dev/null 2>&1; then
      run_bootstrap_as_root apk add --no-cache bash
    elif command -v dnf >/dev/null 2>&1; then
      run_bootstrap_as_root dnf -y install bash
    elif command -v microdnf >/dev/null 2>&1; then
      run_bootstrap_as_root microdnf -y install bash dnf
    elif command -v yum >/dev/null 2>&1; then
      run_bootstrap_as_root yum -y install bash
    elif command -v pacman >/dev/null 2>&1; then
      run_bootstrap_as_root pacman -Sy --noconfirm archlinux-keyring || true
      run_bootstrap_as_root pacman -S --noconfirm bash
    else
      echo "Unsupported package manager for installing checkout tools" >&2
      exit 2
    fi
  fi
  exec env CI_DEPS_REEXECED_WITH_BASH=1 bash "$0" \
    --prepare-profile "${prepare_profile}" \
    --checkout-mode "${checkout_mode}"
fi

set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

need_install=0
command -v tar >/dev/null 2>&1 || need_install=1
command -v bash >/dev/null 2>&1 || need_install=1
command -v awk >/dev/null 2>&1 || need_install=1
command -v update-ca-certificates >/dev/null 2>&1 || need_install=1
[ "${checkout_mode}" != "git" ] || command -v git >/dev/null 2>&1 || need_install=1
[[ "${need_install}" -eq 1 ]] || exit 0

install_pkgs=(tar bash gawk ca-certificates)
if [[ "${checkout_mode}" == "git" ]]; then
  install_pkgs+=(git)
fi

if command -v apt-get >/dev/null 2>&1; then
  ci_deps_apt_get update
  ci_deps_apt_get install -y --no-install-recommends "${install_pkgs[@]}"
elif command -v zypper >/dev/null 2>&1; then
  ci_deps_as_root zypper --non-interactive refresh
  ci_deps_as_root zypper --non-interactive install "${install_pkgs[@]}"
elif command -v apk >/dev/null 2>&1; then
  ci_deps_as_root apk add --no-cache "${install_pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf_repo_args=()
  if [[ "${prepare_profile}" == "redhat" ]] && ci_deps_configure_rocky_fallback_repos ""; then
    ci_deps_parse_os_release || true
    if [[ "${CI_DEPS_OS_ID:-}" == "rocky" ]]; then
      dnf_repo_args=(
        --disablerepo=baseos
        --disablerepo=appstream
        --disablerepo=extras
        --enablerepo=ci-rocky-baseos
        --enablerepo=ci-rocky-appstream
        --enablerepo=ci-rocky-extras
      )
    fi
  fi
    if ((${#dnf_repo_args[@]})); then
      ci_deps_as_root dnf -y "${dnf_repo_args[@]}" install "${install_pkgs[@]}"
    else
      ci_deps_as_root dnf -y install "${install_pkgs[@]}"
    fi
elif command -v microdnf >/dev/null 2>&1; then
  ci_deps_as_root microdnf -y install dnf "${install_pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum_repo_args=()
  if [[ "${prepare_profile}" == "centos7" ]]; then
    ci_deps_install_centos7_vault_repo
    yum_repo_args=(
      --disablerepo=*
      --enablerepo=centos7-vault-base
      --enablerepo=centos7-vault-updates
      --enablerepo=centos7-vault-extras
    )
  elif [[ "${prepare_profile}" == "redhat" ]] && ci_deps_configure_rocky_fallback_repos ""; then
    ci_deps_parse_os_release || true
    if [[ "${CI_DEPS_OS_ID:-}" == "rocky" ]]; then
      yum_repo_args=(
        --disablerepo=baseos
        --disablerepo=appstream
        --disablerepo=extras
        --enablerepo=ci-rocky-baseos
        --enablerepo=ci-rocky-appstream
        --enablerepo=ci-rocky-extras
      )
    fi
  fi
    if ((${#yum_repo_args[@]})); then
      ci_deps_as_root yum -y "${yum_repo_args[@]}" install "${install_pkgs[@]}"
    else
      ci_deps_as_root yum -y install "${install_pkgs[@]}"
    fi
elif command -v pacman >/dev/null 2>&1; then
  pacman_pkgs=(tar bash gawk ca-certificates)
  if [[ "${checkout_mode}" == "git" ]]; then
    pacman_pkgs+=(git)
  fi
  ci_deps_as_root pacman -Sy --noconfirm archlinux-keyring || true
  ci_deps_as_root pacman -S --noconfirm "${pacman_pkgs[@]}"
else
  echo "Unsupported package manager for installing checkout tools" >&2
  exit 2
fi
