#!/usr/bin/env sh
set -eu

prepare_profile="${PREPARE_PROFILE:-default}"

usage() {
  cat <<'USAGE' >&2
Usage: install-checkout-tools.sh [--prepare-profile PROFILE]

Installs basic checkout/runtime tools used by ref-validation Linux containers:
tar git bash gawk ca-certificates.
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

need_install=0
command -v tar >/dev/null 2>&1 || need_install=1
command -v git >/dev/null 2>&1 || need_install=1
command -v bash >/dev/null 2>&1 || need_install=1
command -v awk >/dev/null 2>&1 || need_install=1
command -v update-ca-certificates >/dev/null 2>&1 || need_install=1
[ "${need_install}" -eq 1 ] || exit 0

# install-common.sh is Bash-only. Re-exec once under Bash after bootstrapping
# it, even when /bin/sh is actually Bash running in POSIX mode.
if [ "${CI_DEPS_REEXECED_WITH_BASH:-0}" != "1" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y --no-install-recommends bash
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive refresh
      zypper --non-interactive install bash
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache bash
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install bash
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf -y install bash dnf
    elif command -v yum >/dev/null 2>&1; then
      yum -y install bash
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm archlinux-keyring || true
      pacman -S --noconfirm bash
    else
      echo "Unsupported package manager for installing checkout tools" >&2
      exit 2
    fi
  fi
  exec env CI_DEPS_REEXECED_WITH_BASH=1 bash "$0" --prepare-profile "${prepare_profile}"
fi

set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

need_install=0
command -v tar >/dev/null 2>&1 || need_install=1
command -v git >/dev/null 2>&1 || need_install=1
command -v bash >/dev/null 2>&1 || need_install=1
command -v awk >/dev/null 2>&1 || need_install=1
command -v update-ca-certificates >/dev/null 2>&1 || need_install=1
[[ "${need_install}" -eq 1 ]] || exit 0

if command -v apt-get >/dev/null 2>&1; then
  ci_deps_as_root apt-get update
  ci_deps_as_root env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    apt-get install -y --no-install-recommends tar git bash gawk ca-certificates
elif command -v zypper >/dev/null 2>&1; then
  ci_deps_as_root zypper --non-interactive refresh
  ci_deps_as_root zypper --non-interactive install tar git bash gawk ca-certificates
elif command -v apk >/dev/null 2>&1; then
  ci_deps_as_root apk add --no-cache tar git bash gawk ca-certificates
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
  ci_deps_as_root dnf -y "${dnf_repo_args[@]}" install tar git bash gawk ca-certificates
elif command -v microdnf >/dev/null 2>&1; then
  ci_deps_as_root microdnf -y install dnf tar git bash gawk ca-certificates
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
  ci_deps_as_root yum -y "${yum_repo_args[@]}" install tar git bash gawk ca-certificates
elif command -v pacman >/dev/null 2>&1; then
  ci_deps_as_root pacman -Sy --noconfirm archlinux-keyring || true
  ci_deps_as_root pacman -S --noconfirm tar git bash gawk ca-certificates
else
  echo "Unsupported package manager for installing checkout tools" >&2
  exit 2
fi
