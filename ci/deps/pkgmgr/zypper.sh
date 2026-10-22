#!/usr/bin/env bash
# openSUSE "zypper" backend plugin, sourced by install-packages.sh.
# shellcheck shell=bash

pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

pkg_available() {
  zypper --non-interactive info "$1" >/dev/null 2>&1
}

# --no-recommends, as apt.sh's --no-install-recommends: what a package
# requires, not what it recommends.
pkg_install_one() {
  ci_deps_as_root zypper --non-interactive install --no-recommends "$1"
}

pkg_pre_install() {
  # Refresh metadata before installing.
  ci_deps_as_root zypper --non-interactive refresh
}
