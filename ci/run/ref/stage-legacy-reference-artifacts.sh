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
      rest="${rel#*/}"
      dst_rel="${rel}"
      case "${artifact}" in
        ref_*)
          if [[ "${artifact}" =~ ^ref_([[:alnum:]]+)_([[:alnum:]_]+)-([[:alnum:]_]+)__([[:alnum:]_.-]+)__([[:alnum:]_.-]+)$ ]]; then
            build_tool="${BASH_REMATCH[1]}"
            runtime_os="${BASH_REMATCH[2]}"
            variant="${BASH_REMATCH[3]}"
            platform_id="${BASH_REMATCH[4]}"
            artifact_arch="${BASH_REMATCH[5]}"
            dst_rel="ref/${build_tool}/${runtime_os}/${platform_id}/${variant}/${artifact_arch}/${rest}"
          else
            dst_rel="ref/unparsed/${rel}"
          fi
          ;;
        deps_*)
          if [[ "${artifact}" =~ ^deps_([[:alnum:]]+)_([[:alnum:]_.-]+)_([[:alnum:]_]+)__([[:alnum:]_.-]+)__([[:alnum:]_.-]+)__.*$ ]]; then
            build_tool="${BASH_REMATCH[1]}"
            platform_id="${BASH_REMATCH[2]}"
            variant="${BASH_REMATCH[3]}"
            artifact_arch="${BASH_REMATCH[4]}"
            dep_mode="${BASH_REMATCH[5]}"
            dst_rel="deps/${build_tool}/${platform_id}/${variant}/${artifact_arch}/${dep_mode}/${rest}"
          else
            dst_rel="deps/unparsed/${rel}"
          fi
          ;;
        lane_outcome_*)
          if [[ "${artifact}" =~ ^lane_outcome_([[:alnum:]]+)_([[:alnum:]_.-]+)_([[:alnum:]_]+)__.*$ ]]; then
            build_tool="${BASH_REMATCH[1]}"
            platform_id="${BASH_REMATCH[2]}"
            variant="${BASH_REMATCH[3]}"
            dst_rel="lane-outcome/${build_tool}/${platform_id}/${variant}/${rest}"
          else
            dst_rel="lane-outcome/unparsed/${rel}"
          fi
          ;;
      esac
      dst="${ref_dir}/${dst_rel}"
      mkdir -p "$(dirname "${dst}")"
      install -m 0644 "$f" "${dst}"
    done
