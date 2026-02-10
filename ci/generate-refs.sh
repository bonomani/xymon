#!/usr/bin/env bash
set -euo pipefail

ROOT=""
TOPDIR="/var/lib/xymon"
OS_NAME=""
VARIANT="server"
REF_NAME="ref"
KEYFILES_NAME="keyfiles.sha256"
BUILD_TOOL=""
REF_STAGE_ROOT=""
CONFIG_H_PATH=""

usage() {
  cat <<'USAGE' >&2
Usage: $0 --root ROOT --os OS [--build TOOL] [--variant VARIANT] [--topdir TOPDIR] [--ref-name NAME] [--keyfiles-name NAME] [--refs-root DIR] [--config-h PATH]
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
    --refs-root)
      REF_STAGE_ROOT="${2:-}"
      shift 2
      ;;
    --config-h)
      CONFIG_H_PATH="${2:-}"
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
CONFIG_DEFINES_NAME="config.defines"
REF_STAGE_ROOT="${REF_STAGE_ROOT:-${TMPDIR}/xymon-refs}"
REF_DIR_STAGE="${REF_STAGE_ROOT}/${TEMP_PREFIX}"
CONFIG_H_PATH="${CONFIG_H_PATH:-${XYMON_CONFIG_H:-}}"

copy_to_refs() {
  local src="$1" dst="$2" dst_dir
  [ -e "$src" ] || return 0
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
  if [ -n "${CONFIG_H_PATH}" ] && [ -f "${CONFIG_H_PATH}" ]; then
    echo "Copying config metadata from ${CONFIG_H_PATH}" >&2
    cp "${CONFIG_H_PATH}" "$TMPDIR/${CONFIG_NAME}"
    grep -E '^(#define|#undef) ' "${CONFIG_H_PATH}" | sort -u > "$TMPDIR/${CONFIG_DEFINES_NAME}" || true
  else
    echo "No explicit config.h found at CONFIG_H_PATH='${CONFIG_H_PATH}'; skipping config metadata" >&2
  fi
}

generate_keyfiles_list() {
  : > "${TMPDIR}/${KEYFILES_NAME}"
  local missing=""
  for f in "${key_files[@]}"; do
    local local_p="${ROOT}${f#${TOPDIR}}"
    if [ ! -f "$local_p" ]; then
      echo "MISSING $f" >> "${TMPDIR}/${KEYFILES_NAME}"
      missing=yes
      continue
    fi
    printf '%s  %s\n' "$(sha256_of "$local_p")" "$f" >> "${TMPDIR}/${KEYFILES_NAME}"
  done
  LC_ALL=C sort "${TMPDIR}/${KEYFILES_NAME}" -o "${TMPDIR}/${KEYFILES_NAME}"
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
  LC_ALL=C sort "/tmp/${SYMLINKS_NAME}" -o "/tmp/${SYMLINKS_NAME}"
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
  LC_ALL=C sort "/tmp/${PERMS_NAME}" -o "/tmp/${PERMS_NAME}"
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
  for entry in \
    "${SYMLINKS_NAME}:symlinks" \
    "${PERMS_NAME}:perms" \
    "${BINLINKS_NAME}:binlinks" \
    "${EMBED_NAME}:embedded.paths" \
    "${REF_NAME}:ref" \
    "${KEYFILES_NAME}:keyfiles.sha256" \
    "${CONFIG_NAME}:meta/config.h" \
    "${CONFIG_DEFINES_NAME}:meta/config.defines"; do
    src="/tmp/${entry%%:*}"
    dst="${entry#*:}"
    if [ ! -e "$src" ]; then
      echo "Skipping missing $src" >&2
    fi
    copy_to_refs "$src" "$dst"
  done
}

cleanup_temp_files() {
  local temp_files=(
    "/tmp/${REF_NAME}"
    "/tmp/${KEYFILES_NAME}"
    "/tmp/${CONFIG_NAME}"
    "/tmp/${CONFIG_DEFINES_NAME}"
    "/tmp/${SYMLINKS_NAME}"
    "/tmp/${PERMS_NAME}"
    "/tmp/${BINLINKS_NAME}"
    "/tmp/${EMBED_NAME}"
  )
  for file in "${temp_files[@]}"; do
    rm -f "$file"
  done
}

discover_key_files() {
  local key_tmp p rel
  key_tmp="$(mktemp "${TMPDIR}/xymon-keyfiles.XXXXXX")"
  : > "$key_tmp"

  while IFS= read -r p; do
    rel="${p#$ROOT}"
    if [[ "$rel" =~ ^/(etc|server/etc|client/etc)/[^/]+\.(cfg|csv)$ ]] \
      || [[ "$rel" =~ ^/(etc|server/etc|client/etc)/[^/]+\.d/ ]]; then
      case "$rel" in
        *.bak|*.DIST|*.orig|*~)
          continue
          ;;
      esac
      printf '%s\n' "${TOPDIR}${rel}" >> "$key_tmp"
    fi
  done < <(find "$ROOT" -type f)

  mapfile -t key_files < <(sort -u "$key_tmp")
  rm -f "$key_tmp"

  echo "Discovered ${#key_files[@]} key files" >&2
  [ "${#key_files[@]}" -gt 0 ]
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

run_step "Collect tree list" collect_tree_list
run_step "Copy config" copy_config
run_step "Discover key files" discover_key_files
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
