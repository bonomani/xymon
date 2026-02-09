#!/usr/bin/env bash
set -euo pipefail

ROOT=""
TOPDIR="/var/lib/xymon"
OS_NAME=""
VARIANT="server"
REF_NAME=""
KEYFILES_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --topdir)
      TOPDIR="${2:-}"
      shift 2
      ;;
    --os)
      OS_NAME="${2:-}"
      shift 2
      ;;
    --variant)
      VARIANT="${2:-}"
      shift 2
      ;;
    --ref-name)
      REF_NAME="${2:-}"
      shift 2
      ;;
    --keyfiles-name)
      KEYFILES_NAME="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$ROOT" ]; then
  echo "Missing --root" >&2
  exit 1
fi
if [ -z "$OS_NAME" ]; then
  echo "Missing --os" >&2
  exit 1
fi
if [ -z "$VARIANT" ]; then
  VARIANT="server"
fi
TOPDIR="${TOPDIR%/}"
if [ -z "$TOPDIR" ]; then
  TOPDIR="/"
fi

if [ ! -d "$ROOT" ]; then
  echo "Missing $ROOT" >&2
  exit 1
fi

if [ -z "$REF_NAME" ]; then
  REF_NAME="legacy.${OS_NAME}.${VARIANT}.ref"
fi
if [ -z "$KEYFILES_NAME" ]; then
  KEYFILES_NAME="legacy.${OS_NAME}.${VARIANT}.keyfiles.sha256"
fi
SYMLINKS_NAME="legacy.${OS_NAME}.${VARIANT}.symlinks"
PERMS_NAME="legacy.${OS_NAME}.${VARIANT}.perms"
BINLINKS_NAME="legacy.${OS_NAME}.${VARIANT}.binlinks"
EMBED_NAME="legacy.${OS_NAME}.${VARIANT}.embedded.paths"
CONFIG_NAME="legacy.${OS_NAME}.${VARIANT}.config.h"

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$file"
  elif command -v digest >/dev/null 2>&1; then
    digest -a sha256 "$file"
  else
    echo "No sha256 tool found" >&2
    exit 1
  fi
}

find "$ROOT" -print \
  | sed "s|^$ROOT|$TOPDIR|" \
  | sed "s|$TOPDIR/$|$TOPDIR|" \
  | sort > "/tmp/${REF_NAME}"

if [ -f "$ROOT/include/config.h" ]; then
  cp "$ROOT/include/config.h" "/tmp/${CONFIG_NAME}"
else
  : > "/tmp/${CONFIG_NAME}"
fi

key_files=()
case "$VARIANT" in
  client|localclient)
    key_files=(
      "${TOPDIR}/etc/clientlaunch.cfg"
      "${TOPDIR}/etc/xymonclient.cfg"
      "${TOPDIR}/etc/localclient.cfg"
    )
    ;;
  *)
    key_files=(
      "${TOPDIR}/server/etc/xymonserver.cfg"
      "${TOPDIR}/server/etc/tasks.cfg"
      "${TOPDIR}/server/etc/cgioptions.cfg"
      "${TOPDIR}/server/etc/graphs.cfg"
      "${TOPDIR}/server/etc/client-local.cfg"
      "${TOPDIR}/server/etc/columndoc.csv"
      "${TOPDIR}/server/etc/protocols.cfg"
    )
    ;;
esac

: > "/tmp/${KEYFILES_NAME}"
for f in "${key_files[@]}"; do
  local_p="${ROOT}${f#${TOPDIR}}"
  if [ ! -f "$local_p" ]; then
    echo "MISSING $f" >> "/tmp/${KEYFILES_NAME}"
    continue
  fi
  printf '%s  %s\n' "$(sha256_of "$local_p")" "$f" >> "/tmp/${KEYFILES_NAME}"

done

keyfiles_archive="legacy.${OS_NAME}.${VARIANT}.keyfiles.tgz"
keyfiles_root="/tmp/legacy-keyfiles-${OS_NAME}-${VARIANT}"
rm -rf "${keyfiles_root}"
mkdir -p "${keyfiles_root}"
for f in "${key_files[@]}"; do
  local_p="${ROOT}${f#${TOPDIR}}"
  if [ -f "$local_p" ]; then
    rel="${f#/}"
    mkdir -p "${keyfiles_root}/$(dirname "${rel}")"
    cp -p "$local_p" "${keyfiles_root}/${rel}"
  fi
done

tar -C /tmp -czf "/tmp/${keyfiles_archive}" "$(basename "${keyfiles_root}")"
if [ -d docs/cmake-legacy-migration/refs ]; then
  cp "/tmp/${keyfiles_archive}" "docs/cmake-legacy-migration/refs/${keyfiles_archive}" || true
fi

