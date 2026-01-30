#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

echo "=== Install (Linux packages) ==="

PROFILE="${1:-default}"
if [[ "${PROFILE}" == "linux" ]]; then
  PROFILE="debian"
fi
ENABLE_LDAP="${ENABLE_LDAP:-ON}"
VARIANT="${VARIANT:-all}"
CI_COMPILER="${CI_COMPILER:-}"

sudo apt-get update

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=packages-linux.sh
source "${script_dir}/packages-linux.sh"

mapfile -t ALL_PKGS < <(ci_linux_packages "debian" "ubuntu" "latest" "${VARIANT}" "${ENABLE_LDAP}" "${CI_COMPILER}")

sudo apt-get install -y --no-install-recommends \
  "${ALL_PKGS[@]}"
