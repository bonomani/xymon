#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" || -n "${DEBUG:-}" ]] && set -x

usage() {
  cat <<'USAGE'
Usage: install-bsd-packages.sh [--print] [--check-only] [--install]
                             [--os NAME] [--version NAME]

Options:
  --print          Print package list and exit
  --check-only     Exit 0 if all packages are installed, 1 otherwise
  --install        Install packages (default)
  --os       Override OS (default: detected)
  --version  Override version (default: detected)
USAGE
}

mode="install"
print_list="0"
os_override=""
version_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)
      print_list="1"
      if [[ "${mode}" == "install" ]]; then
        mode="print"
      fi
      shift
      ;;
    --check-only) mode="check"; shift ;;
    --install) mode="install"; shift ;;
    --os) os_override="$2"; shift 2 ;;
    --version) version_override="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

VARIANT="${VARIANT:-}"
ENABLE_LDAP="${ENABLE_LDAP:-}"
ENABLE_SNMP="${ENABLE_SNMP:-}"
if [[ -z "${VARIANT}" || -z "${ENABLE_LDAP}" || -z "${ENABLE_SNMP}" ]]; then
  echo "VARIANT, ENABLE_LDAP, and ENABLE_SNMP must be set"
  exit 1
fi
case "${VARIANT}" in
  server|client|localclient)
    DEPS_VARIANT="${VARIANT}"
    ;;
  *)
    echo "Unknown VARIANT: ${VARIANT}"
    exit 1
    ;;
esac

OS_NAME_RAW="${os_override:-$(uname -s)}"
OS_NAME_LOWER="$(printf '%s' "${OS_NAME_RAW}" | tr '[:upper:]' '[:lower:]')"
case "${OS_NAME_LOWER}" in
  freebsd) OS_NAME="FreeBSD" ;;
  netbsd) OS_NAME="NetBSD" ;;
  openbsd) OS_NAME="OpenBSD" ;;
  *) OS_NAME="${OS_NAME_RAW}" ;;
esac
echo "Normalized BSD OS_NAME override: requested='${OS_NAME_RAW}' resolved='${OS_NAME}'"
OS_VERSION="${version_override:-$(uname -r)}"
export OS_VERSION
echo "$(uname -a)"
echo "=== Install (BSD packages) ==="

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packages-bsd.sh
source "${script_dir}/packages-bsd.sh"

PKG_MGR=""
NETBSD_PKG_PATHS=()
case "${OS_NAME}" in
  FreeBSD) PKG_MGR="pkg" ;;
  NetBSD) PKG_MGR="pkg_add" ;;
  OpenBSD) PKG_MGR="pkg_add" ;;
  *)
    echo "Unsupported BSD OS: ${OS_NAME}"
    exit 1
    ;;
esac

# NetBSD CI runners may have OSABI mismatches; allow pkgin/pkg_add to proceed.
if [[ "${OS_NAME}" == "NetBSD" ]]; then
  netbsd_arch="$(uname -m)"
  netbsd_pkg_ver="${OS_VERSION%%_*}"
  netbsd_pkg_ver="${netbsd_pkg_ver%%-*}"
  netbsd_pkg_ver="$(printf '%s' "${netbsd_pkg_ver}" | sed -E 's/^([0-9]+\\.[0-9]+).*/\\1/')"
  if [[ -z "${netbsd_pkg_ver}" ]]; then
    netbsd_pkg_ver="$(uname -r | sed -E 's/^([0-9]+\\.[0-9]+).*/\\1/')"
  fi
  netbsd_pkg_path_primary="https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/${netbsd_arch}/${netbsd_pkg_ver}/All/"
  netbsd_pkg_path_fallback1="https://ftp.netbsd.org/pub/pkgsrc/packages/NetBSD/${netbsd_arch}/${netbsd_pkg_ver}/All/"
  netbsd_pkg_path_fallback2="http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD/${netbsd_arch}/${netbsd_pkg_ver}/All/"
  NETBSD_PKG_PATHS=(
    "${netbsd_pkg_path_primary}"
    "${netbsd_pkg_path_fallback1}"
    "${netbsd_pkg_path_fallback2}"
  )

  export CHECK_OSABI=no
  PKG_INSTALL_CONF="/tmp/pkg_install.conf"
  printf "%s\n" "CHECK_OSABI=no" > "${PKG_INSTALL_CONF}" 2>/dev/null || true
  export PKG_INSTALL_CONF
  export PKG_PATH="${NETBSD_PKG_PATHS[0]}"
  if [ -x /usr/bin/sudo ]; then
    sudo sh -c "printf '%s\n' '${NETBSD_PKG_PATHS[0]}' > /usr/pkg/etc/pkgin/repositories.conf"
  fi
