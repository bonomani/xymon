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

is_supported_local_cmake_profile() {
  case "$1" in
    default|bsdlocal|macostree|gnuinstall|packaging)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_cmake_build_dir() {
  case "$1" in
    default)
      printf '%s' "build-cmake"
      ;;
    bsdlocal)
      printf '%s' "build-cmake-bsdlocal"
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
    bsdlocal)
      printf '%s' "bsd_local"
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
    default|bsdlocal|macostree)
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
    bsdlocal)
      printf '%s' "/usr/local"
      ;;
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
    default|bsdlocal|macostree|gnuinstall)
      printf '%s' "ON"
      ;;
    *)
      return 1
      ;;
  esac
}

emit_local_cmake_profile_cache_args() {
  case "$1" in
    bsdlocal)
      if [[ -n "${XYMON_BSD_LOCALBASE:-}" ]]; then
        printf '%s\n' "-DXYMON_BSD_LOCALBASE=${XYMON_BSD_LOCALBASE}"
      fi
      if [[ -n "${XYMON_BSD_LOCALSTATEDIR:-}" ]]; then
        printf '%s\n' "-DXYMON_BSD_LOCALSTATEDIR=${XYMON_BSD_LOCALSTATEDIR}"
      fi
      ;;
  esac
}
