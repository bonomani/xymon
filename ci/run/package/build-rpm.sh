#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/package/common.sh
source "${SCRIPT_DIR}/common.sh"

package_parse_release_args "$@"
package_require_tools git rpmbuild sed tar

release_version="${PACKAGE_RELEASE_VERSION}"
repo_root="$(package_repo_root)"
rpm_root="${repo_root}/rpmbuild"

package_prepare_clean_dir "${rpm_root}"
mkdir -p \
  "${rpm_root}/BUILD" \
  "${rpm_root}/BUILDROOT" \
  "${rpm_root}/RPMS" \
  "${rpm_root}/SOURCES" \
  "${rpm_root}/SPECS" \
  "${rpm_root}/SRPMS"

sed -e "s/@VER@/${release_version}/g" "${repo_root}/rpm/xymon.spec" > "${rpm_root}/SPECS/xymon.spec"
cp "${repo_root}/rpm/xymon-init.d" "${rpm_root}/SOURCES/"
cp "${repo_root}/rpm/xymon.logrotate" "${rpm_root}/SOURCES/"
cp "${repo_root}/rpm/xymon-client.init" "${rpm_root}/SOURCES/"
cp "${repo_root}/rpm/xymon-client.default" "${rpm_root}/SOURCES/"

git -C "${repo_root}" archive --format=tar.gz --prefix="xymon-${release_version}/" HEAD > "${rpm_root}/SOURCES/xymon-${release_version}.tar.gz"

rpmbuild \
  --define "_topdir ${rpm_root}" \
  -ba \
  --clean \
  "${rpm_root}/SPECS/xymon.spec"

echo "RPM packages are available under: ${rpm_root}"
