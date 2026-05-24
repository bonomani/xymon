#!/usr/bin/env bash
set -euo pipefail

BSD_DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bsd_sort_versions() {
  if sort -V </dev/null >/dev/null 2>&1; then
    sort -V
  else
    sort
  fi
}

bsd_normalize_os_name() {
  local os_input="${1:-}"
  local lowered
  lowered="$(printf '%s' "${os_input}" | tr '[:upper:]' '[:lower:]')"

  # shellcheck disable=SC2034
  case "${lowered}" in
    freebsd)
      BSD_OS_NAME="FreeBSD"
      BSD_OS_LOWER="freebsd"
      ;;
    netbsd)
      BSD_OS_NAME="NetBSD"
      BSD_OS_LOWER="netbsd"
      ;;
    openbsd)
      BSD_OS_NAME="OpenBSD"
      BSD_OS_LOWER="openbsd"
      ;;
    *)
      echo "Unsupported BSD OS: ${os_input}" >&2
      return 1
      ;;
  esac
}

bsd_init_os_context() {
  local os_input="${1:-$(uname -s)}"
  local version_input="${2:-}"

  bsd_normalize_os_name "${os_input}"
  BSD_OS_VERSION="${version_input:-$(uname -r)}"
  OS_VERSION="${BSD_OS_VERSION}"
  export OS_VERSION
}

bsd_default_pkgmgr_for_os() {
  local os_lower="${1:-}"
  case "${os_lower}" in
    freebsd) echo "pkg" ;;
    netbsd) echo "pkg_add" ;;
    openbsd) echo "pkg_add" ;;
    *) return 1 ;;
  esac
}

bsd_require_os_for_pkgmgr() {
  local pkgmgr="${1:-}"
  case "${pkgmgr}" in
    pkg)
      [[ "${BSD_OS_LOWER}" == "freebsd" ]] || {
        echo "pkg installer supports FreeBSD only (got ${BSD_OS_LOWER})" >&2
        return 1
      }
      ;;
    pkg_add)
      [[ "${BSD_OS_LOWER}" == "netbsd" || "${BSD_OS_LOWER}" == "openbsd" ]] || {
        echo "pkg_add installer supports NetBSD/OpenBSD only (got ${BSD_OS_LOWER})" >&2
        return 1
      }
      ;;
    pkgin)
      [[ "${BSD_OS_LOWER}" == "netbsd" ]] || {
        echo "pkgin installer supports NetBSD only (got ${BSD_OS_LOWER})" >&2
        return 1
      }
      ;;
    *)
      echo "Unsupported BSD package manager: ${pkgmgr}" >&2
      return 1
      ;;
  esac
}

bsd_pick_openldap_variant() {
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

bsd_pick_openldap_variant_from_pkg_add_probe() {
  local probe_file="${1:-}"
  local ambiguous=""

  if [[ -z "${probe_file}" || ! -f "${probe_file}" ]]; then
    return 1
  fi

  ambiguous="$(
    sed -n 's/^Ambiguous:[[:space:]]*//p' "${probe_file}" \
      | head -n 1 || true
  )"
  if [[ -z "${ambiguous}" ]]; then
    return 1
  fi

  bsd_pick_openldap_variant "${ambiguous}"
}

bsd_pick_ldap_pkg() {
  local pkgmgr="${1:-}"
  local found=""
  local probe_file=""
  local probe_rc=0

  case "${pkgmgr}" in
    pkg)
      if [ -x /usr/sbin/pkg ]; then
        found="$(
          /usr/sbin/pkg search -q '^openldap.*client' 2>/dev/null \
            | sed 's/-[0-9].*$//' \
            | bsd_sort_versions \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkgin)
      if [ -x /usr/pkg/bin/pkgin ]; then
        found="$(
          /usr/pkg/bin/pkgin search '^openldap.*-client' 2>/dev/null \
            | awk '{print $1}' \
            | sed 's/-[0-9].*$//' \
            | bsd_sort_versions \
            | tail -n 1 || true
        )"
      fi
      ;;
    pkg_add)
      if [ -x /usr/sbin/pkg_add ]; then
        probe_file="$(mktemp -t install-bsd-openldap.XXXXXX || true)"
        if [[ -n "${probe_file}" ]]; then
          set +e
          /usr/sbin/pkg_add -n openldap-client >"${probe_file}" 2>&1
          probe_rc=$?
          set -e

          if [[ "${probe_rc}" -eq 0 ]]; then
            found="openldap-client"
          else
            found="$(bsd_pick_openldap_variant_from_pkg_add_probe "${probe_file}")" || true
          fi

          rm -f "${probe_file}"
        elif /usr/sbin/pkg_add -n openldap-client >/dev/null 2>&1; then
          found="openldap-client"
        fi
      fi
      ;;
  esac

  if [[ -n "${found}" ]]; then
    echo "${found}"
  fi
}

