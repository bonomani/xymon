#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

PROFILE="${1:-default}"
ENABLE_LDAP="${ENABLE_LDAP:-ON}"
XYMON_VARIANT="${XYMON_VARIANT:-all}"

sudo apt-get update

BASE_PKGS=(
  build-essential
  perl
  fping
  libssl-dev
  libpcre3-dev
  librrd-dev
  libtirpc-dev
)

if [[ "${PROFILE}" == "debian" ]]; then
  PROFILE_PKGS=()
  if [[ "${XYMON_VARIANT}" != "client" ]]; then
    PROFILE_PKGS+=(libc-ares-dev)
  fi
  if [[ "${ENABLE_LDAP}" == "ON" ]]; then
    PROFILE_PKGS+=(libldap-dev)
  fi
else
  PROFILE_PKGS=(clang)
  if [[ "${ENABLE_LDAP}" == "ON" ]]; then
    PROFILE_PKGS+=(libldap2-dev)
  fi
fi

sudo apt-get install -y --no-install-recommends \
  "${BASE_PKGS[@]}" \
  "${PROFILE_PKGS[@]}"

id xymon >/dev/null 2>&1 || sudo useradd -r -m -d /home/xymon -s /usr/sbin/nologin xymon
sudo mkdir -p /home/xymon
sudo chown xymon:xymon /home/xymon
