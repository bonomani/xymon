pkg_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

pkg_available() {
  zypper --non-interactive info "$1" >/dev/null 2>&1
}

pkg_install_one() {
  ci_deps_as_root zypper --non-interactive install "$1"
}

pkg_pre_install() {
  echo "=== Install (Linux packages) ==="
  ci_deps_as_root zypper --non-interactive refresh
}