bsd_pick_pkg_add_variant() {
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
        | bsd_sort_versions \
        | tail -n 1 || true
    )"
    if [[ -n "${picked}" ]]; then
      echo "${picked}"
      return 0
    fi
  fi

  return 1
}

bsd_pick_pkg_add_alternative_for_probe() {
  local spec="${1:-}"
  local cand=""
  local first=""
  local chosen=""
  local -a candidates=()

  if [[ "${spec}" != *"|"* ]]; then
    printf '%s' "${spec}"
    return 0
  fi

  while IFS= read -r cand; do
    candidates+=("${cand}")
  done < <(ci_deps_parse_alternative_candidates "${spec}")

  for cand in "${candidates[@]}"; do
    if [[ -z "${first}" ]]; then
      first="${cand}"
    fi
    if bsd_pkg_installed pkg_add "${cand}"; then
      chosen="${cand}"
      break
    fi
  done

  if [[ -z "${chosen}" ]]; then
    for cand in "${candidates[@]}"; do
      if bsd_pkg_available pkg_add "${cand}"; then
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
    return 1
  fi

  printf '%s' "${chosen}"
}

bsd_resolve_pkg_add_variants() {
  local resolved=()
  local spec=""
  local probe_pkg=""
  local resolved_pkg=""
  local picked=""
  declare -A pkg_add_cache

  for spec in "${PKGS[@]}"; do
    probe_pkg="${spec}"
    resolved_pkg="${spec}"

    if [[ "${spec}" == *"|"* ]]; then
      if [[ "${mode:-install}" != "install" ]]; then
        probe_pkg="$(bsd_pick_pkg_add_alternative_for_probe "${spec}")"
        resolved_pkg="${probe_pkg}"
      else
        # Preserve alternatives in install mode so install fallback can try each candidate.
        resolved+=("${resolved_pkg}")
        continue
      fi
    fi

    if [[ -n "${pkg_add_cache[${probe_pkg}]:-}" ]]; then
      picked="${pkg_add_cache[${probe_pkg}]}"
    else
      picked="$(bsd_pick_pkg_add_variant "${probe_pkg}")" || true
      pkg_add_cache["${probe_pkg}"]="${picked}"
    fi

    if [[ -n "${picked}" ]]; then
      resolved+=("${picked}")
    else
      resolved+=("${resolved_pkg}")
    fi
  done

  PKGS=("${resolved[@]}")
}

bsd_resolve_packages() {
  local pkgmgr="${1:-}"
  local yaml_pkgmgr="${2:-${pkgmgr}}"
  local packages_output=""
  local -a resolver_args=()

  resolver_args=(
    --variant "${DEPS_VARIANT}"
    --family bsd
    --os "${BSD_OS_LOWER}"
    --pkgmgr "${yaml_pkgmgr}"
    --enable-snmp "${ENABLE_SNMP}"
  )
  if [[ -n "${build_tool:-}" ]]; then
    resolver_args+=(--build-tool "${build_tool}")
  fi

  packages_output="$("${BSD_DEPS_DIR}/packages-from-yaml.sh" "${resolver_args[@]}")"

  PKGS=()
  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] && PKGS+=("${pkg}")
  done <<< "${packages_output}"

  if [[ "${#PKGS[@]}" -eq 0 ]]; then
    echo "No packages resolved for variant=${DEPS_VARIANT} family=bsd os=${BSD_OS_LOWER} pkgmgr=${yaml_pkgmgr}" >&2
    return 1
  fi

  if [[ "${ENABLE_LDAP}" == "ON" && "${DEPS_VARIANT}" == "server" ]]; then
    LDAP_PKG="$(bsd_pick_ldap_pkg "${pkgmgr}")"
    if [[ -n "${LDAP_PKG}" ]]; then
      PKGS+=("${LDAP_PKG}")
    fi
  fi

  if [[ "${pkgmgr}" == "pkg_add" ]]; then
    bsd_resolve_pkg_add_variants
  fi
}

