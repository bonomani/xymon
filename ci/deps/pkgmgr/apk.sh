pkg_installed() {
  apk info -e "$1" >/dev/null 2>&1
}

pkg_available() {
  apk search -x "$1" >/dev/null 2>&1
}

pkg_install_one() {
  ci_deps_as_root apk add --no-cache "$1"
}

pkg_pre_install() {
  echo "=== Install (Linux packages) ==="
}
