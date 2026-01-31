#!/usr/bin/env bash
set -euo pipefail

# Common package names by BSD package manager (LDAP resolved separately).
ci_bsd_packages() {
  local pkgmgr="$1"
  local variant="$2"
  local enable_snmp="${3:-}"
  local os_name="${4:-${OS_NAME:-}}"

  if [[ -z "${os_name}" ]]; then
    echo "OS_NAME is required for BSD package lookup" >&2
    return 1
  fi
  os_name="$(printf '%s' "${os_name}" | tr '[:upper:]' '[:lower:]')"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "${script_dir}/packages-from-yaml.sh" \
    --variant "${variant}" \
    --family bsd \
    --os "${os_name}" \
    --pkgmgr "${pkgmgr}" \
    --enable-snmp "${enable_snmp}"
}
