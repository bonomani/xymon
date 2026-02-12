#!/usr/bin/env bash
set -euo pipefail

ROOT=""
TOPDIR="/var/lib/xymon"
OS_NAME=""
VARIANT="server"
KEYFILES_NAME="keyfiles.sha256"
BUILD_TOOL=""
REF_STAGE_ROOT=""
CONFIG_H_PATH=""
INVENTORY_NAME="inventory.tsv"
OWNERS_PASSWD_NAME="owners.passwd"
OWNERS_GROUP_NAME="owners.group"
KEYFILES_LIST_NAME="keyfiles.list"

usage() {
  cat <<'USAGE' >&2
Usage: $0 --root ROOT --os OS [--build TOOL] [--variant VARIANT] [--topdir TOPDIR] [--keyfiles-name NAME] [--refs-root DIR] [--config-h PATH]
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
BINLINKS_NAME="binlinks"
NEEDED_NORM_NAME="needed.norm.tsv"
EMBED_NAME="embedded.paths"
CONFIG_NAME="config.h"
CONFIG_DEFINES_NAME="config.defines"
REF_STAGE_ROOT="${REF_STAGE_ROOT:-${TMPDIR}/xymon-refs}"
REF_DIR_STAGE="${REF_STAGE_ROOT}/${TEMP_PREFIX}"
CONFIG_H_PATH="${CONFIG_H_PATH:-${XYMON_CONFIG_H:-}}"
HOST_UNAME="$(uname -s)"

stat_fields() {
  local p="$1"
  case "${HOST_UNAME}" in
    Darwin|FreeBSD|OpenBSD|NetBSD)
      printf '%s\t%s\t%s\t%s\n' \
        "$(stat -f '%Lp' "$p")" \
        "$(stat -f '%u' "$p")" \
        "$(stat -f '%g' "$p")" \
        "$(stat -f '%z' "$p")"
      ;;
    *)
      printf '%s\t%s\t%s\t%s\n' \
        "$(stat -c '%a' "$p")" \
        "$(stat -c '%u' "$p")" \
        "$(stat -c '%g' "$p")" \
        "$(stat -c '%s' "$p")"
      ;;
  esac
}

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

build_inventory() {
  local p rel abs type mode uid gid size target
  : > "${TMPDIR}/${INVENTORY_NAME}"
  while IFS= read -r p; do
    rel="${p#$ROOT}"
    abs="${p/#$ROOT/$TOPDIR}"
    if [ "${abs}" = "${TOPDIR}/" ]; then
      abs="${TOPDIR}"
    fi

    mode=""
    uid=""
    gid=""
    size=""
    target=""
    if [ -L "$p" ]; then
      type="l"
      target="$(readlink "$p" 2>/dev/null || true)"
    elif [ -d "$p" ]; then
      type="d"
      IFS=$'\t' read -r mode uid gid size < <(stat_fields "$p")
    elif [ -f "$p" ]; then
      type="f"
      IFS=$'\t' read -r mode uid gid size < <(stat_fields "$p")
    else
      type="o"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$abs" "$rel" "$type" "$mode" "$uid" "$gid" "$size" "$target" \
      >> "${TMPDIR}/${INVENTORY_NAME}"
  done < <(find "$ROOT" -print)

  LC_ALL=C sort "${TMPDIR}/${INVENTORY_NAME}" -o "${TMPDIR}/${INVENTORY_NAME}"
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
  if [ ! -f "${TMPDIR}/${KEYFILES_LIST_NAME}" ]; then
    echo "Missing ${TMPDIR}/${KEYFILES_LIST_NAME}" >&2
    return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local local_p="${ROOT}${f#${TOPDIR}}"
    if [ ! -f "$local_p" ]; then
      echo "MISSING $f" >> "${TMPDIR}/${KEYFILES_NAME}"
      missing=yes
      continue
    fi
    printf '%s  %s\n' "$(sha256_of "$local_p")" "$f" >> "${TMPDIR}/${KEYFILES_NAME}"
  done < "${TMPDIR}/${KEYFILES_LIST_NAME}"
  LC_ALL=C sort "${TMPDIR}/${KEYFILES_NAME}" -o "${TMPDIR}/${KEYFILES_NAME}"
  [ -z "$missing" ]
}

default_web_group_name() {
  case "${OS_NAME}" in
    linux)
      echo "www-data"
      ;;
    *)
      echo "www"
      ;;
  esac
}

