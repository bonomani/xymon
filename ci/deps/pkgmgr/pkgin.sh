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
  ci_deps_as_root /usr/pkg/bin/pkgin -y install "$1"
}

# Runs once before the per-package install loop: prepare the pkgsrc repo config,
# ensure a CA trust store + pkgin binary exist, and refresh metadata so
# dependency upgrades resolve against the current binary set.
pkg_pre_install() {
  # Repo config, CA trust store, pkgin bootstrap, and metadata refresh.
  bsd_pkgin_prepare
}
