#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/package/common.sh
source "${SCRIPT_DIR}/common.sh"

package_parse_release_args "$@"
package_require_tools docker git tar id sha256sum

release_version="${PACKAGE_RELEASE_VERSION}"
repo_root="$(package_repo_root)"
output_root="${repo_root}/pkgbuild/archlinux"
work_root="${repo_root}/pkgbuild/.archlinux-work"
source_prefix="xymon-${release_version}"
archive_name="${source_prefix}.tar.gz"
host_uid="$(id -u)"
host_gid="$(id -g)"

package_prepare_clean_dir "${output_root}"
package_prepare_clean_dir "${work_root}"
package_git_archive_to_file "${repo_root}" "${source_prefix}" "${work_root}/${archive_name}"

mapfile -t resolved_packages < <(
  package_resolve_model_packages "${repo_root}" arch archlinux_latest pacman \
    | package_pick_primary_alternatives \
    | package_unique_lines
)

runtime_packages=()
makedepends=()
for package_name in "${resolved_packages[@]}"; do
  [[ -n "${package_name}" ]] || continue
  makedepends+=("${package_name}")
  case "${package_name}" in
    base-devel|git|findutils|diffutils|ninja)
      ;;
    *)
      runtime_packages+=("${package_name}")
      ;;
  esac
done

depends_literal="$(package_parenthesized_words "${runtime_packages[@]}")"
makedepends_literal="$(package_parenthesized_words "${makedepends[@]}")"
container_makedepends="$(printf '%s ' "${makedepends[@]}")"

cat > "${work_root}/PKGBUILD" <<EOF
pkgname=xymon
pkgver=${release_version}
pkgrel=1
pkgdesc='Xymon network monitor'
arch=('x86_64')
url='https://xymon.sourceforge.net/'
license=('GPL')
depends=${depends_literal}
makedepends=${makedepends_literal}
source=(${archive_name})
sha256sums=('SKIP')
install=xymon.install
options=(!debug)

build() {
  cd "\${srcdir}/${source_prefix}"
  USEXYMONPING=y \\
  ENABLESSL=y \\
  ENABLELDAP=y \\
  ENABLELDAPSSL=y \\
  XYMONUSER=xymon \\
  XYMONTOPDIR=/usr/lib/xymon \\
  XYMONVAR=/var/lib/xymon \\
  XYMONHOSTURL=/xymon \\
  CGIDIR=/usr/lib/xymon/cgi-bin \\
  XYMONCGIURL=/xymon-cgi \\
  SECURECGIDIR=/usr/lib/xymon/cgi-secure \\
  SECUREXYMONCGIURL=/xymon-seccgi \\
  HTTPDGID=xymon \\
  XYMONLOGDIR=/var/log/xymon \\
  XYMONHOSTNAME=localhost \\
  XYMONHOSTIP=127.0.0.1 \\
  MANROOT=/usr/share/man \\
  INSTALLBINDIR=/usr/lib/xymon/server/bin \\
  INSTALLETCDIR=/etc/xymon \\
  INSTALLWEBDIR=/etc/xymon/web \\
  INSTALLEXTDIR=/usr/lib/xymon/server/ext \\
  INSTALLTMPDIR=/var/lib/xymon/tmp \\
  INSTALLWWWDIR=/var/lib/xymon/www \\
  ./configure
  PKGBUILD=1 make -j1
}

package() {
  cd "\${srcdir}/${source_prefix}"
  PKGBUILD=1 INSTALLROOT="\${pkgdir}" make -j1 install
  PKGBUILD=1 INSTALLROOT="\${pkgdir}" MANROOT=/usr/share/man make -j1 install-man
}
EOF

cat > "${work_root}/xymon.install" <<'EOF'
pre_install() {
  getent group xymon >/dev/null 2>&1 || groupadd -r xymon >/dev/null 2>&1 || true
  getent passwd xymon >/dev/null 2>&1 || useradd -r -g xymon -d /usr/lib/xymon -s /usr/bin/nologin xymon >/dev/null 2>&1 || true
}

pre_upgrade() {
  pre_install
}
EOF

cat > "${work_root}/container-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

pacman -Syu --noconfirm --needed shadow sudo ${CONTAINER_MAKEDEPENDS}

if ! id builder >/dev/null 2>&1; then
  useradd -m builder
fi

mkdir -p /etc/sudoers.d
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
chmod 440 /etc/sudoers.d/builder

chown -R builder:builder /work /dist

su builder -c 'cd /work && makepkg --nodeps --noconfirm --cleanbuild --clean'

cp -a /work/*.pkg.tar.* /dist/
chown -R "${HOST_UID}:${HOST_GID}" /dist
EOF
chmod 755 "${work_root}/container-build.sh"

docker run --rm \
  -e HOST_UID="${host_uid}" \
  -e HOST_GID="${host_gid}" \
  -e CONTAINER_MAKEDEPENDS="${container_makedepends}" \
  -v "${work_root}:/work" \
  -v "${output_root}:/dist" \
  --workdir /work \
  archlinux:latest \
  bash /work/container-build.sh

echo "Arch packages are available under: ${output_root}"
