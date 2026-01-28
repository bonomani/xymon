#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

PROFILE="${1:-default}"

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
  PROFILE_PKGS=(libc-ares-dev libldap-dev)
else
  PROFILE_PKGS=(clang libldap2-dev)
fi

sudo apt-get install -y --no-install-recommends \
  "${BASE_PKGS[@]}" \
  "${PROFILE_PKGS[@]}"

id xymon >/dev/null 2>&1 || sudo useradd -r -m -d /home/xymon -s /usr/sbin/nologin xymon
sudo mkdir -p /home/xymon
sudo chown xymon:xymon /home/xymon
