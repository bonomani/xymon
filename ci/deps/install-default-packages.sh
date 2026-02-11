#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-default-packages.sh
Detects the current OS and installs build dependencies using the appropriate
install-<pkgmgr>-packages.sh script.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

family=""
os_name=""
version=""
pkgmgr=""

detect_linux() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_name="${ID:-}"
    version="${VERSION_ID:-}"
  fi
}

case "${RUNNER_OS:-}" in
  macOS)
    family="macos"
    os_name="macos"
    version="latest"
    pkgmgr="brew"
    ;;
  Linux|"")
    detect_linux
    ;;
  *)
    echo "Unsupported RUNNER_OS: ${RUNNER_OS}" >&2
    exit 2
    ;;
esac

if [[ -z "${family}" ]]; then
if [[ -z "${os_name}" ]]; then
  os_name="$(uname -s 2>/dev/null || true)"
  os_name="$(printf '%s' "${os_name}" | awk '{print tolower($0)}')"
  version="$(uname -r 2>/dev/null || true)"
fi

case "${os_name}" in
    debian)
      family="debian"
      pkgmgr="apt"
      ;;
    ubuntu)
      family="gh-debian"
      pkgmgr="apt"
      ;;
    netbsd|freebsd|openbsd)
      exec "${script_dir}/install-bsd-packages.sh" --os "${os_name}" --version "${version:-}"
      ;;
    rocky|rockylinux|almalinux|fedora)
      family="rpm"
      pkgmgr="dnf"
      if [[ "${os_name}" == "rocky" ]]; then
        os_name="rockylinux"
      fi
      ;;
    centos)
      family="rpm"
      pkgmgr="yum"
      ;;
    opensuse*|sles)
      family="suse"
      pkgmgr="zypper"
      ;;
    alpine)
      family="alpine"
      pkgmgr="apk"
      ;;
    arch|archlinux)
      family="arch"
      pkgmgr="pacman"
      os_name="archlinux"
      ;;
    *)
      echo "Unsupported or unknown OS ID: ${os_name}" >&2
      exit 2
      ;;
  esac
fi

if [[ -z "${version}" ]]; then
  version="latest"
fi

# Normalize version tokens used by deps YAML keys.
case "${family}" in
  gh-debian)
    version="latest"
    ;;
  debian)
    case "${version}" in
      12) version="bookworm" ;;
      11) version="bullseye" ;;
      *) : ;;
    esac
    ;;
  rpm)
    # Normalize to major version for distro keys (e.g. 9.7 -> 9).
    if [[ "${version}" =~ ^[0-9]+([.].*)?$ ]]; then
      version="${version%%.*}"
    fi
    ;;
  suse)
    # Convert 15.6 -> 15_6
    version="${version//./_}"
    ;;
  alpine)
    # Normalize 3.19 -> 3
    if [[ "${version}" =~ ^3 ]]; then
      version="3"
    fi
    ;;
  arch|macos)
    version="latest"
    ;;
esac

case "${pkgmgr}" in
  apt)
    exec "${script_dir}/install-apt-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  dnf)
    exec "${script_dir}/install-dnf-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  yum)
    exec "${script_dir}/install-yum-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  zypper)
    # normalize opensuse id to match YAML keys
    if [[ "${os_name}" == "opensuse-leap" ]]; then
      os_name="opensuse_leap"
    fi
    exec "${script_dir}/install-zypper-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  apk)
    exec "${script_dir}/install-apk-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  pacman)
    exec "${script_dir}/install-pacman-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  brew)
    exec "${script_dir}/install-brew-packages.sh" --family "${family}" --os "${os_name}" --version "${version}"
    ;;
  *)
    echo "Unsupported package manager: ${pkgmgr}" >&2
    exit 2
    ;;
esac
