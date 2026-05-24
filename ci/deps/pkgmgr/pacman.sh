pkg_installed() {
  pacman -Q "$1" >/dev/null 2>&1
}

pkg_available() {
  pacman -Si "$1" >/dev/null 2>&1
}

pkg_install_one() {
  ci_deps_as_root pacman -S --noconfirm --needed "$1"
}

pkg_pre_install() {
  # Refresh metadata and the signing keyring (Arch disallows partial upgrades).
  ci_deps_as_root pacman -Sy --noconfirm archlinux-keyring
  ci_deps_as_root pacman -Syu --noconfirm
}
