#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

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

mode="install"
print_list="0"
family=""
os_name=""
version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      print_list="1"
      if [[ "${mode}" == "install" ]]; then
        mode="print"
      fi
      shift
      ;;
    --check-only) mode="check"; shift ;;
    --install) mode="install"; shift ;;
    --family) family="$2"; shift 2 ;;
    --os) os_name="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${family}" || -z "${os_name}" ]]; then
  echo "Missing required --family/--os flags." >&2
  usage
  exit 2
fi

ENABLE_LDAP="${ENABLE_LDAP:-ON}"
ENABLE_SNMP="${ENABLE_SNMP:-ON}"
VARIANT="${VARIANT:-server}"
DEPS_VARIANT="${VARIANT}"
case "${VARIANT}" in
  server|client|localclient)
    ;;
  *)
    echo "Unsupported VARIANT: ${VARIANT}" >&2
    exit 2
    ;;
esac
CI_COMPILER="${CI_COMPILER:-}"

os_key="${os_name}"
if [[ -n "${version}" ]]; then
  os_key="${os_name}_${version}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
packages_output="$(
  "${script_dir}/packages-from-yaml.sh" \
    --variant "${DEPS_VARIANT}" \
    --family "${family}" \
    --os "${os_key}" \
    --pkgmgr yum \
    --enable-ldap "${ENABLE_LDAP}" \
    --enable-snmp "${ENABLE_SNMP}"
)"
PKGS=()
while IFS= read -r pkg; do
  [[ -n "${pkg}" ]] && PKGS+=("${pkg}")
done <<< "${packages_output}"
if [[ "${#PKGS[@]}" -eq 0 ]]; then
  echo "No packages resolved for variant=${DEPS_VARIANT} family=${family} os=${os_key} pkgmgr=yum" >&2
  exit 1
fi

if [[ "${CI_COMPILER}" == "clang" ]]; then
  PKGS+=(clang)
fi

if [[ "${mode}" == "print" ]]; then
  printf '%s\n' "${PKGS[@]}"
  exit 0
fi

if [[ "${mode}" == "check" ]]; then
  missing=0
  missing_pkgs=()
  for pkg in "${PKGS[@]}"; do
    if ! rpm -q "${pkg}" >/dev/null 2>&1; then
      missing=1
      missing_pkgs+=("${pkg}")
    fi
  done
  if [[ "${print_list}" == "1" && "${missing}" == "1" ]]; then
    printf '%s\n' "${missing_pkgs[@]}"
  fi
  exit "${missing}"
fi

if [[ "${mode}" == "install" && "${print_list}" == "1" ]]; then
  printf '%s\n' "${PKGS[@]}"
fi

as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
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
  as_root install -m 0644 "${vault_repo_tmp}" /etc/yum.repos.d/centos7-vault.repo
  rm -f "${vault_repo_tmp}"
  YUM_OPTS=(
    --disablerepo=*
    --enablerepo=centos7-vault-base
    --enablerepo=centos7-vault-updates
    --enablerepo=centos7-vault-extras
  )
fi

echo "=== Install (Linux packages) ==="
if as_root yum -y "${YUM_OPTS[@]}" install epel-release; then
  if [[ "${os_name}" == "centos" && "${version}" == "7" ]]; then
    YUM_OPTS+=(--enablerepo=epel)
  fi
fi
as_root yum -y "${YUM_OPTS[@]}" install "${PKGS[@]}"