generate_owner_maps() {
  : > "${TMPDIR}/${OWNERS_PASSWD_NAME}"
  : > "${TMPDIR}/${OWNERS_GROUP_NAME}"
  if [ ! -s "${TMPDIR}/${INVENTORY_NAME}" ]; then
    return 0
  fi

  local web_group_name
  web_group_name="$(default_web_group_name)"

  awk -F $'\t' -v web_group_name="${web_group_name}" '
    ($3 == "f" || $3 == "d") {
      uid = $5 + 0
      gid = $6 + 0
      uid_total[uid]++
      uid_gid_count[uid SUBSEP gid]++
      gid_total[gid]++
    }
    END {
      service_uid = -1
      service_uid_count = -1
      for (uid in uid_total) {
        if (uid == 0) continue
        if (uid_total[uid] > service_uid_count || (uid_total[uid] == service_uid_count && uid < service_uid)) {
          service_uid = uid
          service_uid_count = uid_total[uid]
        }
      }
      if (service_uid < 0) service_uid = 0

      service_gid = -1
      service_gid_count = -1
      for (k in uid_gid_count) {
        split(k, parts, SUBSEP)
        uid = parts[1] + 0
        gid = parts[2] + 0
        if (uid != service_uid) continue
        cnt = uid_gid_count[k]
        if (cnt > service_gid_count || (cnt == service_gid_count && gid < service_gid)) {
          service_gid = gid
          service_gid_count = cnt
        }
      }
      if (service_gid < 0) service_gid = service_uid

      web_gid = -1
      web_gid_count = -1
      for (gid in gid_total) {
        if (gid == 0 || gid == service_gid) continue
        cnt = gid_total[gid]
        if (cnt > web_gid_count || (cnt == web_gid_count && gid < web_gid)) {
          web_gid = gid
          web_gid_count = cnt
        }
      }

      for (uid in uid_total) {
        uidn = uid + 0
        uname = (uidn == 0 ? "root" : (uidn == service_uid ? "xymon" : "xymonu" uidn))
        uid_name[uidn] = uname
      }

      for (gid in gid_total) {
        gidn = gid + 0
        if (gidn == 0) gname = "root"
        else if (gidn == service_gid) gname = "xymon"
        else if (gidn == web_gid) gname = web_group_name
        else gname = "xymong" gidn
        gid_name[gidn] = gname
      }

      for (uid in uid_total) {
        uidn = uid + 0
        primary_gid = -1
        primary_gid_count = -1
        for (k in uid_gid_count) {
          split(k, parts, SUBSEP)
          ku = parts[1] + 0
          kg = parts[2] + 0
          if (ku != uidn) continue
          cnt = uid_gid_count[k]
          if (cnt > primary_gid_count || (cnt == primary_gid_count && kg < primary_gid)) {
            primary_gid = kg
            primary_gid_count = cnt
          }
        }
        if (primary_gid < 0) primary_gid = (uidn == 0 ? 0 : service_gid)
        printf "U\t%d\t%s\t%d\n", uidn, uid_name[uidn], primary_gid
      }

      for (gid in gid_total) {
        gidn = gid + 0
        printf "G\t%d\t%s\n", gidn, gid_name[gidn]
      }
    }
  ' "${TMPDIR}/${INVENTORY_NAME}" \
    | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n \
    | while IFS=$'\t' read -r rec_type id name extra; do
        if [ "${rec_type}" = "U" ]; then
          printf '%s:x:%s:%s::/nonexistent:/usr/sbin/nologin\n' "${name}" "${id}" "${extra}" >> "${TMPDIR}/${OWNERS_PASSWD_NAME}"
        elif [ "${rec_type}" = "G" ]; then
          printf '%s:x:%s:\n' "${name}" "${id}" >> "${TMPDIR}/${OWNERS_GROUP_NAME}"
        fi
      done
}

stage_keyfiles() {
  [ -f "${TMPDIR}/${KEYFILES_LIST_NAME}" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local local_p="${ROOT}${f#${TOPDIR}}"
    if [ -f "$local_p" ]; then
      local rel="${f#/}" rel_dir
      rel_dir=$(dirname "$rel")
      mkdir -p "$REF_DIR_STAGE/${rel_dir}"
      echo "Staging $rel" >&2
      cp -p "$local_p" "$REF_DIR_STAGE/${rel}"
    fi
  done < "${TMPDIR}/${KEYFILES_LIST_NAME}"
}

dump_binlinks() {
  : > "${TMPDIR}/${BINLINKS_NAME}"
  collect_bin_roots || return 0
  find "${bin_roots[@]}" -type f -perm -111 \
    | while IFS= read -r bin; do
        echo "=== ${bin#$ROOT} ===" >> "${TMPDIR}/${BINLINKS_NAME}"
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
            ' >> "${TMPDIR}/${BINLINKS_NAME}" || true
      done
}

extract_direct_needed() {
  local bin="$1"
  if command -v readelf >/dev/null 2>&1; then
    readelf -d "$bin" 2>/dev/null \
      | awk '
          /NEEDED/ {
            if (match($0, /\[[^]]+\]/)) {
              print substr($0, RSTART + 1, RLENGTH - 2)
            }
          }
        '
    return 0
  fi
  if command -v objdump >/dev/null 2>&1; then
    objdump -p "$bin" 2>/dev/null \
      | awk '$1 == "NEEDED" { print $2 }'
    return 0
  fi
  return 1
}

