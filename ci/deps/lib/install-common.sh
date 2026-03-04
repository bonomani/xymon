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

ci_deps_init_linux_installer() {
  local pkgmgr="${1:-}"
  shift || true

  if [[ -z "${pkgmgr}" ]]; then
    echo "Missing package manager for Linux installer initialization" >&2
    exit 2
  fi

  ci_deps_init_cli
  ci_deps_parse_cli 1 1 "$@"
  ci_deps_setup_variant_defaults
  ci_deps_build_os_key
  ci_deps_resolve_packages "${pkgmgr}" "${family}" "${os_key}"
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

ci_deps_run_installer_modes() {
  local installed_fn="${1:-}"
  local available_fn="${2:-}"
  local install_fn="${3:-}"
  local pre_install_fn="${4:-}"
  local install_banner="${5:-}"
  local -a pkg_specs=()

  if [[ -z "${installed_fn}" ]]; then
    echo "Missing package check callback function" >&2
    exit 2
  fi
  if [[ -z "${install_fn}" ]]; then
    echo "Missing package install callback function" >&2
    exit 2
  fi

  if [[ "${mode}" == "install" && -n "${pre_install_fn}" ]]; then
    "${pre_install_fn}"
  fi

  pkg_specs=("${PKGS[@]}")
  ci_deps_resolve_package_alternatives "${installed_fn}" "${available_fn}"

  ci_deps_mode_print_or_exit
  ci_deps_mode_check_or_exit "${installed_fn}"
  ci_deps_mode_install_print

  if [[ "${mode}" == "install" ]]; then
    if [[ -n "${install_banner}" ]]; then
      echo "${install_banner}"
    fi
    PKGS=("${pkg_specs[@]}")
    ci_deps_install_packages_with_alternatives \
      "${installed_fn}" "${available_fn}" "${install_fn}"
  fi
}

ci_deps_trim() {
  local val="${1:-}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "${val}"
}

ci_deps_parse_alternative_candidates() {
  local spec="${1:-}"
  local cand=""
  local -a raw=()

  IFS='|' read -r -a raw <<< "${spec}"
  for cand in "${raw[@]}"; do
    cand="$(ci_deps_trim "${cand}")"
    [[ -n "${cand}" ]] && printf '%s\n' "${cand}"
  done
}

# Resolve alternative expressions (e.g. "pcre|pcre2") to a single package
# for list/check flows. This does not perform retries and is intentionally
# deterministic for print/check output.
ci_deps_resolve_package_alternatives() {
  local installed_fn="${1:-}"
  local available_fn="${2:-}"
  local spec=""
  local cand=""
  local first=""
  local chosen=""
  local -a resolved=()
  local -a candidates=()

  if [[ -z "${installed_fn}" ]]; then
    echo "Missing installed-check callback for alternative package resolution" >&2
    exit 2
  fi

  for spec in "${PKGS[@]}"; do
    if [[ "${spec}" != *"|"* ]]; then
      resolved+=("${spec}")
      continue
    fi

    candidates=()
    while IFS= read -r cand; do
      candidates+=("${cand}")
    done < <(ci_deps_parse_alternative_candidates "${spec}")

    first=""
    chosen=""

    for cand in "${candidates[@]}"; do
      if [[ -z "${first}" ]]; then
        first="${cand}"
      fi
      if "${installed_fn}" "${cand}"; then
        chosen="${cand}"
        break
      fi
    done

    if [[ -z "${chosen}" && -n "${available_fn}" ]]; then
      for cand in "${candidates[@]}"; do
        if "${available_fn}" "${cand}"; then
          chosen="${cand}"
          break
        fi
      done
    fi

    if [[ -z "${chosen}" ]]; then
      chosen="${first}"
    fi
    if [[ -z "${chosen}" ]]; then
      echo "Invalid alternative package expression: '${spec}'" >&2
      exit 2
    fi

    if [[ "${chosen}" != "${spec}" ]]; then
      echo "Resolved package alternative '${spec}' -> '${chosen}'" >&2
    fi
    resolved+=("${chosen}")
  done

  PKGS=("${resolved[@]}")
}

# Install packages with real fallback retries for alternative expressions.
# For "pkg1|pkg2", installation attempts pkg1 first, then pkg2, while
# honoring installed/available callbacks when provided.
ci_deps_install_packages_with_alternatives() {
  local installed_fn="${1:-}"
  local available_fn="${2:-}"
  local install_fn="${3:-}"
  local spec=""
  local pkg=""
  local success=0
  local -a candidates=()

  if [[ -z "${installed_fn}" ]]; then
    echo "Missing installed-check callback for alternative package install" >&2
    exit 2
  fi
  if [[ -z "${install_fn}" ]]; then
    echo "Missing install callback for alternative package install" >&2
    exit 2
  fi

  for spec in "${PKGS[@]}"; do
    if [[ "${spec}" != *"|"* ]]; then
      pkg="$(ci_deps_trim "${spec}")"
      [[ -z "${pkg}" ]] && continue
      if "${installed_fn}" "${pkg}"; then
        continue
      fi
      if "${install_fn}" "${pkg}"; then
        continue
      fi
      echo "Failed to install package '${pkg}'" >&2
      return 1
    fi

    candidates=()
    while IFS= read -r pkg; do
      candidates+=("${pkg}")
    done < <(ci_deps_parse_alternative_candidates "${spec}")

    success=0

    for pkg in "${candidates[@]}"; do
      if "${installed_fn}" "${pkg}"; then
        success=1
        break
      fi

      if [[ -n "${available_fn}" ]] && ! "${available_fn}" "${pkg}"; then
        echo "Alternative '${pkg}' is not available, trying next for '${spec}'"
        continue
      fi

      echo "Trying package alternative '${pkg}' for '${spec}'"
      if "${install_fn}" "${pkg}"; then
        success=1
        break
      fi

      echo "Install failed for alternative '${pkg}', trying next for '${spec}'"
    done

    if [[ "${success}" != "1" ]]; then
      echo "Failed to install any package alternative for '${spec}'" >&2
      return 1
    fi
  done
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

ci_deps_retry_command() {
  local retry_attempts="${CI_DEPS_RETRY_ATTEMPTS:-3}"
  local retry_sleep_secs="${CI_DEPS_RETRY_SLEEP_SECS:-5}"
  local retry_attempt=1
  local retry_rc=0

  if [[ "${retry_attempts}" -lt 1 ]]; then
    retry_attempts=1
  fi

  while true; do
    if "$@"; then
      return 0
    else
      retry_rc=$?
    fi
    if [[ "${retry_attempt}" -ge "${retry_attempts}" ]]; then
      return "${retry_rc}"
    fi
    echo "Command failed with exit ${retry_rc}; retrying (${retry_attempt}/${retry_attempts}) in ${retry_sleep_secs}s" >&2
    sleep "${retry_sleep_secs}"
    retry_attempt=$((retry_attempt + 1))
  done
}

ci_deps_apt_get() {
  local acquire_retries="${CI_DEPS_APT_ACQUIRE_RETRIES:-5}"

  ci_deps_retry_command \
    ci_deps_as_root env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    apt-get -o "Acquire::Retries=${acquire_retries}" "$@"
}

ci_deps_parse_os_release() {
  local os_release="/etc/os-release"
  local key=""
  local value=""

  CI_DEPS_OS_ID=""
  CI_DEPS_OS_VERSION_ID=""

  [[ -r "${os_release}" ]] || return 1

  while IFS='=' read -r key value; do
    case "${key}" in
      ID)
        value="${value%\"}"
        value="${value#\"}"
        CI_DEPS_OS_ID="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
        ;;
      VERSION_ID)
        value="${value%\"}"
        value="${value#\"}"
        CI_DEPS_OS_VERSION_ID="${value}"
        ;;
    esac
  done < "${os_release}"

  return 0
}

