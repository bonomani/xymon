#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-packages.sh --pkgmgr NAME [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --pkgmgr NAME  Package manager key used for installation helpers
  --print        Print package list and exit
  --check-only   Exit 0 if all packages are installed, 1 otherwise
  --install      Install packages (default)
  --family NAME  Dependency family (e.g. rpm, ubuntu)
  --os NAME      OS key (e.g. centos, ubuntu)
  --version NAME Optional version key (e.g. 7, latest)
  --build-tool   Resolve build-specific deps (make|cmake)
USAGE
  exit 2
}

pkgmgr=""
remaining_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkgmgr)
      pkgmgr="$2"
      shift 2
      ;;
    --pkgmgr=*)
      pkgmgr="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      remaining_args+=("$1")
      shift
      ;;
  esac
done

if [[ -z "${pkgmgr}" ]]; then
  echo "Missing required --pkgmgr flag" >&2
  usage
fi

pkgmgr="$(printf '%s' "${pkgmgr}" | tr '[:upper:]' '[:lower:]')"

if ! ci_deps_init_linux_installer "${pkgmgr}" "${remaining_args[@]}"; then
  exit $?
fi

case "${pkgmgr}" in
  apt)
    apt_pkg_installed() {
      dpkg -s "$1" >/dev/null 2>&1
    }

    apt_pkg_available() {
      local candidate=""
      candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')"
      [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
    }

    apt_install_one() {
      ci_deps_apt_get install -y --no-install-recommends "$1"
    }

    apt_pre_install() {
      echo "=== Install (Linux packages) ==="
      ci_deps_apt_get update
    }

    ci_deps_run_installer_modes \
      apt_pkg_installed apt_pkg_available apt_install_one apt_pre_install
    ;;
  dnf)
    DNF_REPO_ARGS=()

    configure_rocky_fallback_repos() {
      [[ "${os_name}" == "rockylinux" ]] || return 0
      ci_deps_configure_rocky_fallback_repos "${os_name}" "${version}" || return 1

      DNF_REPO_ARGS=(
        --disablerepo=baseos
        --disablerepo=appstream
        --disablerepo=extras
        --enablerepo=ci-rocky-baseos
        --enablerepo=ci-rocky-appstream
        --enablerepo=ci-rocky-extras
      )
    }

    configure_enterprise_builder_repos() {
      if [[ "${os_name}" == "rockylinux" || "${os_name}" == "almalinux" ]]; then
        if [[ "${version}" == "8" ]]; then
          ci_deps_as_root dnf config-manager --set-enabled powertools || true
        elif [[ "${version}" == "9" ]]; then
          ci_deps_as_root dnf config-manager --set-enabled crb || true
        fi
        return 0
      fi

      if [[ "${os_name}" == "oraclelinux" && -n "${version}" ]]; then
        ci_deps_as_root dnf config-manager --set-enabled "ol${version}_codeready_builder" || true
      fi
    }

    install_optional_epel_release() {
      local epel_package="epel-release"

      if [[ "${os_name}" == "oraclelinux" && -n "${version}" ]]; then
        epel_package="oracle-epel-release-el${version}"
      fi

      dnf_run -y install "${epel_package}" || true
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
      configure_enterprise_builder_repos
      install_optional_epel_release
      dnf_run clean all
      dnf_run -y makecache
    }

    ci_deps_run_installer_modes \
      dnf_pkg_installed dnf_pkg_available dnf_install_one dnf_pre_install
    ;;
  yum)
    YUM_OPTS=()

    yum_pkg_installed() {
      rpm -q "$1" >/dev/null 2>&1
    }

    yum_pkg_available() {
      yum -q "${YUM_OPTS[@]}" list available "$1" >/dev/null 2>&1
    }

    yum_install_one() {
      ci_deps_as_root yum -y "${YUM_OPTS[@]}" install "$1"
    }

    yum_pre_install() {
      echo "=== Install (Linux packages) ==="
      if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
        local needs_epel=0
        local pkg=""

        for pkg in "${PKGS[@]}"; do
          case "${pkg}" in
            cmake3|ninja-build)
              needs_epel=1
              break
              ;;
          esac
        done

        if [[ "${needs_epel}" == "1" ]]; then
          local basearch
          basearch="$(ci_deps_detect_rpm_basearch || true)"
          if ! ci_deps_centos7_has_epel_archive "${basearch}"; then
            echo "CentOS 7 EPEL archive is unavailable for basearch $(ci_deps_detect_rpm_basearch || echo unknown)" >&2
            return 1
          fi
          if [[ "${basearch}" == "armhfp" ]]; then
            ci_deps_install_epel7_altarch_repo
            YUM_OPTS+=(--enablerepo=ci-epel7-altarch)
          else
            ci_deps_install_epel7_archive_repo
            YUM_OPTS+=(--enablerepo=ci-epel7-archive)
          fi
        fi
        return 0
      fi

      if ci_deps_as_root yum -y "${YUM_OPTS[@]}" install epel-release; then
        if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
          YUM_OPTS+=(--enablerepo=epel)
        fi
      fi
    }

    if [[ "${os_name}" == "centos" && "${version}" == "7" && "${mode}" != "print" ]]; then
      ci_deps_install_centos7_vault_repo
      YUM_OPTS=(
        --disablerepo=*
        --enablerepo=centos7-vault-base
        --enablerepo=centos7-vault-updates
        --enablerepo=centos7-vault-extras
      )
    fi

    ci_deps_run_installer_modes \
      yum_pkg_installed yum_pkg_available yum_install_one yum_pre_install
    ;;
  zypper)
    zypper_pkg_installed() {
      rpm -q "$1" >/dev/null 2>&1
    }

    zypper_pkg_available() {
      zypper --non-interactive info "$1" >/dev/null 2>&1
    }

    zypper_install_one() {
      ci_deps_as_root zypper --non-interactive install "$1"
    }

    zypper_pre_install() {
      echo "=== Install (Linux packages) ==="
      ci_deps_as_root zypper --non-interactive refresh
    }

    ci_deps_run_installer_modes \
      zypper_pkg_installed zypper_pkg_available zypper_install_one zypper_pre_install
    ;;
  apk)
    apk_pkg_installed() {
      apk info -e "$1" >/dev/null 2>&1
    }

    apk_pkg_available() {
      apk search -x "$1" >/dev/null 2>&1
    }

    apk_install_one() {
      ci_deps_as_root apk add --no-cache "$1"
    }

    ci_deps_run_installer_modes \
      apk_pkg_installed "" apk_install_one "" "=== Install (Linux packages) ==="
    ;;
  pacman)
    pacman_pkg_installed() {
      pacman -Q "$1" >/dev/null 2>&1
    }

    pacman_pkg_available() {
      pacman -Si "$1" >/dev/null 2>&1
    }

    pacman_install_one() {
      ci_deps_as_root pacman -S --noconfirm --needed "$1"
    }

    pacman_pre_install() {
      echo "=== Install (Linux packages) ==="
      ci_deps_as_root pacman -Sy --noconfirm archlinux-keyring
      ci_deps_as_root pacman -Syu --noconfirm
    }

    ci_deps_run_installer_modes \
      pacman_pkg_installed pacman_pkg_available pacman_install_one pacman_pre_install
    ;;
  brew)
    brew_pkg_installed() {
      brew list --versions "$1" >/dev/null 2>&1
    }

    brew_pkg_available() {
      brew info --formula "$1" >/dev/null 2>&1
    }

    brew_install_one() {
      brew install "$1"
    }

    brew_pre_install() {
      echo "=== Install (Homebrew packages) ==="
      brew update
    }

    ci_deps_run_installer_modes \
      brew_pkg_installed brew_pkg_available brew_install_one brew_pre_install
    ;;
  *)
    echo "Unsupported package manager: ${pkgmgr}" >&2
    exit 2
    ;;
esac
