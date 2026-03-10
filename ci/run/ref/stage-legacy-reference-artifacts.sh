#!/usr/bin/env bash
set -euo pipefail

artifacts_dir=""
ref_dir=""

usage() {
  cat <<'USAGE' >&2
Usage: stage-legacy-reference-artifacts.sh --artifacts-dir PATH --ref-dir PATH

Copy downloaded legacy reference artifacts into refs staging layout.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts-dir)
      artifacts_dir="${2:-}"
      shift 2
      ;;
    --ref-dir)
      ref_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "${artifacts_dir}" ]; then
  echo "Missing --artifacts-dir" >&2
  usage
  exit 2
fi
if [ -z "${ref_dir}" ]; then
  echo "Missing --ref-dir" >&2
  usage
  exit 2
fi
if [ ! -d "${artifacts_dir}" ]; then
  echo "Artifacts directory does not exist: ${artifacts_dir}" >&2
  exit 1
fi

find "${artifacts_dir}" -type f -print0 \
  | while IFS= read -r -d '' f; do
      rel="${f#${artifacts_dir}/}"
      artifact="${rel%%/*}"
      dst_rel="${rel}"
      case "${artifact}" in
        ref_*)
          dst_rel="ref/${rel}"
          ;;
        deps_*)
          dst_rel="deps/${rel}"
          ;;
        lane_outcome_*)
          dst_rel="lane-outcome/${rel}"
          ;;
      esac
      dst="${ref_dir}/${dst_rel}"
      mkdir -p "$(dirname "${dst}")"
      install -m 0644 "$f" "${dst}"
    done
