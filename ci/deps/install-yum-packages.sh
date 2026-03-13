#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${script_dir}/lib/install-common.sh"
ci_deps_enable_trace

usage() {
  cat <<'USAGE'
Usage: install-yum-packages.sh [--print] [--check-only] [--install]
                               --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. rpm)
  --os NAME       OS key (e.g. centos)
  --version NAME  Optional version key (e.g. 7)
USAGE
}

ci_deps_init_linux_installer yum "$@"
# Populated by ci_deps_init_linux_installer from install-common.sh.
os_name="${os_name:-}"
version="${version:-}"

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
      if ! ci_deps_centos7_has_epel_archive; then
        echo "CentOS 7 EPEL archive is unavailable for basearch $(ci_deps_detect_rpm_basearch || echo unknown)" >&2
        return 1
      fi
      ci_deps_install_epel7_archive_repo
      YUM_OPTS+=(--enablerepo=ci-epel7-archive)
    fi
    return 0
  fi

  if ci_deps_as_root yum -y "${YUM_OPTS[@]}" install epel-release; then
    if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
      YUM_OPTS+=(--enablerepo=epel)
    fi
  fi
}

YUM_OPTS=()
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
