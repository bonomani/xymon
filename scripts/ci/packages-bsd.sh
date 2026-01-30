#!/usr/bin/env bash
set -euo pipefail

# Common package names by BSD package manager (LDAP resolved separately).
ci_bsd_packages() {
  local pkgmgr="$1"
  local variant="$2"

  local common=(gmake cmake pcre)
  local server_pkg=(c-ares)
  local server_pkgin=(libcares)
  local server_pkg_add=(libcares)

  case "${pkgmgr}" in
    pkg)
      printf '%s\n' "${common[@]}" $( [[ "${variant}" == "server" ]] && printf '%s\n' "${server_pkg[@]}" )
      ;;
    pkgin)
      printf '%s\n' "${common[@]}" $( [[ "${variant}" == "server" ]] && printf '%s\n' "${server_pkgin[@]}" )
      ;;
    pkg_add)
      printf '%s\n' "${common[@]}" $( [[ "${variant}" == "server" ]] && printf '%s\n' "${server_pkg_add[@]}" )
      ;;
    *)
      printf '%s\n' "${common[@]}"
      ;;
  esac
}
