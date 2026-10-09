#!/usr/bin/env bash
# macOS MacPorts "port" backend plugin, sourced by install-packages.sh.
# shellcheck shell=bash

pkg_installed() {
  # `port installed <name>` exits 0 whether or not the port is present, so
  # check explicitly for an active installed version.
  port -q installed "$1" 2>/dev/null | grep -q '(active)'
}

pkg_available() {
  # `port info` exits non-zero for an unknown port.
  port info "$1" >/dev/null 2>&1
}

pkg_install_one() {
  ci_deps_as_root port -N install "$1"
}

pkg_pre_install() {
  # Sync the ports tree so package metadata is current before installing.
  ci_deps_as_root port -N selfupdate
}
