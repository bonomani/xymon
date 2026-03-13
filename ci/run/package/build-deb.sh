#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/run/package/common.sh
source "${SCRIPT_DIR}/common.sh"

package_parse_release_args "$@"
package_require_tools git dpkg-buildpackage fakeroot tar make awk

release_version="${PACKAGE_RELEASE_VERSION}"
repo_root="$(package_repo_root)"
stage_root="${repo_root}/debbuild"
source_dir="${stage_root}/xymon-${release_version}"

package_prepare_clean_dir "${stage_root}"

git -C "${repo_root}" archive --format=tar --prefix="xymon-${release_version}/" HEAD | tar -xf - -C "${stage_root}"

if [[ -f "${source_dir}/Makefile" ]]; then
  make -C "${source_dir}" -f "${repo_root}/Makefile" distclean || true
fi

changelog_file="${source_dir}/debian/changelog"
if [[ ! -f "${changelog_file}" ]]; then
  echo "Missing Debian changelog in staged source: ${changelog_file}" >&2
  exit 1
fi

old_changelog_version="$(
  awk '
    NR == 1 {
      if (match($0, /\([^)]*\)/)) {
        val = substr($0, RSTART + 1, RLENGTH - 2)
        print val
        exit
      }
    }
  ' "${changelog_file}"
)"
if [[ -z "${old_changelog_version}" ]]; then
  echo "Unable to parse package version from ${changelog_file}" >&2
  exit 1
fi

debian_revision=""
if [[ "${old_changelog_version}" == *-* ]]; then
  debian_revision="${old_changelog_version##*-}"
fi

deb_package_version="${release_version}"
if [[ -n "${debian_revision}" && "${release_version}" != *-* ]]; then
  deb_package_version="${release_version}-${debian_revision}"
fi

tmp_changelog="${changelog_file}.tmp"
awk -v NEW_VERSION="${deb_package_version}" '
  NR == 1 {
    if (sub(/\([^)]*\)/, "(" NEW_VERSION ")", $0) == 0) {
      exit 1
    }
  }
  { print }
' "${changelog_file}" > "${tmp_changelog}"
mv "${tmp_changelog}" "${changelog_file}"

(
  cd "${source_dir}"
  dpkg-buildpackage -rfakeroot -b -us -uc
)

echo "Debian packages are available under: ${stage_root}"