bsd_pkg_installed() {
  local pkgmgr="${1:-}"
  local pkg="${2:-}"
  case "${pkgmgr}" in
    pkg)
      /usr/sbin/pkg info -e "${pkg}" >/dev/null 2>&1
      ;;
    pkgin)
      /usr/pkg/bin/pkg_info -e "${pkg}" >/dev/null 2>&1
      ;;
    pkg_add)
      /usr/sbin/pkg_info -e "${pkg}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

bsd_pkg_available() {
  local pkgmgr="${1:-}"
  local pkg="${2:-}"
  case "${pkgmgr}" in
    pkg)
      /usr/sbin/pkg search -q "^${pkg}(-|$)" >/dev/null 2>&1
      ;;
    pkgin)
      /usr/pkg/bin/pkgin search "^${pkg}(-|$)" 2>/dev/null | grep -q .
      ;;
    pkg_add)
      /usr/sbin/pkg_add -n "${pkg}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

bsd_prepare_netbsd_pkg_environment() {
  local netbsd_arch=""
  local netbsd_pkg_ver=""
  local arch_try=""
  local url=""
  local -a arch_candidates=()
  local -a mirror_bases=(
    "https://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD"
    "https://ftp.netbsd.org/pub/pkgsrc/packages/NetBSD"
    "http://cdn.netbsd.org/pub/pkgsrc/packages/NetBSD"
  )
  declare -A seen_paths=()

  NETBSD_PKG_PATHS=()
  netbsd_arch="$(uname -m)"
  netbsd_pkg_ver="${BSD_OS_VERSION%%_*}"
  netbsd_pkg_ver="${netbsd_pkg_ver%%-*}"
  netbsd_pkg_ver="$(printf '%s' "${netbsd_pkg_ver}" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
  if [[ -z "${netbsd_pkg_ver}" ]]; then
    netbsd_pkg_ver="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
  fi

  case "${netbsd_arch}" in
    amd64|x86_64)
      arch_candidates=(amd64 x86_64)
      ;;
    evbarm|evbarm64|aarch64|arm64)
      # arm64 VMs may report evbarm while pkgsrc binary sets live under aarch64.
      arch_candidates=(aarch64 evbarm arm64 earmv7hf earmv6hf)
      ;;
    *)
      arch_candidates=("${netbsd_arch}")
      ;;
  esac

  for arch_try in "${arch_candidates[@]}"; do
    for url in "${mirror_bases[@]}"; do
      url="${url}/${arch_try}/${netbsd_pkg_ver}/All/"
      if [[ -z "${seen_paths[${url}]:-}" ]]; then
        NETBSD_PKG_PATHS+=("${url}")
        seen_paths["${url}"]=1
      fi
    done
  done

  export CHECK_OSABI=no
  PKG_INSTALL_CONF="/tmp/pkg_install.conf"
  printf "%s\n" "CHECK_OSABI=no" > "${PKG_INSTALL_CONF}" 2>/dev/null || true
  export PKG_INSTALL_CONF
  export PKG_PATH="${NETBSD_PKG_PATHS[0]}"

  # Strip the trailing slash: pkgin appends "/pkg_summary.*" itself, and the
  # standard repositories.conf form ends at ".../All" (no trailing slash).
  ci_deps_as_root sh -c "printf '%s\n' '${NETBSD_PKG_PATHS[0]%/}' > /usr/pkg/etc/pkgin/repositories.conf" || true
}

bsd_openbsd_post_install_gcc_link() {
  local need_gcc=0
  local gcc_pkg=""
  local gcc_bin=""

  for pkg in "$@"; do
    if [[ "${pkg}" == gcc* ]]; then
      need_gcc=1
      gcc_pkg="${pkg}"
      break
    fi
  done

  if [[ "${need_gcc}" != "1" || -e /usr/local/bin/gcc ]]; then
    return 0
  fi

  if [[ -n "${gcc_pkg}" ]]; then
    gcc_bin="$(/usr/sbin/pkg_info -L "${gcc_pkg}" 2>/dev/null | grep -E '/(egcc|gcc)$' | head -n 1 || true)"
    if [[ -z "${gcc_bin}" ]]; then
      gcc_bin="$(/usr/sbin/pkg_info -L "${gcc_pkg}" 2>/dev/null | grep -E '/gcc-[0-9]+' | bsd_sort_versions | tail -n 1 || true)"
    fi
  fi

  if [[ -z "${gcc_bin}" ]]; then
    gcc_bin="$(ls /usr/local/bin/gcc-[0-9]* /usr/local/bin/egcc* 2>/dev/null | bsd_sort_versions | tail -n 1 || true)"
  fi

  if [[ -n "${gcc_bin}" ]]; then
    ci_deps_as_root ln -s "${gcc_bin}" /usr/local/bin/gcc
  fi
}

