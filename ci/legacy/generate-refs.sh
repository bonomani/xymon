#!/usr/bin/env bash
set -euo pipefail

ROOT=""
TOPDIR="/var/lib/xymon"
OS_NAME=""
VARIANT="server"
REF_NAME="ref"
KEYFILES_NAME="keyfiles.sha256"
BUILD_TOOL=""

usage() {
  cat <<'USAGE' >&2
Usage: $0 --root ROOT --os OS [--build TOOL] [--variant VARIANT] [--topdir TOPDIR] [--ref-name NAME] [--keyfiles-name NAME]
USAGE
  exit 1
}

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
      usage
      ;;
  esac
done

[ -n "$ROOT" ] || { echo "Missing --root" >&2; exit 1; }
[ -n "$OS_NAME" ] || { echo "Missing --os" >&2; exit 1; }
[ -n "$BUILD_TOOL" ] || BUILD_TOOL="make"
[ -n "$VARIANT" ] || VARIANT="server"
TOPDIR="${TOPDIR%/}"
[ -n "$TOPDIR" ] || TOPDIR="/"

TMPDIR="${TMPDIR:-/tmp}"
TMPDIR="${TMPDIR%/}"
[ -d "$ROOT" ] || { echo "Missing $ROOT" >&2; exit 1; }

TEMP_PREFIX="${BUILD_TOOL}.${OS_NAME}.${VARIANT}"
SYMLINKS_NAME="symlinks"
PERMS_NAME="perms"
BINLINKS_NAME="binlinks"
EMBED_NAME="embedded.paths"
CONFIG_NAME="config.h"
REF_STAGE_ROOT="${REF_STAGE_ROOT:-${TMPDIR}/xymon-refs}"
REF_DIR_STAGE="${REF_STAGE_ROOT}/${TEMP_PREFIX}"

copy_to_refs() {
  local src="$1" dst="$2" dst_dir
  [ -e "$src" ] || return
  dst_dir="$(dirname "$REF_DIR_STAGE/$dst")"
  mkdir -p "$dst_dir"
  cp -p "$src" "$REF_DIR_STAGE/$dst"
}

error_steps=()
run_step() {
  local name="$1"
  shift
  echo "=== Step: $name ===" >&2
  if "$@"; then
    echo "=== Step '$name' succeeded ===" >&2
  else
    echo "=== Step '$name' FAILED ===" >&2
    error_steps+=("$name")
  fi
}

bin_roots=()
collect_bin_roots() {
  bin_roots=()
  [ -d "$ROOT/server/bin" ] && bin_roots+=("$ROOT/server/bin")
  [ -d "$ROOT/bin" ] && bin_roots+=("$ROOT/bin")
  [ "${#bin_roots[@]}" -gt 0 ]
}

collect_tree_list() {
  echo "Building file list from $ROOT" >&2
  find "$ROOT" -print \
    | sed "s|^$ROOT|$TOPDIR|" \
    | sed "s|$TOPDIR/$|$TOPDIR|" \
    | sort > "$TMPDIR/${REF_NAME}"
}

copy_config() {
  if [ -f "$ROOT/include/config.h" ]; then
    cp "$ROOT/include/config.h" "$TMPDIR/${CONFIG_NAME}"
  else
    : > "$TMPDIR/${CONFIG_NAME}"
  fi
}

generate_keyfiles_list() {
  : > "${TMPDIR}/${KEYFILES_NAME}"
  local missing
  for f in "${key_files[@]}"; do
    local local_p="${ROOT}${f#${TOPDIR}}"
    if [ ! -f "$local_p" ]; then
      echo "MISSING $f" >> "${TMPDIR}/${KEYFILES_NAME}"
      missing=yes
      continue
    fi
    printf '%s  %s\n' "$(sha256_of "$local_p")" "$f" >> "${TMPDIR}/${KEYFILES_NAME}"
  done
  [ -z "$missing" ]
}

