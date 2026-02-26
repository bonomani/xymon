#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-dnf-packages.sh [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. rpm)
  --os NAME       OS key (e.g. rockylinux, fedora)
  --version NAME  Optional version key (e.g. 9, 40)
USAGE
}

ci_deps_init_linux_installer dnf "$@"

DNF_REPO_ARGS=()

configure_rocky_fallback_repos() {
  [[ "${os_name}" == "rockylinux" ]] || return 0

  local rocky_major="${version}"
  local rocky_gpgkey=""
  local repo_file="/tmp/ci-rocky-fallback.repo.$$"

  if [[ -z "${rocky_major}" || "${rocky_major}" == "latest" ]]; then
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      rocky_major="${VERSION_ID%%.*}"
    fi
  fi
  [[ -n "${rocky_major}" ]] || rocky_major="8"

  rocky_gpgkey="/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${rocky_major}"
  if [[ ! -r "${rocky_gpgkey}" ]]; then
    rocky_gpgkey="/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial"
  fi
  if [[ ! -r "${rocky_gpgkey}" ]]; then
    rocky_gpgkey="$(ls /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-* 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "${rocky_gpgkey}" || ! -r "${rocky_gpgkey}" ]]; then
    echo "Unable to locate Rocky Linux RPM GPG key in /etc/pki/rpm-gpg" >&2
    return 1
  fi

  {
    printf '%s\n' '[ci-rocky-baseos]'
    printf '%s\n' 'name=CI Rocky BaseOS fallback mirrors'
    printf '%s\n' "baseurl=https://mirror.rackspace.com/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' "        https://mirror.math.princeton.edu/pub/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' "        https://mirrors.sonic.net/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' "        https://ftp.iij.ad.jp/pub/linux/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' 'enabled=1'
    printf '%s\n' 'gpgcheck=1'
    printf '%s\n' "gpgkey=file://${rocky_gpgkey}"
    printf '%s\n' 'skip_if_unavailable=1'
    printf '\n'

    printf '%s\n' '[ci-rocky-appstream]'
    printf '%s\n' 'name=CI Rocky AppStream fallback mirrors'
    printf '%s\n' "baseurl=https://mirror.rackspace.com/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' "        https://mirror.math.princeton.edu/pub/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' "        https://mirrors.sonic.net/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' "        https://ftp.iij.ad.jp/pub/linux/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' 'enabled=1'
    printf '%s\n' 'gpgcheck=1'
    printf '%s\n' "gpgkey=file://${rocky_gpgkey}"
    printf '%s\n' 'skip_if_unavailable=1'
    printf '\n'

    printf '%s\n' '[ci-rocky-extras]'
    printf '%s\n' 'name=CI Rocky Extras fallback mirrors'
    printf '%s\n' "baseurl=https://mirror.rackspace.com/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' "        https://mirror.math.princeton.edu/pub/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' "        https://mirrors.sonic.net/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' "        https://ftp.iij.ad.jp/pub/linux/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' 'enabled=1'
    printf '%s\n' 'gpgcheck=1'
    printf '%s\n' "gpgkey=file://${rocky_gpgkey}"
    printf '%s\n' 'skip_if_unavailable=1'
  } > "${repo_file}"
  ci_deps_as_root install -m 0644 "${repo_file}" /etc/yum.repos.d/ci-rocky-fallback.repo
  rm -f "${repo_file}"

  DNF_REPO_ARGS=(
    --disablerepo=baseos
    --disablerepo=appstream
    --disablerepo=extras
    --enablerepo=ci-rocky-baseos
    --enablerepo=ci-rocky-appstream
    --enablerepo=ci-rocky-extras
  )
}

dnf_run() {
  ci_deps_as_root dnf "${DNF_REPO_ARGS[@]}" "$@"
}

dnf_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

dnf_pkg_available() {
  dnf -q "${DNF_REPO_ARGS[@]}" list --available "$1" >/dev/null 2>&1
}

dnf_install_one() {
  dnf_run -y install "$1"
}

dnf_pre_install() {
  echo "=== Install (Linux packages) ==="

  configure_rocky_fallback_repos
  dnf_run -y install dnf-plugins-core
  if [[ "${os_name}" == "rockylinux" || "${os_name}" == "almalinux" ]]; then
    if [[ "${version}" == "8" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled powertools || true
    elif [[ "${version}" == "9" ]]; then
      ci_deps_as_root dnf config-manager --set-enabled crb || true
    fi
  fi
  dnf_run -y install epel-release || true
  dnf_run clean all
  dnf_run -y makecache
}

ci_deps_run_installer_modes \
  dnf_pkg_installed dnf_pkg_available dnf_install_one dnf_pre_install
