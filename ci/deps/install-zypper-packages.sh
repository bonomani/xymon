#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-zypper-packages.sh [--print] [--check-only] [--install]
                                  --family FAMILY --os NAME [--version NAME]

Options:
  --print       Print package list and exit
  --check-only  Exit 0 if all packages are installed, 1 otherwise
  --install     Install packages (default)
  --family NAME   Dependency family (e.g. suse)
  --os NAME       OS key (e.g. opensuse_leap)
  --version NAME  Optional version key (e.g. 15_6)
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
CI_COMPILER="${CI_COMPILER:-}"

os_key="${os_name}"
if [[ -n "${version}" ]]; then
  os_key="${os_name}_${version}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t PKGS < <(
  "${script_dir}/packages-from-yaml.sh" \
    --variant "${VARIANT}" \
    --family "${family}" \
    --os "${os_key}" \
    --pkgmgr zypper \
    --enable-ldap "${ENABLE_LDAP}" \
    --enable-snmp "${ENABLE_SNMP}"
)

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

echo "=== Install (Linux packages) ==="
zypper --non-interactive refresh
zypper --non-interactive install "${PKGS[@]}"
