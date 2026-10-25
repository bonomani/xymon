#!/usr/bin/env bash
# NetBSD "pkgin" backend plugin, sourced by install-packages.sh.
# The generic pkg_* functions delegate to helpers in lib/install-bsd-common.sh.
# shellcheck shell=bash

pkg_installed() {
  bsd_pkg_installed pkgin "$1"
}

pkg_available() {
  bsd_pkg_available pkgin "$1"
}

pkg_install_one() {
  # env, not a plain call: sudo resets the environment, so the pkg_install
  # settings prepared by bsd_prepare_netbsd_pkg_environment have to be handed
  # over explicitly or the OS-ABI check refuses packages built for the base
  # release. See bsd_netbsd_pkg_env_args().
  local rc
  while :; do
    rc=0
    bsd_netbsd_pkg_env_args
    ci_deps_as_root env ${NETBSD_PKG_ENV_ARGS[@]+"${NETBSD_PKG_ENV_ARGS[@]}"} \
      /usr/pkg/bin/pkgin -y install "$1" || rc=$?
    [[ "${rc}" -ne 0 ]] || return 0
    # pkgin only counts pkg_install's errors; the reasons are in its log.
    echo "pkgin install of $1 failed (rc=${rc}); pkg_install's error log:" >&2
    cat /var/db/pkgin/pkg_install-err.log >&2 2>/dev/null || true
    # A stale mirror fails the same way for every package: try the next.
    bsd_pkgin_next_mirror || return "${rc}"
  done
}

# Runs once before the per-package install loop: prepare the pkgsrc repo config,
# ensure a CA trust store + pkgin binary exist, and refresh metadata so
# dependency upgrades resolve against the current binary set.
pkg_pre_install() {
  # Repo config, CA trust store, pkgin bootstrap, and metadata refresh.
  bsd_pkgin_prepare
}
