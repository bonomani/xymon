#!/usr/bin/env bash
# Best-effort MacPorts installer for CI macOS runners (which ship Homebrew but
# not MacPorts). Builds MacPorts base from source so it works on any macOS
# release without a per-version .pkg/codename mapping. Idempotent.
#
# Callers should treat failure as non-fatal and fall back to Homebrew: this
# script only makes `port` available; it does not install Xymon's deps.
set -euo pipefail
IFS=$' \t\n'

PREFIX="${MACPORTS_PREFIX:-/opt/local}"
PORT_BIN="${PREFIX}/bin/port"
MACPORTS_REPO="${MACPORTS_REPO:-https://github.com/macports/macports-base.git}"

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

if [ -x "${PORT_BIN}" ]; then
  log "MacPorts already present at ${PORT_BIN}"
  export_port_path
else
  log "Building MacPorts base from source (prefix ${PREFIX})"
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' EXIT
  git clone --depth 1 "${MACPORTS_REPO}" "${workdir}/macports-base"
  (
    cd "${workdir}/macports-base"
    ./configure --prefix="${PREFIX}" --with-applications-dir="${PREFIX}/Applications"
    make
    as_root make install
  )
  export_port_path
fi

log "Syncing ports tree (selfupdate)"
as_root "${PORT_BIN}" -N selfupdate || log "selfupdate failed (continuing; install may still work)"

log "MacPorts ready: $("${PORT_BIN}" version 2>/dev/null || echo unknown)"
