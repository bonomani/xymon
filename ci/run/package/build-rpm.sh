#!/usr/bin/env bash
set -euo pipefail

release_version=""

usage() {
  cat <<'USAGE' >&2
Usage: build-rpm.sh --release VERSION
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      release_version="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "${release_version}" ]]; then
  echo "Missing --release" >&2
  usage
fi

for tool in git rpmbuild sed tar; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Required tool not found: ${tool}" >&2
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
rpm_root="${repo_root}/rpmbuild"

rm -rf "${rpm_root}"
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
