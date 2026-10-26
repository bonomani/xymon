#!/usr/bin/env bash
# Alpine "apk" backend plugin, sourced by install-packages.sh.
# shellcheck shell=bash

pkg_installed() {
  apk info -e "$1" >/dev/null 2>&1
}

pkg_available() {
  apk search -x "$1" >/dev/null 2>&1
}

pkg_install_one() {
  # `apk add --no-cache` fetches the package index again for every package,
  # so one dropped connection to the CDN ("unexpected eof while reading")
  # fails whichever package it lands on, as "no such package". Try again
  # before giving up.
  local attempt rc
  for attempt in 1 2 3; do
    rc=0
    ci_deps_as_root apk add --no-cache "$1" || rc=$?
    [[ "${rc}" -ne 0 ]] || return 0
    [[ "${attempt}" -lt 3 ]] || break
    echo "apk add $1 failed (rc=${rc}), attempt ${attempt} of 3; retrying in $((attempt * 5))s" >&2
    sleep $((attempt * 5))
  done
  return "${rc}"
}

pkg_pre_install() {
  # No metadata refresh needed: `apk add --no-cache` re-fetches the package
  # index on every install.
  :
}