fi

pick_ldap_pkg() {
  local pkgmgr="${1:-}"
  local found=""
  local probe_out=""

  normalize_pkg_name() {
    sed 's/-[0-9].*$//'
  }

  sort_versions() {
    if sort -V </dev/null >/dev/null 2>&1; then
      sort -V
    else
      sort
    fi
  }

  pick_openldap_variant() {
    local ambiguous="${1:-}"
    local picked=""

    picked="$(
      echo "${ambiguous}" \
        | tr ' ' '\n' \
        | grep '^openldap-client-' \
        | grep -v 'gssapi' \
        | head -n 1 || true
    )"
    if [[ -z "${picked}" ]]; then
      picked="$(
        echo "${ambiguous}" \
          | tr ' ' '\n' \
          | grep '^openldap-client-' \
          | head -n 1 || true
      )"
    fi

    echo "${picked}"
  }

  case "${pkgmgr}" in
    pkg)
      if [ -x /usr/sbin/pkg ]; then
        found="$(
          /usr/sbin/pkg search -q '^openldap.*client' 2>/dev/null \
            | normalize_pkg_name \
            | sort_versions \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkgin)
      if [ -x /usr/pkg/bin/pkgin ]; then
        found="$(
          /usr/pkg/bin/pkgin search '^openldap.*-client' 2>/dev/null \
            | awk '{print $1}' \
            | normalize_pkg_name \
            | sort_versions \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkg_add)
      if [ -x /usr/sbin/pkg_add ]; then
        set +e
        probe_out="$(/usr/sbin/pkg_add -n openldap-client 2>&1)"
        set -e
        if echo "${probe_out}" | grep -q '^Ambiguous:'; then
          found="$(pick_openldap_variant "${probe_out}")"
        elif /usr/sbin/pkg_add -n openldap-client >/dev/null 2>&1; then
          found="openldap-client"
        fi
      fi
      ;;
  esac

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi
}

pick_pkg_add_variant() {
  local base="${1:-}"
  local probe_out=""
  local picked=""

  if [ -z "${base}" ] || [ ! -x /usr/sbin/pkg_add ]; then
    return 1
  fi

  set +e
  probe_out="$(/usr/sbin/pkg_add -n "${base}" 2>&1)"
  set -e

  if echo "${probe_out}" | grep -q '^Ambiguous:'; then
    picked="$(
      echo "${probe_out}" \
        | tr ' ' '\n' \
        | grep "^${base}-" \
        | sort -V \
        | tail -n 1 || true
    )"
    if [[ -n "${picked}" ]]; then
      echo "${picked}"
      return 0
    fi
  fi

  return 1
}

active_pkgs_output="$(ci_bsd_packages "${PKG_MGR}" "${DEPS_VARIANT}" "${ENABLE_SNMP}")"
ACTIVE_PKGS=()
while IFS= read -r pkg; do
  [[ -n "${pkg}" ]] && ACTIVE_PKGS+=("${pkg}")
done <<< "${active_pkgs_output}"
if [[ "${#ACTIVE_PKGS[@]}" -eq 0 ]]; then
  echo "No packages resolved for variant=${DEPS_VARIANT} family=bsd os=${OS_NAME_LOWER} pkgmgr=${PKG_MGR}" >&2
  exit 1
fi

if [[ "${ENABLE_LDAP}" == "ON" && "${DEPS_VARIANT}" == "server" ]]; then
  LDAP_PKG="$(pick_ldap_pkg "${PKG_MGR}")"
  if [[ -n "${LDAP_PKG}" ]]; then
    ACTIVE_PKGS+=("${LDAP_PKG}")
  fi
fi

if [[ "${PKG_MGR}" == "pkg_add" ]]; then
  resolved=()
  declare -A pkg_add_cache
  for pkg in "${ACTIVE_PKGS[@]}"; do
    if [[ -n "${pkg_add_cache[${pkg}]:-}" ]]; then
      picked="${pkg_add_cache[${pkg}]}"
    else
      picked="$(pick_pkg_add_variant "${pkg}")" || true
      pkg_add_cache["${pkg}"]="${picked}"
    fi
    if [[ -n "${picked}" ]]; then
      resolved+=("${picked}")
    else
      resolved+=("${pkg}")
    fi
  done
  ACTIVE_PKGS=("${resolved[@]}")
fi

