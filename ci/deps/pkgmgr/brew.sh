pkg_installed() {
  brew list --versions "$1" >/dev/null 2>&1
}

pkg_available() {
  brew info --formula "$1" >/dev/null 2>&1
}

pkg_install_one() {
  brew install "$1"
}

pkg_pre_install() {
  echo "=== Install (Homebrew packages) ==="
  brew update
}
