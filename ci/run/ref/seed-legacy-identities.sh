#!/usr/bin/env bash
set -euo pipefail

legacy_passwd=""
legacy_group=""

usage() {
  cat <<'USAGE' >&2
Usage: seed-legacy-identities.sh --passwd FILE --group FILE
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --passwd)
      legacy_passwd="${2:-}"
      shift 2
      ;;
    --group)
      legacy_group="${2:-}"
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

if [[ -z "${legacy_passwd}" || -z "${legacy_group}" ]]; then
  usage
fi

if [[ ! -s "${legacy_passwd}" ]]; then
  echo "Identity seed failed: missing ${legacy_passwd}" >&2
  exit 1
fi
if [[ ! -s "${legacy_group}" ]]; then
  echo "Identity seed failed: missing ${legacy_group}" >&2
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Identity seed skipped (not running as root)"
  exit 0
fi
if ! command -v getent >/dev/null 2>&1; then
  echo "Identity seed skipped (getent unavailable)"
  exit 0
fi

ensure_group() {
  local gid="$1" preferred="${2:-}"
  local gname
  [[ -n "${gid}" ]] || return 0

  if getent group "${gid}" >/dev/null 2>&1; then
    return 0
  fi

  gname="${preferred}"
  [[ -n "${gname}" ]] || gname="xymonrefg${gid}"
  if getent group "${gname}" >/dev/null 2>&1; then
    gname="${gname}_legacy"
  fi

  if command -v groupadd >/dev/null 2>&1; then
    groupadd -g "${gid}" "${gname}" >/dev/null 2>&1 || true
  elif command -v addgroup >/dev/null 2>&1; then
    addgroup --gid "${gid}" --system "${gname}" >/dev/null 2>&1 \
      || addgroup -g "${gid}" "${gname}" >/dev/null 2>&1 \
      || true
  fi
}

ensure_user() {
  local uid="$1" gid="$2" preferred="${3:-}"
  local uname
  [[ -n "${uid}" ]] || return 0
  [[ -n "${gid}" ]] || return 0

  if getent passwd "${uid}" >/dev/null 2>&1; then
    return 0
  fi

  ensure_group "${gid}"

  uname="${preferred}"
  [[ -n "${uname}" ]] || uname="xymonrefu${uid}"
  if getent passwd "${uname}" >/dev/null 2>&1; then
    uname="${uname}_legacy"
  fi

  if command -v useradd >/dev/null 2>&1; then
    useradd --uid "${uid}" --gid "${gid}" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "${uname}" >/dev/null 2>&1 || true
  elif command -v adduser >/dev/null 2>&1; then
    adduser --uid "${uid}" --gid "${gid}" --home /nonexistent --no-create-home --disabled-password --gecos "" "${uname}" >/dev/null 2>&1 || true
  fi
}

while IFS=':' read -r group_name _ gid _; do
  [[ -n "${group_name}" ]] || continue
  [[ -n "${gid}" ]] || continue
  ensure_group "${gid}" "${group_name}"
done < "${legacy_group}"

while IFS=':' read -r user_name _ uid gid _; do
  [[ -n "${user_name}" ]] || continue
  [[ -n "${uid}" ]] || continue
  [[ -n "${gid}" ]] || continue
  ensure_user "${uid}" "${gid}" "${user_name}"
done < "${legacy_passwd}"

echo "Seeded identity entries from ${legacy_passwd} and ${legacy_group}"
