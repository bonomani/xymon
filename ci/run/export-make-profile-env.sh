#!/usr/bin/env bash
set -euo pipefail

profile="default"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile_file="${script_dir%/run}/profiles/make-layouts.yml"

usage() {
  cat <<'USAGE' >&2
Usage: export-make-profile-env.sh [--profile PROFILE]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:-}"
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

profile="$(printf '%s' "${profile:-default}" | tr '[:upper:]' '[:lower:]')"

if [[ ! -f "${profile_file}" ]]; then
  echo "Missing profile file: ${profile_file}" >&2
  exit 1
fi

awk -v profile="${profile}" '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }

  BEGIN {
    in_profiles = 0
    current_profile = ""
    found_profile = 0
  }

  /^[[:space:]]*#/ || /^[[:space:]]*$/ {
    next
  }

  /^profiles:[[:space:]]*$/ {
    in_profiles = 1
    next
  }

  !in_profiles {
    next
  }

  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    current_profile = $0
    sub(/^  /, "", current_profile)
    sub(/:[[:space:]]*$/, "", current_profile)
    if (current_profile == profile) {
      found_profile = 1
    }
    next
  }

  current_profile == profile && /^    [A-Z0-9_]+:[[:space:]]*[^[:space:]].*$/ {
    entry = $0
    sub(/^    /, "", entry)
    key = entry
    sub(/:.*/, "", key)
    value = entry
    sub(/^[^:]+:[[:space:]]*/, "", value)
    value = trim(value)
    if (value !~ /^[-./:_A-Za-z0-9]+$/) {
      printf "Unsafe value for %s in profile %s: %s\n", key, profile, value > "/dev/stderr"
      exit 4
    }
    printf "export %s=%s\n", key, value
    next
  }

  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    current_profile = ""
  }

  END {
    if (!found_profile) {
      printf "Unknown make profile: %s\n", profile > "/dev/stderr"
      exit 3
    }
  }
' "${profile_file}"
