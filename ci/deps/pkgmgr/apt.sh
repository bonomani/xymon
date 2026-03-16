pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

pkg_available() {
  local candidate
  candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')"
  [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
}

pkg_install_one() {
  ci_deps_apt_get install -y --no-install-recommends "$1"
}

pkg_pre_install() {
  echo "=== Install (Linux packages) ==="
  ci_deps_apt_get update
}
