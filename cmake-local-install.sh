#!/usr/bin/env bash
set -euo pipefail

build_dir="${BUILD_DIR:?BUILD_DIR is required}"
non_interactive="${NON_INTERACTIVE:-0}"
build_install="${BUILD_INSTALL:-1}"

normalize_onoff() {
  local val="$1"
  case "${val^^}" in
    ON|YES|Y|TRUE|1) printf 'ON' ;;
    OFF|NO|N|FALSE|0) printf 'OFF' ;;
    *) printf '%s' "${val}" ;;
  esac
}

if [[ "${build_install}" == "1" ]]; then
  if [[ "${non_interactive}" != "1" ]]; then
    read -r -p "Install now? [y/N]: " install_confirm
    install_confirm="$(normalize_onoff "${install_confirm}")"
    if [[ "${install_confirm}" == "ON" ]]; then
      cmake --install "${build_dir}"
    else
      echo "Install skipped."
    fi
  else
    cmake --install "${build_dir}"
  fi
fi
