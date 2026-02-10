#!/usr/bin/env bash
set -euo pipefail

ROOT=""
TOPDIR="/var/lib/xymon"
OS_NAME=""
VARIANT="server"
REF_NAME=""
KEYFILES_NAME=""
BUILD_TOOL=""
BUILD_TOOL=""

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
    --build)
      BUILD_TOOL="${2:-}"
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
if [ -z "$BUILD_TOOL" ]; then
  BUILD_TOOL="make"
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

TEMP_PREFIX="${BUILD_TOOL}.${OS_NAME}.${VARIANT}"
REF_NAME="ref"
KEYFILES_NAME="keyfiles.sha256"
SYMLINKS_NAME="symlinks"
PERMS_NAME="perms"
BINLINKS_NAME="binlinks"
EMBED_NAME="embedded.paths"
CONFIG_NAME="config.h"
KEYFILES_ARCHIVE="keyfiles.tgz"
REF_STAGE_ROOT="/tmp/xymon-refs"
REF_DIR_STAGE="${REF_STAGE_ROOT}/${TEMP_PREFIX}"
REF_DIR="docs/refs/${TEMP_PREFIX}"
TARBALL="docs/refs/${TEMP_PREFIX}.tar.gz"

copy_to_refs() {
  local src="$1"
  local dst="$2"
  if [ ! -e "$src" ]; then
    return
  fi
  for dir in "$REF_DIR_STAGE" "$REF_DIR"; do
    mkdir -p "$dir"
    cp "$src" "$dir/$dst"
  done
}

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

copy_to_refs "/tmp/${SYMLINKS_NAME}" "symlinks"
copy_to_refs "/tmp/${PERMS_NAME}" "perms"
copy_to_refs "/tmp/${BINLINKS_NAME}" "binlinks"
copy_to_refs "/tmp/${EMBED_NAME}" "embedded.paths"
copy_to_refs "/tmp/${REF_NAME}" "ref"
copy_to_refs "/tmp/${KEYFILES_NAME}" "keyfiles.sha256"
copy_to_refs "/tmp/${CONFIG_NAME}" "config.h"
copy_to_refs "/tmp/${keyfiles_archive}" "${KEYFILES_ARCHIVE}"
mkdir -p "$(dirname "$TARBALL")"
pushd "$REF_DIR" >/dev/null
tar -czf "../${TEMP_PREFIX}.tar.gz" . >/dev/null 2>&1 || true
popd >/dev/null