ci_deps_find_rocky_gpgkey() {
  local rocky_major="${1:-}"
  local rocky_gpgkey=""
  local first_match=""

  rocky_gpgkey="/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${rocky_major}"
  if [[ ! -r "${rocky_gpgkey}" ]]; then
    rocky_gpgkey="/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial"
  fi
  if [[ ! -r "${rocky_gpgkey}" ]]; then
    first_match="$(
      find /etc/pki/rpm-gpg -maxdepth 1 -type f -name 'RPM-GPG-KEY-Rocky-*' 2>/dev/null \
        | head -n 1 || true
    )"
    rocky_gpgkey="${first_match}"
  fi
  if [[ -z "${rocky_gpgkey}" || ! -r "${rocky_gpgkey}" ]]; then
    return 1
  fi

  printf '%s\n' "${rocky_gpgkey}"
}

ci_deps_install_rocky_fallback_repo() {
  local rocky_major="${1:-}"
  local rocky_gpgkey="${2:-}"
  local repo_dest="${3:-/etc/yum.repos.d/ci-rocky-fallback.repo}"
  local repo_file=""

  if [[ -z "${rocky_major}" || -z "${rocky_gpgkey}" ]]; then
    echo "Missing Rocky repo parameters (major/gpgkey)" >&2
    return 1
  fi

  repo_file="$(mktemp)"
  {
    printf '%s\n' '[ci-rocky-baseos]'
    printf '%s\n' 'name=CI Rocky BaseOS fallback mirrors'
    printf '%s\n' "baseurl=https://mirror.rackspace.com/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' "        https://mirror.math.princeton.edu/pub/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' "        https://mirrors.sonic.net/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' "        https://ftp.iij.ad.jp/pub/linux/rocky/${rocky_major}/BaseOS/\$basearch/os/"
    printf '%s\n' 'enabled=1'
    printf '%s\n' 'gpgcheck=1'
    printf '%s\n' "gpgkey=file://${rocky_gpgkey}"
    printf '%s\n' 'skip_if_unavailable=1'
    printf '\n'

    printf '%s\n' '[ci-rocky-appstream]'
    printf '%s\n' 'name=CI Rocky AppStream fallback mirrors'
    printf '%s\n' "baseurl=https://mirror.rackspace.com/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' "        https://mirror.math.princeton.edu/pub/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' "        https://mirrors.sonic.net/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' "        https://ftp.iij.ad.jp/pub/linux/rocky/${rocky_major}/AppStream/\$basearch/os/"
    printf '%s\n' 'enabled=1'
    printf '%s\n' 'gpgcheck=1'
    printf '%s\n' "gpgkey=file://${rocky_gpgkey}"
    printf '%s\n' 'skip_if_unavailable=1'
    printf '\n'

    printf '%s\n' '[ci-rocky-extras]'
    printf '%s\n' 'name=CI Rocky Extras fallback mirrors'
    printf '%s\n' "baseurl=https://mirror.rackspace.com/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' "        https://mirror.math.princeton.edu/pub/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' "        https://mirrors.sonic.net/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' "        https://ftp.iij.ad.jp/pub/linux/rocky/${rocky_major}/extras/\$basearch/os/"
    printf '%s\n' 'enabled=1'
    printf '%s\n' 'gpgcheck=1'
    printf '%s\n' "gpgkey=file://${rocky_gpgkey}"
    printf '%s\n' 'skip_if_unavailable=1'
  } > "${repo_file}"

  ci_deps_as_root install -m 0644 "${repo_file}" "${repo_dest}"
  rm -f "${repo_file}"
}

