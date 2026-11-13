#!/usr/bin/env bash
set -euo pipefail

PACKAGE_RELEASE_VERSION=""

package_usage_release() {
  cat <<'USAGE' >&2
Usage: PACKAGE_SCRIPT --release VERSION
USAGE
  exit 2
}

package_parse_release_args() {
  PACKAGE_RELEASE_VERSION=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release)
        PACKAGE_RELEASE_VERSION="${2:-}"
        shift 2
        ;;
      -h|--help)
        package_usage_release
        ;;
      *)
        echo "Unknown argument: $1" >&2
        package_usage_release
        ;;
    esac
  done

  if [[ -z "${PACKAGE_RELEASE_VERSION}" ]]; then
    echo "Missing --release" >&2
    package_usage_release
  fi
}

package_require_tools() {
  local tool=""
  for tool in "$@"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Required tool not found: ${tool}" >&2
      exit 1
    fi
  done
}

package_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd
}

package_prepare_clean_dir() {
  local path="${1:-}"
  if [[ -z "${path}" ]]; then
    echo "package_prepare_clean_dir requires a path" >&2
    exit 1
  fi
  rm -rf "${path}"
  mkdir -p "${path}"
}

package_git_archive_to_dir() {
  local repo_root="${1:-}"
  local prefix="${2:-}"
  local destination="${3:-}"
  if [[ -z "${repo_root}" || -z "${prefix}" || -z "${destination}" ]]; then
    echo "package_git_archive_to_dir requires repo_root, prefix and destination" >&2
    exit 1
  fi

  mkdir -p "${destination}"
  git -C "${repo_root}" archive --format=tar --prefix="${prefix}/" HEAD | tar -xf - -C "${destination}"
}

package_git_archive_to_file() {
  local repo_root="${1:-}"
  local prefix="${2:-}"
  local archive_path="${3:-}"
  if [[ -z "${repo_root}" || -z "${prefix}" || -z "${archive_path}" ]]; then
    echo "package_git_archive_to_file requires repo_root, prefix and archive_path" >&2
    exit 1
  fi

  git -C "${repo_root}" archive --format=tar.gz --prefix="${prefix}/" HEAD > "${archive_path}"
}

package_resolve_model_packages() {
  local repo_root="${1:-}"
  local family="${2:-}"
  local os_name="${3:-}"
  local pkgmgr="${4:-}"
  if [[ -z "${repo_root}" || -z "${family}" || -z "${os_name}" || -z "${pkgmgr}" ]]; then
    echo "package_resolve_model_packages requires repo_root, family, os_name and pkgmgr" >&2
    exit 1
  fi

  bash "${repo_root}/ci/deps/packages-from-yaml.sh" \
    --variant server \
    --family "${family}" \
    --os "${os_name}" \
    --pkgmgr "${pkgmgr}" \
    --build-tool make \
    --enable-ldap ON \
    --enable-snmp ON
}

package_pick_primary_alternatives() {
  awk '
    NF == 0 {
      next
    }
    {
      split($0, parts, /\|/)
      print parts[1]
    }
  '
}

package_unique_lines() {
  awk '
    NF == 0 {
      next
    }
    !seen[$0]++ {
      print
    }
  '
}

package_parenthesized_words() {
  local item=""
  printf '('
  for item in "$@"; do
    printf '%q ' "${item}"
  done
  printf ')'
}