if [ -d docs/cmake-legacy-migration/refs ]; then
  cp "/tmp/${REF_NAME}" "docs/cmake-legacy-migration/refs/${REF_NAME}" || true
  cp "/tmp/${KEYFILES_NAME}" "docs/cmake-legacy-migration/refs/${KEYFILES_NAME}" || true
  if [ -f "/tmp/${CONFIG_NAME}" ]; then
    cp "/tmp/${CONFIG_NAME}" "docs/cmake-legacy-migration/refs/${CONFIG_NAME}" || true
  fi
fi

: > "/tmp/${SYMLINKS_NAME}"
if [ -d "$ROOT" ]; then
  while IFS= read -r link; do
    target=$(readlink "$link" || true)
    printf '%s|%s\n' "${link#$ROOT}" "$target" >> "/tmp/${SYMLINKS_NAME}"
  done < <(find "$ROOT" -type l)
fi

: > "/tmp/${PERMS_NAME}"
if [ -d "$ROOT" ]; then
  case "$(uname -s)" in
    Darwin|FreeBSD|OpenBSD|NetBSD)
      find "$ROOT" -type f -o -type d \
        | while IFS= read -r p; do
            mode=$(stat -f '%Lp' "$p")
            uid=$(stat -f '%u' "$p")
            gid=$(stat -f '%g' "$p")
            size=$(stat -f '%z' "$p")
            printf '%s|%s|%s|%s|%s\n' "${p#$ROOT}" "$mode" "$uid" "$gid" "$size" >> "/tmp/${PERMS_NAME}"
          done
      ;;
    *)
      find "$ROOT" -type f -o -type d \
        | while IFS= read -r p; do
            stat -c '%n|%a|%u|%g|%s' "$p" | sed "s|$p|${p#$ROOT}|" >> "/tmp/${PERMS_NAME}"
          done
      ;;
  esac
fi

: > "/tmp/${BINLINKS_NAME}"
bin_roots=()
if [ -d "$ROOT/server/bin" ]; then
  bin_roots+=("$ROOT/server/bin")
fi
if [ -d "$ROOT/bin" ]; then
  bin_roots+=("$ROOT/bin")
fi
if [ "${#bin_roots[@]}" -gt 0 ]; then
  while IFS= read -r bin; do
    echo "=== ${bin#$ROOT} ===" >> "/tmp/${BINLINKS_NAME}"
    case "$(uname -s)" in
      Darwin)
        otool -L "$bin" | sed '1d' | awk '{print $1}' >> "/tmp/${BINLINKS_NAME}" || true
        ;;
      OpenBSD|FreeBSD|NetBSD)
        if command -v ldd >/dev/null 2>&1; then
          ldd "$bin" | awk '
            /Start[[:space:]]+End[[:space:]]+Type/ {next}
            /:$/ {next}
            /=>/ {
              for (i = 1; i < NF; i++) {
                if ($i == "=>") {print $(i+1); next}
              }
            }
            NF && $NF ~ /^\// {print $NF}
          ' >> "/tmp/${BINLINKS_NAME}" || true
        fi
        ;;
      *)
        if command -v ldd >/dev/null 2>&1; then
          ldd "$bin" \
            | sed -E 's/ \(0x[0-9a-fA-F]+\)//g' \
            | awk '
                $1 == "linux-vdso.so.1" {print $1; next}
                $1 == "not" && $2 == "a" {print; next}
                $NF ~ /^\// {print $NF}
              ' >> "/tmp/${BINLINKS_NAME}" || true
        fi
        ;;
    esac
done < <(find "${bin_roots[@]}" -type f -perm -111)
fi

: > "/tmp/${EMBED_NAME}"
if [ "${#bin_roots[@]}" -gt 0 ] && command -v strings >/dev/null 2>&1; then
  while IFS= read -r bin; do
    strings "$bin" | grep -E '/var/lib/xymon' >> "/tmp/${EMBED_NAME}" || true
  done < <(find "${bin_roots[@]}" -type f -perm -111)
  sort -u "/tmp/${EMBED_NAME}" -o "/tmp/${EMBED_NAME}"
fi

if [ -d docs/cmake-legacy-migration/refs ]; then
  cp "/tmp/${SYMLINKS_NAME}" "docs/cmake-legacy-migration/refs/${SYMLINKS_NAME}" || true
  cp "/tmp/${PERMS_NAME}" "docs/cmake-legacy-migration/refs/${PERMS_NAME}" || true
  cp "/tmp/${BINLINKS_NAME}" "docs/cmake-legacy-migration/refs/${BINLINKS_NAME}" || true
  cp "/tmp/${EMBED_NAME}" "docs/cmake-legacy-migration/refs/${EMBED_NAME}" || true
fi
