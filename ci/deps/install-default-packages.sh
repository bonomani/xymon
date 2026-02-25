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
normalization_file="${script_dir}/platform-normalization.yaml"
normalization_resolver="${script_dir}/lib/resolve-platform-normalization.awk"

family=""
os_name=""
version=""
pkgmgr=""

detect_linux() {
  if [[ -f /etc/os-release ]]; then
    os_name="$(
      awk -F= '/^ID=/{v=$2; gsub(/"/,"",v); print tolower(v); exit}' /etc/os-release
    )"
    version="$(
      awk -F= '/^VERSION_ID=/{v=$2; gsub(/"/,"",v); print v; exit}' /etc/os-release
    )"
  fi
}

case "${RUNNER_OS:-}" in
  macOS)
    os_name="macos"
    version="latest"
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
    netbsd|freebsd|openbsd)
      exec "${script_dir}/install-bsd-packages.sh" --os "${os_name}" --version "${version:-}"
      ;;
    *)
      if [[ ! -f "${normalization_file}" ]]; then
        echo "Missing platform normalization file: ${normalization_file}" >&2
        exit 2
      fi
      if [[ ! -f "${normalization_resolver}" ]]; then
        echo "Missing platform normalization resolver: ${normalization_resolver}" >&2
        exit 2
      fi

      normalized="$(
        awk \
          -v RULES_FILE="${normalization_file}" \
          -v OS_ID="${os_name}" \
          -v VERSION="${version}" \
          -f "${normalization_resolver}"
      )" || {
        echo "Unsupported or unknown OS ID: ${os_name}" >&2
        exit 2
      }

      IFS='|' read -r family os_name pkgmgr version <<< "${normalized}"
      if [[ -z "${family}" || -z "${os_name}" || -z "${pkgmgr}" ]]; then
        echo "Invalid platform normalization for OS ID: ${os_name}" >&2
        exit 2
      fi
      ;;
  esac
fi

if [[ -z "${version}" ]]; then
  version="latest"
fi

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
