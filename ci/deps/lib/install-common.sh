#!/usr/bin/env bash
set -euo pipefail

CI_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ci_deps_enable_trace() {
  if [[ -n "${CI:-}" || -n "${DEBUG:-}" ]]; then
    set -x
  fi
}

ci_deps_init_cli() {
  mode="install"
  print_list="0"
  family=""
  os_name=""
  version=""
}

ci_deps_parse_cli() {
  local require_family="${1:-1}"
  local require_os="${2:-1}"
  shift 2 || true

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
      --family)
        family="$2"
        shift 2
        ;;
      --os)
        os_name="$2"
        shift 2
        ;;
      --version)
        version="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "${require_family}" == "1" && -z "${family}" ]]; then
    echo "Missing required --family flag." >&2
    usage
    exit 2
  fi

  if [[ "${require_os}" == "1" && -z "${os_name}" ]]; then
    echo "Missing required --os flag." >&2
    usage
    exit 2
  fi
}

ci_deps_setup_variant_defaults() {
  ENABLE_LDAP="${ENABLE_LDAP:-ON}"
  ENABLE_SNMP="${ENABLE_SNMP:-ON}"
  VARIANT="${VARIANT:-server}"
  DEPS_VARIANT="${VARIANT}"
  case "${VARIANT}" in
    server|client|localclient)
      ;;
    *)
      echo "Unsupported VARIANT: ${VARIANT}" >&2
      exit 2
      ;;
  esac

  CI_COMPILER="${CI_COMPILER:-}"
}

ci_deps_build_os_key() {
  os_key="${os_name}"
  if [[ -n "${version}" ]]; then
    os_key="${os_name}_${version}"
  fi
}

ci_deps_resolve_packages() {
  local pkgmgr="$1"
  local family_key="$2"
  local os_key="$3"
  local apply_ci_compiler="${4:-1}"
  local packages_output=""

  packages_output="$(
    "${CI_DEPS_DIR}/packages-from-yaml.sh" \
      --variant "${DEPS_VARIANT}" \
      --family "${family_key}" \
      --os "${os_key}" \
      --pkgmgr "${pkgmgr}" \
      --enable-ldap "${ENABLE_LDAP}" \
      --enable-snmp "${ENABLE_SNMP}"
  )"

  PKGS=()
  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] && PKGS+=("${pkg}")
  done <<< "${packages_output}"

  if [[ "${#PKGS[@]}" -eq 0 ]]; then
    echo "No packages resolved for variant=${DEPS_VARIANT} family=${family_key} os=${os_key} pkgmgr=${pkgmgr}" >&2
    exit 1
  fi

  if [[ "${apply_ci_compiler}" == "1" && "${CI_COMPILER}" == "clang" ]]; then
    PKGS+=(clang)
  fi
}

ci_deps_mode_print_or_exit() {
  if [[ "${mode}" == "print" ]]; then
    printf '%s\n' "${PKGS[@]}"
    exit 0
  fi
}

ci_deps_mode_check_or_exit() {
  local check_fn="${1:-}"
  local missing=0
  local missing_pkgs=()
  local pkg=""

  if [[ "${mode}" != "check" ]]; then
    return 0
  fi

  if [[ -z "${check_fn}" ]]; then
    echo "Missing package check callback function" >&2
    exit 2
  fi

  for pkg in "${PKGS[@]}"; do
    if ! "${check_fn}" "${pkg}"; then
      missing=1
      missing_pkgs+=("${pkg}")
    fi
  done

  if [[ "${print_list}" == "1" && "${missing}" == "1" ]]; then
    printf '%s\n' "${missing_pkgs[@]}"
  fi
  exit "${missing}"
}

ci_deps_mode_install_print() {
  if [[ "${mode}" == "install" && "${print_list}" == "1" ]]; then
    printf '%s\n' "${PKGS[@]}"
  fi
}

ci_deps_as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}
