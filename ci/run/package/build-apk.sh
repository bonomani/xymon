#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/package/common.sh
source "${SCRIPT_DIR}/common.sh"

package_parse_release_args "$@"
package_require_tools docker git tar id sha512sum

release_version="${PACKAGE_RELEASE_VERSION}"
repo_root="$(package_repo_root)"
output_root="${repo_root}/pkgbuild/alpine"
work_root="${repo_root}/pkgbuild/.alpine-work"
source_prefix="xymon-${release_version}"
archive_name="${source_prefix}.tar.gz"
host_uid="$(id -u)"
host_gid="$(id -g)"

package_prepare_clean_dir "${output_root}"
package_prepare_clean_dir "${work_root}"
package_git_archive_to_file "${repo_root}" "${source_prefix}" "${work_root}/${archive_name}"

mapfile -t resolved_packages < <(
  package_resolve_model_packages "${repo_root}" alpine alpine_3 apk \
    | package_pick_primary_alternatives \
    | package_unique_lines
)

makedepends=()
runtime_packages=()
for package_name in "${resolved_packages[@]}"; do
  [[ -n "${package_name}" ]] || continue
  makedepends+=("${package_name}")
  case "${package_name}" in
    build-base|git|findutils|diffutils|ninja)
      continue
      ;;
    *-dev)
      runtime_packages+=("${package_name%-dev}")
      ;;
    *)
      runtime_packages+=("${package_name}")
      ;;
  esac
done

mapfile -t unique_runtime_packages < <(
  printf '%s\n' "${runtime_packages[@]}" | package_unique_lines
)
for package_name in "${unique_runtime_packages[@]}"; do
  if [[ " ${makedepends[*]} " != *" ${package_name} "* ]]; then
    makedepends+=("${package_name}")
  fi
done

sha512_hash="$(sha512sum "${work_root}/${archive_name}" | awk '{print $1}')"
sha512_line="${sha512_hash}  ${archive_name}"
makedepends_string="${makedepends[*]}"
depends_string="$(printf '%s\n' "${unique_runtime_packages[@]}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
container_makedepends="$(printf '%s ' "${makedepends[@]}")"

cat > "${work_root}/APKBUILD" <<EOF
pkgname=xymon
pkgver=${release_version}
pkgrel=0
pkgdesc="Xymon network monitor"
maintainer="Xymon CI <noreply@example.invalid>"
url="https://xymon.sourceforge.net/"
arch="x86_64"
license="GPL-2.0-only"
depends="${depends_string}"
makedepends="${makedepends_string}"
source="${archive_name}"
builddir="\${srcdir}/${source_prefix}"
options="!check"

build() {
  cd "\${builddir}"
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
  cd "\${builddir}"
  PKGBUILD=1 INSTALLROOT="\${pkgdir}" make -j1 install
  PKGBUILD=1 INSTALLROOT="\${pkgdir}" MANROOT=/usr/share/man make -j1 install-man
  if [ -d "\${pkgdir}/usr/share/man" ]; then
    find "\${pkgdir}/usr/share/man" -type f ! -name '*.gz' -exec gzip -9 {} +
  fi
}

sha512sums="
${sha512_line}
"
EOF

cat > "${work_root}/container-build.sh" <<'EOF'
#!/usr/bin/env sh
set -eu

apk add --no-cache alpine-sdk bash git shadow sudo ${CONTAINER_MAKEDEPENDS}

adduser -D builder >/dev/null 2>&1 || true
addgroup builder abuild >/dev/null 2>&1 || true
mkdir -p /etc/sudoers.d
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
chmod 440 /etc/sudoers.d/builder
chown -R builder:abuild /work /dist /home/builder

su builder -c 'abuild-keygen -a -i -n'
chmod a+r /home/builder/.abuild/*.rsa.pub
mkdir -p /etc/apk/keys
cp /home/builder/.abuild/*.rsa.pub /etc/apk/keys/
mkdir -p /dist/packages
chown -R builder:abuild /dist/packages

su builder -c 'cd /work && abuild -P /dist/packages -K'

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
  alpine:3.20 \
  sh /work/container-build.sh

echo "APK packages are available under: ${output_root}"
