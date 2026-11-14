#!/usr/bin/env bash
# FreeBSD "pkg" backend plugin, sourced by install-packages.sh.
# The generic pkg_* functions delegate to helpers in lib/install-bsd-common.sh.
# shellcheck shell=bash

pkg_installed() {
  bsd_pkg_installed pkg "$1"
}

pkg_available() {
  bsd_pkg_available pkg "$1"
}

pkg_install_one() {
  ci_deps_as_root env ASSUME_ALWAYS_YES=YES pkg install "$1"
}

pkg_pre_install() {
  # Refresh the binary package catalog before installing.
  ci_deps_as_root env ASSUME_ALWAYS_YES=YES pkg update
}
