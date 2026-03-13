#!/usr/bin/env bash

resolve_cmake_platform_os() {
  local platform_os="${1:-}"
  if [[ -n "${platform_os}" ]]; then
    printf '%s' "${platform_os}"
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      printf '%s' "macos"
      ;;
    FreeBSD)
      printf '%s' "freebsd"
      ;;
    NetBSD)
      printf '%s' "netbsd"
      ;;
    OpenBSD)
      printf '%s' "openbsd"
      ;;
    *)
      printf '%s' "linux"
      ;;
  esac
}

resolve_cmake_effective_profile() {
  local profile="$1"
  local platform_os="$2"

  if [[ "${profile}" == "default" && "${platform_os}" == "macos" ]]; then
    printf '%s' "macostree"
    return 0
  fi

  printf '%s' "${profile}"
}

resolve_cmake_build_dir() {
  case "$1" in
    default)
      printf '%s' "build-cmake"
      ;;
    macostree)
      printf '%s' "build-cmake-macostree"
      ;;
    gnuinstall)
      printf '%s' "build-cmake-gnu"
      ;;
    packaging)
      printf '%s' "build-cmake-packaging"
      ;;
    *)
      printf 'build-cmake/%s' "$1"
      ;;
  esac
}

resolve_cmake_layout() {
  local profile="$1"
  local platform_os="$2"

  case "${profile}" in
    default)
      if [[ "${platform_os}" == "freebsd" || "${platform_os}" == "netbsd" ]]; then
        printf '%s' "home_tree"
      else
        printf '%s' "var_tree"
      fi
      ;;
    macostree)
      printf '%s' "macos_tree"
      ;;
    gnuinstall|packaging)
      printf '%s' "fhs"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_cmake_use_gnuinstalldirs() {
  case "$1" in
    default|macostree)
      printf '%s' "OFF"
      ;;
    gnuinstall|packaging)
      printf '%s' "ON"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_cmake_install_prefix() {
  case "$1" in
    gnuinstall|packaging)
      printf '%s' "/usr"
      ;;
    default|macostree)
      printf '%s' "/"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_cmake_httpdgid_chgrp() {
  case "$1" in
    packaging)
      printf '%s' "OFF"
      ;;
    default|macostree|gnuinstall)
      printf '%s' "ON"
      ;;
    *)
      return 1
      ;;
  esac
}
