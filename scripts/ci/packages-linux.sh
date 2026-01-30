#!/usr/bin/env bash
set -euo pipefail

ci_linux_packages() {
  local profile="$1"
  local variant="$2"
  local enable_ldap="$3"
  local ci_compiler="$4"

  local base_pkgs=(
    build-essential
    libssl-dev
    libpcre3-dev
    librrd-dev
    libtirpc-dev
  )

  local profile_pkgs=()
  if [[ "${profile}" == "debian" ]]; then
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
    profile_pkgs+=(clang)
    if [[ "${enable_ldap}" == "ON" ]]; then
      profile_pkgs+=(libldap2-dev)
    fi
  fi

  printf '%s\n' "${base_pkgs[@]}" "${profile_pkgs[@]}"
}
