#!/usr/bin/env bash
set -euo pipefail

os_name=""
os_version=""
variant=""

usage() {
  cat <<'USAGE' >&2
Usage: bootstrap-cmake.sh --os NAME --variant NAME [--version VERSION]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os)
      os_name="${2:-}"
      shift 2
      ;;
    --version)
      os_version="${2:-}"
      shift 2
      ;;
    --variant)
      variant="${2:-}"
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

if [[ -z "${os_name}" || -z "${variant}" ]]; then
  usage
fi

cmd=(bash ci/bootstrap-install.sh --os "${os_name}" --variant "${variant}" --build cmake)
if [[ -n "${os_version}" ]]; then
  cmd+=(--version "${os_version}")
fi

echo "Running bootstrap-install (${os_name} / ${variant})"
"${cmd[@]}"
