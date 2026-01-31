#!/usr/bin/env bash
set -euo pipefail

ci_linux_packages() {
  local distro_family="$1"
  local distro="$2"
  local version="$3"
  local variant="$4"
  local enable_ldap="$5"
  local ci_compiler="$6"
  local enable_snmp="$7"

  if [[ "${distro_family}" != "gh-debian" ]]; then
    echo "Unsupported distro family for package list: ${distro_family} (${distro} ${version})" >&2
    return 1
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local yaml_pkgs=()
  mapfile -t yaml_pkgs < <(
    python3 "${script_dir}/packages-from-yaml.py" \
      --variant "${variant}" \
      --family "${distro_family}" \
      --os "${distro}_${version}" \
      --pkgmgr apt \
      --enable-ldap "${enable_ldap}" \
      --enable-snmp "${enable_snmp}"
  )
  if [[ "${ci_compiler}" == "clang" ]]; then
    yaml_pkgs+=(clang)
  fi

  printf '%s\n' "${yaml_pkgs[@]}"
}
