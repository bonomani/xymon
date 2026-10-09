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
  bsd_netbsd_pkg_env_args
  ci_deps_as_root env ${NETBSD_PKG_ENV_ARGS[@]+"${NETBSD_PKG_ENV_ARGS[@]}"} \
    /usr/pkg/bin/pkgin -y install "$1"
}

# Runs once before the per-package install loop: prepare the pkgsrc repo config,
# ensure a CA trust store + pkgin binary exist, and refresh metadata so
# dependency upgrades resolve against the current binary set.
pkg_pre_install() {
  # Repo config, CA trust store, pkgin bootstrap, and metadata refresh.
  bsd_pkgin_prepare
}