bsd_install_pkg_add() {
  local install_ok=0

  if [[ "${BSD_OS_LOWER}" == "netbsd" ]]; then
    bsd_prepare_netbsd_pkg_environment
    for pkg_path_try in "${NETBSD_PKG_PATHS[@]}"; do
      echo "NetBSD pkg_add install using PKG_PATH=${pkg_path_try}"
      if ci_deps_as_root env PKG_PATH="${pkg_path_try}" /usr/sbin/pkg_add -I "${PKGS[@]}"; then
        export PKG_PATH="${pkg_path_try}"
        install_ok=1
        break
      fi
      echo "pkg_add failed for PKG_PATH=${pkg_path_try}, trying next mirror if available"
    done
    if [[ "${install_ok}" != "1" ]]; then
      echo "pkg_add failed on all configured NetBSD package mirrors" >&2
      return 1
    fi
  else
    ci_deps_as_root /usr/sbin/pkg_add -I "${PKGS[@]}"
  fi

  if [[ "${BSD_OS_LOWER}" == "openbsd" ]]; then
    bsd_openbsd_post_install_gcc_link "${PKGS[@]}"
  fi
}

# pkgin >= 23.12 verifies TLS certificates. NetBSD 10 ships a CA trust store
# (certctl + bundled Mozilla certs); NetBSD 9.x does not, so https to
# cdn.netbsd.org fails certificate verification there. When no trust store is
# present, install mozilla-rootcerts-openssl, which populates /etc/openssl/certs
# (where NetBSD's OpenSSL/libfetch look). Install it WITHOUT -I so its setup
# script runs, and via pkg_add -- which does not verify TLS, so it can fetch
# over the https mirror before a trust store exists (chicken-and-egg).
bsd_netbsd_ensure_ca_certs() {
  local pkg_path_try=""

  if [ -n "$(ls -A /etc/openssl/certs 2>/dev/null)" ]; then
    return 0
  fi

  echo "No CA trust store found; installing mozilla-rootcerts-openssl via pkg_add"
  for pkg_path_try in "${NETBSD_PKG_PATHS[@]}"; do
    if ci_deps_as_root env PKG_PATH="${pkg_path_try}" \
        /usr/sbin/pkg_add mozilla-rootcerts-openssl; then
      return 0
    fi
    echo "CA cert install failed for PKG_PATH=${pkg_path_try}, trying next mirror"
  done
  echo "failed to install CA certificates from all mirrors" >&2
  return 1
}

# One-time setup before per-package pkgin installs (use as a pre_install hook).
# Ensures the pkgsrc repo config, a CA trust store (so pkgin can verify https),
# and the pkgin binary exist, then refreshes repository metadata so dependency
# upgrades (e.g. a stale sqlite3) resolve against the current binary set. pkgin
# ships in pkgsrc (/usr/pkg), not the base system, so bootstrap it via pkg_add
# if the VM image doesn't already provide it.
bsd_pkgin_prepare() {
  local -a saved_pkgs=()
  if [[ "${BSD_OS_LOWER}" == "netbsd" ]]; then
    bsd_prepare_netbsd_pkg_environment
    bsd_netbsd_ensure_ca_certs || return 1
    if [[ ! -x /usr/pkg/bin/pkgin ]]; then
      echo "pkgin not present; bootstrapping it via pkg_add"
      saved_pkgs=("${PKGS[@]}")
      PKGS=(pkgin)
      if ! bsd_install_pkg_add; then
        PKGS=("${saved_pkgs[@]}")
        echo "failed to bootstrap pkgin via pkg_add" >&2
        return 1
      fi
      PKGS=("${saved_pkgs[@]}")
    fi
  fi
  ci_deps_as_root /usr/pkg/bin/pkgin -y update
}
