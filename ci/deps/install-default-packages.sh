#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
normalization_file="${script_dir}/platform-normalization.yaml"
normalization_resolver="${script_dir}/lib/resolve-platform-normalization.awk"

mode="install"
print_list="0"
report_json_path="${CI_DEPS_REPORT_JSON:-}"
build_tool="${CI_DEPS_BUILD_TOOL:-}"

family=""
os_name=""
version=""
pkgmgr=""
target_script=""
target_pkgmgr=""

declare -a target_base_args=()
declare -a target_args=()

usage() {
  cat <<'USAGE'
Usage: install-default-packages.sh [--print] [--check-only] [--install]
                                   [--report-json PATH]
                                   [--build-tool make|cmake]

Detect the current OS and dispatch to the matching install-<pkgmgr>-packages.sh
script. When --report-json is provided, also write a JSON report describing:
- requested packages
- packages already present before install
- packages newly installed by the run
- indirect packages added by the package manager

Options:
  --print             Print the resolved package list and exit
  --check-only        Exit 0 if all packages are installed, 1 otherwise
  --install           Install packages (default)
  --report-json PATH  Write dependency state report to PATH
  --build-tool TOOL   Resolve build-specific deps (make|cmake)
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print)
        print_list="1"
        if [[ "${mode}" == "install" ]]; then
          mode="print"
        fi
        shift
        ;;
      --check-only)
        mode="check"
        shift
        ;;
      --install)
        mode="install"
        shift
        ;;
      --report-json)
        report_json_path="${2:-}"
        shift 2
        ;;
      --report-json=*)
        report_json_path="${1#*=}"
        shift
        ;;
      --build-tool)
        build_tool="${2:-}"
        shift 2
        ;;
      --build-tool=*)
        build_tool="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done

  if [[ -z "${report_json_path}" && -n "${CI_DEPS_REPORT_JSON:-}" ]]; then
    report_json_path="${CI_DEPS_REPORT_JSON}"
  fi
  if [[ -z "${build_tool}" && -n "${CI_DEPS_BUILD_TOOL:-}" ]]; then
    build_tool="${CI_DEPS_BUILD_TOOL}"
  fi
}

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

detect_runner_os() {
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
}

resolve_normalized_platform() {
  local normalized=""

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

  # Amazon Linux 2 still exposes yum as the package manager used by the
  # runtime deps installer, while Amazon Linux 2023 uses dnf.
  if [[ "${os_name}" == "amazonlinux" && "${version}" == "2" ]]; then
    pkgmgr="yum"
  fi
}

resolve_target_script() {
  if [[ -z "${family}" ]]; then
    if [[ -z "${os_name}" ]]; then
      os_name="$(uname -s 2>/dev/null || true)"
      os_name="$(printf '%s' "${os_name}" | awk '{print tolower($0)}')"
      version="$(uname -r 2>/dev/null || true)"
    fi

    case "${os_name}" in
      netbsd|freebsd|openbsd)
        target_script="${script_dir}/install-bsd-packages.sh"
        target_base_args=(--os "${os_name}")
        if [[ -n "${version}" ]]; then
          target_base_args+=(--version "${version}")
        fi
        # NetBSD: prefer pkgin over raw pkg_add. pkg_add will not upgrade an
        # already-installed older dependency (e.g. a stale sqlite3) to satisfy
        # a newer package, whereas pkgin resolves and upgrades via repo
        # metadata. pkgin reuses the pkg_add dependency set in the deps YAML.
        # An explicit BSD_PKGMGR still wins.
        if [[ "${os_name}" == "netbsd" ]]; then
          target_pkgmgr="${BSD_PKGMGR:-pkgin}"
        fi
        return
        ;;
      *)
        resolve_normalized_platform
        ;;
    esac
  fi

  if [[ -z "${version}" ]]; then
    version="latest"
  fi

  target_base_args=(--family "${family}" --os "${os_name}" --version "${version}")

  case "${pkgmgr}" in
    apt|dnf|yum|zypper|apk|pacman|brew)
      target_script="${script_dir}/install-packages.sh"
      target_pkgmgr="${pkgmgr}"
      ;;
    *)
      echo "Unsupported package manager: ${pkgmgr}" >&2
      exit 2
      ;;
  esac
}

build_target_args() {
  target_args=()

  if [[ -n "${target_pkgmgr}" ]]; then
    target_args+=(--pkgmgr "${target_pkgmgr}")
  fi

  case "${mode}" in
    print)
      target_args+=(--print)
      ;;
    check)
      if [[ "${print_list}" == "1" ]]; then
        target_args+=(--print)
      fi
      target_args+=(--check-only)
      ;;
    install)
      if [[ "${print_list}" == "1" ]]; then
        target_args+=(--print --install)
      fi
      ;;
    *)
      echo "Unsupported mode: ${mode}" >&2
      exit 2
      ;;
  esac

  target_args+=("${target_base_args[@]}")
  if [[ -n "${report_json_path}" ]]; then
    target_args+=(--report-json "${report_json_path}")
  fi
  if [[ -n "${build_tool}" ]]; then
    target_args+=(--build-tool "${build_tool}")
  fi
}

# Report generation is delegated to installer-specific scripts via
# --report-json (implemented in ci/deps/lib/install-common.sh).

main() {
  parse_args "$@"

  detect_runner_os
  resolve_target_script

  build_target_args
  exec "${target_script}" "${target_args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
