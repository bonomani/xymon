#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/package/common.sh
source "${SCRIPT_DIR}/common.sh"

package_parse_release_args "$@"
package_require_tools bash gmake pkg tar find sed awk

release_version="${PACKAGE_RELEASE_VERSION}"
repo_root="$(package_repo_root)"
output_root="${repo_root}/pkgbuild/freebsd"
build_root="${output_root}/build"
stage_root="${output_root}/stage"
meta_root="${output_root}/metadata"
source_prefix="xymon-${release_version}"
source_dir="${build_root}/${source_prefix}"

package_prepare_clean_dir "${output_root}"
mkdir -p "${build_root}" "${stage_root}" "${meta_root}"

bash "${repo_root}/ci/deps/install-bsd-packages.sh" \
  --install \
  --os freebsd \
  --version 14.3 \
  --build-tool make

openldap_pkg="$(pkg search -q '^openldap.*client$' 2>/dev/null | head -n1 || true)"
if [[ -n "${openldap_pkg}" ]]; then
  env ASSUME_ALWAYS_YES=YES pkg install "${openldap_pkg}"
fi

mkdir -p "${source_dir}"
(
  cd "${repo_root}"
  tar -cf - \
    --exclude='.git' \
    --exclude='pkgbuild' \
    .
) | tar -xf - -C "${source_dir}"

(
  cd "${source_dir}"
  USEXYMONPING=y \
  ENABLESSL=y \
  ENABLELDAP=y \
  ENABLELDAPSSL=y \
  XYMONUSER=xymon \
  XYMONTOPDIR=/usr/local/lib/xymon \
  XYMONVAR=/var/lib/xymon \
  XYMONHOSTURL=/xymon \
  CGIDIR=/usr/local/lib/xymon/cgi-bin \
  XYMONCGIURL=/xymon-cgi \
  SECURECGIDIR=/usr/local/lib/xymon/cgi-secure \
  SECUREXYMONCGIURL=/xymon-seccgi \
  HTTPDGID=xymon \
  XYMONLOGDIR=/var/log/xymon \
  XYMONHOSTNAME=localhost \
  XYMONHOSTIP=127.0.0.1 \
  MANROOT=/usr/local/share/man \
  INSTALLBINDIR=/usr/local/lib/xymon/server/bin \
  INSTALLETCDIR=/usr/local/etc/xymon \
  INSTALLWEBDIR=/usr/local/etc/xymon/web \
  INSTALLEXTDIR=/usr/local/lib/xymon/server/ext \
  INSTALLTMPDIR=/var/lib/xymon/tmp \
  INSTALLWWWDIR=/var/lib/xymon/www \
  ./configure
  PKGBUILD=1 gmake -j1
  PKGBUILD=1 INSTALLROOT="${stage_root}" gmake -j1 install
  PKGBUILD=1 INSTALLROOT="${stage_root}" MANROOT=/usr/local/share/man gmake -j1 install-man
)

cat > "${meta_root}/+MANIFEST" <<EOF
name: xymon
version: "${release_version}"
origin: net/xymon
comment: Xymon network monitor
www: https://xymon.sourceforge.net/
maintainer: noreply@example.invalid
prefix: /
licenses: [ GPLv2 ]
desc: <<EOD
Xymon network monitor packaged for FreeBSD.
EOD
EOF

cat > "${meta_root}/+PRE_INSTALL" <<'EOF'
#!/bin/sh
if ! pw groupshow xymon >/dev/null 2>&1; then
  pw groupadd xymon >/dev/null 2>&1 || true
fi
if ! pw usershow xymon >/dev/null 2>&1; then
  pw useradd xymon -g xymon -d /usr/local/lib/xymon -s /usr/sbin/nologin -c "Xymon user" >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "${meta_root}/+PRE_INSTALL"

plist_file="${meta_root}/plist"
{
  (
    cd "${stage_root}"
    find . -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort | sed 's#^\./#/#'
  )
  (
    cd "${stage_root}"
    find . -mindepth 1 -type d | LC_ALL=C sort -r | sed 's#^\./#@dir /#'
  )
} > "${plist_file}"

pkg create \
  --metadata "${meta_root}" \
  --plist "${plist_file}" \
  --root-dir "${stage_root}" \
  --out-dir "${output_root}"

echo "FreeBSD packages are available under: ${output_root}"
