#!/usr/bin/env bash
set -euo pipefail

ci_linux_packages() {
  local distro_family="$1"
  local distro="$2"
  local version="$3"
  local variant="$4"
  local enable_ldap="$5"
  local ci_compiler="$6"

  local base_pkgs=(
    build-essential
    libssl-dev
    libpcre3-dev
    librrd-dev
    libtirpc-dev
  )

  local profile_pkgs=()
  if [[ "${distro_family}" == "linux_github" ]]; then
    if [[ "${variant}" != "client" ]]; then
      profile_pkgs+=(libc-ares-dev)
    fi
    if [[ "${enable_ldap}" == "ON" ]]; then
      profile_pkgs+=(libldap-dev)
    fi
    if [[ "${ci_compiler}" == "clang" ]]; then
      profile_pkgs+=(clang)
    fi
  else
    echo "Unsupported distro family for package list: ${distro_family} (${distro} ${version})" >&2
    return 1
  fi

  printf '%s\n' "${base_pkgs[@]}" "${profile_pkgs[@]}"
}