ci_deps_configure_rocky_fallback_repos() {
  local os_hint="${1:-}"
  local version_hint="${2:-}"
  local repo_dest="${3:-/etc/yum.repos.d/ci-rocky-fallback.repo}"
  local os_id="${os_hint}"
  local rocky_major="${version_hint}"
  local rocky_gpgkey=""

  os_id="$(printf '%s' "${os_id}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${os_id}" ]]; then
    ci_deps_parse_os_release || true
    os_id="${CI_DEPS_OS_ID:-}"
  fi
  case "${os_id}" in
    rocky|rockylinux)
      ;;
    *)
      return 1
      ;;
  esac

  if [[ -z "${rocky_major}" || "${rocky_major}" == "latest" ]]; then
    if [[ -z "${CI_DEPS_OS_VERSION_ID:-}" ]]; then
      ci_deps_parse_os_release || true
    fi
    rocky_major="${CI_DEPS_OS_VERSION_ID%%.*}"
  fi
  [[ -n "${rocky_major}" ]] || rocky_major="8"

  rocky_gpgkey="$(ci_deps_find_rocky_gpgkey "${rocky_major}")" || {
    echo "Unable to locate Rocky Linux RPM GPG key in /etc/pki/rpm-gpg" >&2
    return 1
  }

  ci_deps_install_rocky_fallback_repo "${rocky_major}" "${rocky_gpgkey}" "${repo_dest}"
}

ci_deps_install_centos7_vault_repo() {
  local repo_dest="${1:-/etc/yum.repos.d/centos7-vault.repo}"
  local repo_file=""

  repo_file="$(mktemp)"
  cat > "${repo_file}" <<'EOF'
[centos7-vault-base]
name=CentOS 7 Vault Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
enabled=1
gpgcheck=0

[centos7-vault-updates]
name=CentOS 7 Vault Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
enabled=1
gpgcheck=0

[centos7-vault-extras]
name=CentOS 7 Vault Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
enabled=1
gpgcheck=0
EOF

  ci_deps_as_root install -m 0644 "${repo_file}" "${repo_dest}"
  rm -f "${repo_file}"
}
