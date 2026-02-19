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

ci_deps_init_cli
ci_deps_parse_cli 1 1 "$@"
ci_deps_setup_variant_defaults
ci_deps_build_os_key
ci_deps_resolve_packages yum "${family}" "${os_key}"

yum_pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

yum_pkg_available() {
  yum -q "${YUM_OPTS[@]}" list available "$1" >/dev/null 2>&1
}

YUM_OPTS=()
if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
  vault_repo_tmp="$(mktemp)"
  cat > "${vault_repo_tmp}" <<'EOF'
[centos7-vault-base]
name=CentOS 7 Vault Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
enabled=1
gpgcheck=0

[centos7-vault-updates]
name=CentOS 7 Vault Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
enabled=1
gpgcheck=0

[centos7-vault-extras]
name=CentOS 7 Vault Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
enabled=1
gpgcheck=0
EOF
  ci_deps_as_root install -m 0644 "${vault_repo_tmp}" /etc/yum.repos.d/centos7-vault.repo
  rm -f "${vault_repo_tmp}"
  YUM_OPTS=(
    --disablerepo=*
    --enablerepo=centos7-vault-base
    --enablerepo=centos7-vault-updates
    --enablerepo=centos7-vault-extras
  )
fi

if [[ "${mode}" == "install" ]]; then
  echo "=== Install (Linux packages) ==="
  if ci_deps_as_root yum -y "${YUM_OPTS[@]}" install epel-release; then
    if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
      YUM_OPTS+=(--enablerepo=epel)
    fi
  fi
fi

ci_deps_resolve_package_alternatives yum_pkg_installed yum_pkg_available

ci_deps_mode_print_or_exit
ci_deps_mode_check_or_exit yum_pkg_installed
ci_deps_mode_install_print

if [[ "${mode}" == "install" ]]; then
  ci_deps_as_root yum -y "${YUM_OPTS[@]}" install "${PKGS[@]}"
fi
