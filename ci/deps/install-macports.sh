#!/usr/bin/env bash
# Best-effort MacPorts installer for CI macOS runners (which ship Homebrew but
# not MacPorts). Installs the official installer package for the runner's
# macOS from MacPorts' latest release, found by its version number in the
# release's file list, so no codename table is kept here; checks it against
# the release's checksums. Builds MacPorts base from source when there is no
# package for this macOS (a preview newer than the release) or any step
# fails. Idempotent.
#
# Callers should treat failure as non-fatal and fall back to Homebrew: this
# script only makes `port` available; it does not install Xymon's deps.
set -euo pipefail
IFS=$' \t\n'

PREFIX="${MACPORTS_PREFIX:-/opt/local}"
PORT_BIN="${PREFIX}/bin/port"
MACPORTS_REPO="${MACPORTS_REPO:-https://github.com/macports/macports-base.git}"
MACPORTS_RELEASE_API="${MACPORTS_RELEASE_API:-https://api.github.com/repos/macports/macports-base/releases/latest}"

log() { printf '=== install-macports: %s ===\n' "$*"; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

export_port_path() {
  export PATH="${PREFIX}/bin:${PREFIX}/sbin:${PATH}"
  # Persist for later GitHub Actions steps, when running under Actions.
  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n%s\n' "${PREFIX}/bin" "${PREFIX}/sbin" >> "${GITHUB_PATH}"
  fi
}

# install_pkg DIR: the official package for this macOS, or fail.
install_pkg() {
  local dir=$1 major release urls url name sum want
  [ "${PREFIX}" = /opt/local ] || return 1    # the packages install there only
  major="$(sw_vers -productVersion | cut -d. -f1)"
  release="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} "${MACPORTS_RELEASE_API}")" || return 1
  urls="$(printf '%s\n' "${release}" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"$/\1/')"
  url="$(printf '%s\n' "${urls}" | grep -E "/MacPorts-[0-9.]+-${major}-[A-Za-z]+\.pkg\$" | head -1)"
  [ -n "${url}" ] || { log "no package for macOS ${major} in the latest release"; return 1; }
  name="${url##*/}"
  curl -fsSL -o "${dir}/${name}" "${url}" || return 1
  curl -fsSL -o "${dir}/chk.txt" "$(printf '%s\n' "${urls}" | grep -E '\.chk\.txt$' | head -1)" || return 1
  # Packages are listed as SHA2-256(...), tarballs as SHA256(...).
  want="$(grep -F -e "SHA2-256(${name})= " -e "SHA256(${name})= " "${dir}/chk.txt" | head -1 | sed 's/.*= //')"
  sum="$(shasum -a 256 "${dir}/${name}" | cut -d' ' -f1)"
  [ -n "${want}" ] && [ "${sum}" = "${want}" ] || { log "checksum mismatch for ${name}"; return 1; }
  log "Installing ${name}"
  as_root installer -pkg "${dir}/${name}" -target / >/dev/null
}

build_from_source() {
  local dir=$1
  log "Building MacPorts base from source (prefix ${PREFIX})"
  git clone --depth 1 "${MACPORTS_REPO}" "${dir}/macports-base"
  (
    cd "${dir}/macports-base"
    # Keep MacPorts' default applications_dir (/Applications/MacPorts): its
    # binary archives are used only when it matches the one they were built
    # with, and otherwise every port is compiled from source.
    ./configure --prefix="${PREFIX}"
    make
    as_root make install
  )
}

if [ -x "${PORT_BIN}" ]; then
  log "MacPorts already present at ${PORT_BIN}"
else
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT
  if ! { install_pkg "${workdir}" && [ -x "${PORT_BIN}" ]; }; then
    build_from_source "${workdir}"
  fi
fi
export_port_path

log "Syncing ports tree (selfupdate)"
as_root "${PORT_BIN}" -N selfupdate || log "selfupdate failed (continuing; install may still work)"

log "MacPorts ready: $("${PORT_BIN}" version 2>/dev/null || echo unknown)"