stage_keyfiles() {
  for f in "${key_files[@]}"; do
    local local_p="${ROOT}${f#${TOPDIR}}"
    if [ -f "$local_p" ]; then
      local rel="${f#/}" rel_dir
      rel_dir=$(dirname "$rel")
      mkdir -p "$REF_DIR_STAGE/${rel_dir}"
      echo "Staging $rel" >&2
      cp -p "$local_p" "$REF_DIR_STAGE/${rel}"
    fi
  done
}

dump_symlinks() {
  : > "/tmp/${SYMLINKS_NAME}"
  find "$ROOT" -type l \
    | while IFS= read -r link; do
        if target=$(readlink "$link" 2>/dev/null); then
          printf '%s|%s\n' "${link#$ROOT}" "$target" >> "/tmp/${SYMLINKS_NAME}"
        fi
      done
}

dump_perms() {
  : > "/tmp/${PERMS_NAME}"
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
}

dump_binlinks() {
  : > "/tmp/${BINLINKS_NAME}"
  collect_bin_roots || return 0
  find "${bin_roots[@]}" -type f -perm -111 \
    | while IFS= read -r bin; do
        echo "=== ${bin#$ROOT} ===" >> "/tmp/${BINLINKS_NAME}"
        if ! command -v ldd >/dev/null 2>&1; then
          continue
        fi
        printf 'ldd: %s\n' "$bin" >&2
        ldd "$bin" 2>/dev/null \
          | sed -E 's/ \(0x[0-9a-fA-F]+\)//g' \
          | awk '\
              $1 == "linux-vdso.so.1" {print $1; next} \
              $1 == "not" && $2 == "a" {print; next} \
              $NF ~ /^\// {print $NF} \
            ' >> "/tmp/${BINLINKS_NAME}" || true
      done
}

dump_embedded() {
  : > "/tmp/${EMBED_NAME}"
  collect_bin_roots || return 0
  find "${bin_roots[@]}" -type f -perm -111 \
    | while IFS= read -r bin; do
        strings "$bin" | grep -E '/var/lib/xymon' >> "/tmp/${EMBED_NAME}" || true
      done
  sort -u "/tmp/${EMBED_NAME}" -o "/tmp/${EMBED_NAME}"
}

copy_artifacts() {
  copy_to_refs "/tmp/${SYMLINKS_NAME}" "symlinks"
  copy_to_refs "/tmp/${PERMS_NAME}" "perms"
  copy_to_refs "/tmp/${BINLINKS_NAME}" "binlinks"
  copy_to_refs "/tmp/${EMBED_NAME}" "embedded.paths"
  copy_to_refs "/tmp/${REF_NAME}" "ref"
  copy_to_refs "/tmp/${KEYFILES_NAME}" "keyfiles.sha256"
  copy_to_refs "/tmp/${CONFIG_NAME}" "config.h"
}

cleanup_temp_files() {
  local temp_files=(
    "/tmp/${REF_NAME}"
    "/tmp/${KEYFILES_NAME}"
    "/tmp/${CONFIG_NAME}"
    "/tmp/${SYMLINKS_NAME}"
    "/tmp/${PERMS_NAME}"
    "/tmp/${BINLINKS_NAME}"
    "/tmp/${EMBED_NAME}"
  )
  for file in "${temp_files[@]}"; do
    rm -f "$file"
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

run_step "Collect tree list" collect_tree_list
run_step "Copy config" copy_config
run_step "Generate keyfile list" generate_keyfiles_list
run_step "Stage keyfiles" stage_keyfiles
run_step "Dump symlinks" dump_symlinks
run_step "Dump perms" dump_perms
run_step "Dump binlinks" dump_binlinks
run_step "Dump embedded paths" dump_embedded
run_step "Copy artifacts" copy_artifacts

cleanup_temp_files

if [ "${#error_steps[@]}" -gt 0 ]; then
  echo "Reference generation had issues in the following steps: ${error_steps[*]}" >&2
  exit 1
else
  echo "Reference generation completed successfully." >&2
fi