case "${mode}" in
  print)
    printf '%s\n' "${ACTIVE_PKGS[@]}"
    exit 0
    ;;
  check)
    case "${PKG_MGR}" in
      pkg)
        missing=0
        missing_pkgs=()
        for pkg in "${ACTIVE_PKGS[@]}"; do
          if ! /usr/sbin/pkg info -e "${pkg}" >/dev/null 2>&1; then
            missing=1
            missing_pkgs+=("${pkg}")
          fi
        done
        if [[ "${print_list}" == "1" && "${missing}" == "1" ]]; then
          printf '%s\n' "${missing_pkgs[@]}"
        fi
        exit "${missing}"
        ;;
      pkgin)
        missing=0
        missing_pkgs=()
        for pkg in "${ACTIVE_PKGS[@]}"; do
          if ! /usr/pkg/bin/pkg_info -e "${pkg}" >/dev/null 2>&1; then
            missing=1
            missing_pkgs+=("${pkg}")
          fi
        done
        if [[ "${print_list}" == "1" && "${missing}" == "1" ]]; then
          printf '%s\n' "${missing_pkgs[@]}"
        fi
        exit "${missing}"
        ;;
      pkg_add)
        missing=0
        missing_pkgs=()
        for pkg in "${ACTIVE_PKGS[@]}"; do
          if ! /usr/sbin/pkg_info -e "${pkg}" >/dev/null 2>&1; then
            missing=1
            missing_pkgs+=("${pkg}")
          fi
        done
        if [[ "${print_list}" == "1" && "${missing}" == "1" ]]; then
          printf '%s\n' "${missing_pkgs[@]}"
        fi
        exit "${missing}"
        ;;
    esac
    ;;
  install)
    if [[ "${print_list}" == "1" ]]; then
      printf '%s\n' "${ACTIVE_PKGS[@]}"
    fi
    case "${PKG_MGR}" in
      pkg)
        sudo -E ASSUME_ALWAYS_YES=YES pkg install "${ACTIVE_PKGS[@]}"
        exit 0
        ;;
      pkgin)
        sudo -E /usr/pkg/bin/pkgin -y install "${ACTIVE_PKGS[@]}"
        exit 0
        ;;
      pkg_add)
        if [[ "${OS_NAME}" == "NetBSD" && "${#NETBSD_PKG_PATHS[@]}" -gt 0 ]]; then
          install_ok=0
          for pkg_path_try in "${NETBSD_PKG_PATHS[@]}"; do
            echo "NetBSD pkg_add install using PKG_PATH=${pkg_path_try}"
            if sudo -E PKG_PATH="${pkg_path_try}" /usr/sbin/pkg_add -I "${ACTIVE_PKGS[@]}"; then
              export PKG_PATH="${pkg_path_try}"
              install_ok=1
              break
            fi
            echo "pkg_add failed for PKG_PATH=${pkg_path_try}, trying next mirror if available"
          done
          if [[ "${install_ok}" != "1" ]]; then
            echo "pkg_add failed on all configured NetBSD package mirrors" >&2
            exit 1
          fi
        else
          sudo -E /usr/sbin/pkg_add -I "${ACTIVE_PKGS[@]}"
        fi
        if [[ "${OS_NAME}" == "OpenBSD" ]]; then
          need_gcc=0
          gcc_pkg=""
          for pkg in "${ACTIVE_PKGS[@]}"; do
            if [[ "${pkg}" == gcc* ]]; then
              need_gcc=1
              gcc_pkg="${pkg}"
              break
            fi
          done
          if [[ "${need_gcc}" == "1" && ! -e /usr/local/bin/gcc ]]; then
            gcc_bin=""
            if [[ -n "${gcc_pkg}" ]]; then
              gcc_bin="$(/usr/sbin/pkg_info -L "${gcc_pkg}" 2>/dev/null | grep -E '/(egcc|gcc)$' | head -n 1 || true)"
              if [[ -z "${gcc_bin}" ]]; then
                gcc_bin="$(/usr/sbin/pkg_info -L "${gcc_pkg}" 2>/dev/null | grep -E '/gcc-[0-9]+' | sort -V | tail -n 1 || true)"
              fi
            fi
            if [[ -z "${gcc_bin}" ]]; then
              gcc_bin="$(ls /usr/local/bin/gcc-[0-9]* /usr/local/bin/egcc* 2>/dev/null | sort -V | tail -n 1 || true)"
            fi
            if [[ -n "${gcc_bin}" ]]; then
              sudo -E ln -s "${gcc_bin}" /usr/local/bin/gcc
            fi
          fi
        fi
        exit 0
        ;;
    esac
    ;;
  *)
    usage
    exit 1
    ;;
esac

echo "No supported package manager found"
exit 1
