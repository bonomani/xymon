#!/usr/bin/env bash
# NetBSD/OpenBSD "pkg_add" backend plugin, sourced by install-packages.sh.
# The generic pkg_* functions delegate to helpers in lib/install-bsd-common.sh.
# shellcheck shell=bash

pkg_installed() {
  bsd_pkg_installed pkg_add "$1"
}

pkg_available() {
  bsd_pkg_available pkg_add "$1"
}

pkg_install_one() {
  local pkg="${1:-}"
  local rc=0
  local -a saved_pkgs=("${PKGS[@]}")

  PKGS=("${pkg}")
  if ! bsd_install_pkg_add; then
    rc=$?
  fi

  PKGS=("${saved_pkgs[@]}")
  return "${rc}"
}

pkg_pre_install() {
  # No metadata refresh: pkg_add has no local catalog; it resolves names
  # against PKG_PATH at install time. (OpenBSD release sets are frozen.)
  :
}