normalize_needed_names() {
  sed -E \
    -e 's/\.so(\.[0-9]+)+$/.so/' \
    -e 's/^lib(lber|ldap)(_r)?-[0-9]+(\.[0-9]+)?\.so$/lib\1.so/' \
    -e 's/^libc\.musl-[A-Za-z0-9_]+(\.so(\.[0-9]+)*)?$/libc.so/'
}

dump_needed_norm() {
  : > "${TMPDIR}/${NEEDED_NORM_NAME}"
  collect_bin_roots || return 0
  find "${bin_roots[@]}" -type f -perm -111 \
    | while IFS= read -r bin; do
        extract_direct_needed "$bin" \
          | normalize_needed_names \
          | awk -v exe="${bin#$ROOT}" 'NF { printf "%s\t%s\n", exe, $0 }' \
          >> "${TMPDIR}/${NEEDED_NORM_NAME}" || true
      done
  sort -u "${TMPDIR}/${NEEDED_NORM_NAME}" -o "${TMPDIR}/${NEEDED_NORM_NAME}"
}

dump_embedded() {
  : > "${TMPDIR}/${EMBED_NAME}"
  collect_bin_roots || return 0
  find "${bin_roots[@]}" -type f -perm -111 \
    | while IFS= read -r bin; do
        strings "$bin" | grep -E '/var/lib/xymon' >> "${TMPDIR}/${EMBED_NAME}" || true
      done
  sort -u "${TMPDIR}/${EMBED_NAME}" -o "${TMPDIR}/${EMBED_NAME}"
}

copy_artifacts() {
  for entry in \
    "${INVENTORY_NAME}:inventory.tsv" \
    "${OWNERS_PASSWD_NAME}:owners.passwd" \
    "${OWNERS_GROUP_NAME}:owners.group" \
    "${BINLINKS_NAME}:binlinks" \
    "${NEEDED_NORM_NAME}:needed.norm.tsv" \
    "${EMBED_NAME}:embedded.paths" \
    "${KEYFILES_NAME}:keyfiles.sha256" \
    "${CONFIG_NAME}:meta/config.h" \
    "${CONFIG_DEFINES_NAME}:meta/config.defines"; do
    src="${TMPDIR}/${entry%%:*}"
    dst="${entry#*:}"
    if [ ! -e "$src" ]; then
      echo "Skipping missing $src" >&2
    fi
    copy_to_refs "$src" "$dst"
  done
}

cleanup_temp_files() {
  local temp_files=(
    "${TMPDIR}/${INVENTORY_NAME}"
    "${TMPDIR}/${OWNERS_PASSWD_NAME}"
    "${TMPDIR}/${OWNERS_GROUP_NAME}"
    "${TMPDIR}/${KEYFILES_LIST_NAME}"
    "${TMPDIR}/${KEYFILES_NAME}"
    "${TMPDIR}/${CONFIG_NAME}"
    "${TMPDIR}/${CONFIG_DEFINES_NAME}"
    "${TMPDIR}/${BINLINKS_NAME}"
    "${TMPDIR}/${NEEDED_NORM_NAME}"
    "${TMPDIR}/${EMBED_NAME}"
  )
  for file in "${temp_files[@]}"; do
    rm -f "$file"
  done
}

discover_key_files() {
  local key_tmp rel type key_count
  key_tmp="$(mktemp "${TMPDIR}/xymon-keyfiles.XXXXXX")"
  : > "$key_tmp"

  while IFS=$'\t' read -r _ rel type _; do
    [ "${type}" = "f" ] || continue
    if [[ "$rel" =~ ^/(etc|server/etc|client/etc)/[^/]+\.(cfg|csv)$ ]] \
      || [[ "$rel" =~ ^/(etc|server/etc|client/etc)/[^/]+\.d/ ]]; then
      case "$rel" in
        *.bak|*.DIST|*.orig|*~)
          continue
          ;;
      esac
      printf '%s\n' "${TOPDIR}${rel}" >> "$key_tmp"
    fi
  done < "${TMPDIR}/${INVENTORY_NAME}"

  LC_ALL=C sort -u "$key_tmp" > "${TMPDIR}/${KEYFILES_LIST_NAME}"
  rm -f "$key_tmp"

  key_count="$(wc -l < "${TMPDIR}/${KEYFILES_LIST_NAME}" | awk '{print $1}')"
  echo "Discovered ${key_count} key files" >&2
  [ "${key_count}" -gt 0 ]
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

run_step "Build inventory" build_inventory
run_step "Generate owner maps" generate_owner_maps
run_step "Copy config" copy_config
run_step "Discover key files" discover_key_files
run_step "Generate keyfile list" generate_keyfiles_list
run_step "Stage keyfiles" stage_keyfiles
run_step "Dump binlinks" dump_binlinks
run_step "Dump normalized direct deps" dump_needed_norm
run_step "Dump embedded paths" dump_embedded
run_step "Copy artifacts" copy_artifacts

cleanup_temp_files

if [ "${#error_steps[@]}" -gt 0 ]; then
  echo "Reference generation had issues in the following steps: ${error_steps[*]}" >&2
  exit 1
else
  echo "Reference generation completed successfully." >&2
fi
