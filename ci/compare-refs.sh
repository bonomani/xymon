#!/usr/bin/env bash
set -euo pipefail

BASELINE_PREFIX=""
CANDIDATE_DIR=""
CANDIDATE_ROOT=""
DIFF_PREVIEW_LINES="${DIFF_PREVIEW_LINES:-120}"
BLOCKING_FAILURE=0

usage() {
  cat <<'USAGE' >&2
Usage: $0 --baseline-prefix PATH_OR_DIR --candidate-dir DIR [--candidate-root DIR]
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline-prefix)
      BASELINE_PREFIX="${2:-}"
      shift 2
      ;;
    --candidate-dir)
      CANDIDATE_DIR="${2:-}"
      shift 2
      ;;
    --candidate-root)
      CANDIDATE_ROOT="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      ;;
  esac
done

[ -n "$BASELINE_PREFIX" ] || { echo "Missing --baseline-prefix" >&2; exit 1; }
[ -n "$CANDIDATE_DIR" ] || { echo "Missing --candidate-dir" >&2; exit 1; }
[ -d "$CANDIDATE_DIR" ] || { echo "Missing candidate dir: $CANDIDATE_DIR" >&2; exit 1; }

copy_if_present() {
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    cp -p "$src" "$dst"
  else
    : > "$dst"
  fi
}

resolve_baseline_file() {
  local name="$1"
  if [ -d "$BASELINE_PREFIX" ]; then
    echo "${BASELINE_PREFIX}/${name}"
  else
    echo "${BASELINE_PREFIX}.${name}"
  fi
}

emit_theme_summary() {
  local left="$1" right="$2" mode="$3"
  local summary
  [ -n "$mode" ] || return 0
  [ -s "$left" ] || return 0
  [ -s "$right" ] || return 0

  summary="$(mktemp /tmp/xymon-theme-summary.XXXXXX)"
  awk -v mode="$mode" '
    function theme_from_path(path,    clean, n, a) {
      clean = path
      sub(/^\/var\/lib\/xymon\/?/, "", clean)
      sub(/^\/+/, "", clean)
      if (clean == "") return "(root)"
      n = split(clean, a, "/")
      if ((a[1] == "server" || a[1] == "client") && n >= 2) return a[1] "/" a[2]
      if (a[1] == "cgi-bin" || a[1] == "cgi-secure") return a[1]
      return a[1]
    }

    function parse_record(line, kind,    parts, n, hash) {
      rec_key = ""
      rec_val = ""
      if (line == "") return

      if (kind == "inventory") {
        if (index(line, "\t") > 0) {
          n = split(line, parts, "\t")
          rec_key = parts[1]
          rec_val = line
          sub(/^[^\t]*\t/, "", rec_val)
        } else {
          n = split(line, parts, /\|/)
          rec_key = parts[1]
          rec_val = parts[2]
        }
        return
      }

      if (kind == "perms" || kind == "symlink" || kind == "owners") {
        n = split(line, parts, /\|/)
        rec_key = parts[1]
        rec_val = line
        sub(/^[^|]*\|/, "", rec_val)
        return
      }

      if (kind == "keyfiles") {
        if (line ~ /^MISSING[[:space:]]+/) {
          rec_key = line
          sub(/^MISSING[[:space:]]+/, "", rec_key)
          rec_val = "MISSING"
          return
        }
        rec_key = line
        sub(/^[^[:space:]]+[[:space:]]+/, "", rec_key)
        hash = line
        sub(/[[:space:]].*$/, "", hash)
        rec_val = hash
        return
      }

      if (kind == "tree") {
        rec_key = line
        rec_val = "present"
      }
    }

    FNR == NR {
      parse_record($0, mode)
      if (rec_key == "") next
      base_val[rec_key] = rec_val
      base_theme[rec_key] = theme_from_path(rec_key)
      next
    }

    {
      parse_record($0, mode)
      if (rec_key == "") next
      cand_val[rec_key] = rec_val
      cand_theme[rec_key] = theme_from_path(rec_key)
    }

    END {
      for (k in base_val) {
        t = base_theme[k]
        if (!(k in cand_val)) removed[t]++
        else if (base_val[k] != cand_val[k]) changed[t]++
      }
      for (k in cand_val) {
        t = cand_theme[k]
        if (!(k in base_val)) added[t]++
      }

      for (t in added) {
        if ((added[t] + removed[t] + changed[t]) > 0) printf "%s\t%d\t%d\t%d\n", t, added[t] + 0, removed[t] + 0, changed[t] + 0
      }
      for (t in removed) {
        if (!(t in added) && (added[t] + removed[t] + changed[t]) > 0) printf "%s\t%d\t%d\t%d\n", t, added[t] + 0, removed[t] + 0, changed[t] + 0
      }
      for (t in changed) {
        if (!(t in added) && !(t in removed) && (added[t] + removed[t] + changed[t]) > 0) printf "%s\t%d\t%d\t%d\n", t, added[t] + 0, removed[t] + 0, changed[t] + 0
      }
    }
  ' "$left" "$right" | sort > "$summary"

  if [ -s "$summary" ]; then
    echo "theme summary (+ added, - removed, ~ changed):"
    while IFS=$'\t' read -r theme added removed changed; do
      printf '  %s: +%s -%s ~%s\n' "$theme" "$added" "$removed" "$changed"
    done < "$summary"
  fi
  rm -f "$summary"
}

show_diff_preview() {
  local diff_file="$1"
  local total limit
  [ -s "$diff_file" ] || return 0

  total="$(wc -l < "$diff_file")"
  limit="$DIFF_PREVIEW_LINES"
  if [ "$total" -le "$limit" ]; then
    cat "$diff_file"
    return 0
  fi

  sed -n "1,${limit}p" "$diff_file"
  echo "... diff truncated (${total} lines total; showing first ${limit}; full diff in ${diff_file})"
}

derive_views_from_inventory() {
  local inventory="$1" out_ref="$2" out_perms="$3" out_symlinks="$4" out_owners="$5" out_inventory_shape="$6"
  : > "$out_ref"
  : > "$out_perms"
  : > "$out_symlinks"
  : > "$out_owners"
  : > "$out_inventory_shape"
  if [ ! -s "$inventory" ]; then
    return 0
  fi

  awk -F $'\t' '{print $1}' "$inventory" > "$out_ref"
  awk -F $'\t' '{ printf "%s|%s\n", $1, $3 }' "$inventory" > "$out_inventory_shape"
  awk -F $'\t' '($3 == "f" || $3 == "d") { printf "%s|%s\n", $2, $4 }' \
    "$inventory" > "$out_perms"
  awk -F $'\t' '$3 == "l" { printf "%s|%s\n", $2, $8 }' "$inventory" > "$out_symlinks"
  awk -F $'\t' '($3 == "f" || $3 == "d") { printf "%s|%s|%s\n", $2, $5, $6 }' \
    "$inventory" > "$out_owners"
}

is_container_runtime() {
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    return 0
  fi
  if [ -r /proc/1/cgroup ] && grep -qaE '(docker|containerd|kubepods|podman|lxc)' /proc/1/cgroup; then
    return 0
  fi
  [ "${container:-}" = "docker" ] || [ "${container:-}" = "podman" ]
}

render_owner_names() {
  local src="$1" dst="$2" passwd_map="$3" group_map="$4"
  : > "$dst"
  if [ ! -s "$src" ]; then
    return 0
  fi

  declare -A map_uid=()
  declare -A map_gid=()
  while IFS=':' read -r name _ uid _ _; do
    [ -n "$name" ] || continue
    [ -n "$uid" ] || continue
    map_uid[$uid]="$name"
  done < "$passwd_map"
  while IFS=':' read -r name _ gid _; do
    [ -n "$name" ] || continue
    [ -n "$gid" ] || continue
    map_gid[$gid]="$name"
  done < "$group_map"

  local has_getent=0
  if command -v getent >/dev/null 2>&1; then
    has_getent=1
  fi
  declare -A uid_cache=()
  declare -A gid_cache=()
  local path uid gid user_name group_name
  while IFS='|' read -r path uid gid; do
    if [ -z "${uid_cache[$uid]+x}" ]; then
      user_name="${map_uid[$uid]:-}"
      if [ -z "$user_name" ] && [ "$has_getent" -eq 1 ]; then
        user_name="$(getent passwd "$uid" | awk -F: 'NR==1 {print $1}')"
      fi
      [ -n "$user_name" ] || user_name="$uid"
      uid_cache[$uid]="$user_name"
    fi
    if [ -z "${gid_cache[$gid]+x}" ]; then
      group_name="${map_gid[$gid]:-}"
      if [ -z "$group_name" ] && [ "$has_getent" -eq 1 ]; then
        group_name="$(getent group "$gid" | awk -F: 'NR==1 {print $1}')"
      fi
      [ -n "$group_name" ] || group_name="$gid"
      gid_cache[$gid]="$group_name"
    fi

    printf '%s|%s|%s\n' "$path" "${uid_cache[$uid]}" "${gid_cache[$gid]}" >> "$dst"
  done < "$src"
}

write_allowed_extras() {
  cat > /tmp/allowed-extras.list <<'EOF'
/var/lib/xymon/cgi-bin/.stamp
/var/lib/xymon/cgi-secure/.stamp
/var/lib/xymon/install-cmake-legacy.log
EOF
}

emit_sorted_diff() {
  local left="$1" right="$2" out="$3" label="$4" theme_mode="${5:-}" severity="${6:-non-blocking}"
  local left_sorted right_sorted
  : > "$out"
  echo "=== Compare: ${label} ==="
  if [ -s "$left" ]; then
    echo "baseline: ${left} ($(wc -l < "$left") lines)"
  else
    echo "baseline: ${left} (missing or empty)"
  fi
  if [ -s "$right" ]; then
    echo "candidate: ${right} ($(wc -l < "$right") lines)"
  else
    echo "candidate: ${right} (missing or empty)"
  fi
  if [ ! -s "$left" ]; then
    echo "skip: baseline missing/empty"
    return 0
  fi
  if [ ! -s "$right" ]; then
    echo "skip: candidate missing/empty"
    return 0
  fi
  left_sorted="$(mktemp /tmp/xymon-compare-left.XXXXXX)"
  right_sorted="$(mktemp /tmp/xymon-compare-right.XXXXXX)"
  sort "$left" > "$left_sorted"
  sort "$right" > "$right_sorted"
  diff -u "$left_sorted" "$right_sorted" > "$out" || true
  rm -f "$left_sorted" "$right_sorted"
  if [ -s "$out" ]; then
    echo "result: different (${severity})"
    if [ "$severity" = "blocking" ]; then
      BLOCKING_FAILURE=1
      echo "blocking: ${label} mismatch"
    fi
    emit_theme_summary "$left" "$right" "$theme_mode"
    show_diff_preview "$out"
  else
    echo "result: identical"
  fi
}

emit_diff() {
  local left="$1" right="$2" out="$3" label="$4" theme_mode="${5:-}" severity="${6:-non-blocking}"
  : > "$out"
  echo "=== Compare: ${label} ==="
  if [ -s "$left" ]; then
    echo "baseline: ${left} ($(wc -l < "$left") lines)"
  else
    echo "baseline: ${left} (missing or empty)"
  fi
  if [ -s "$right" ]; then
    echo "candidate: ${right} ($(wc -l < "$right") lines)"
  else
    echo "candidate: ${right} (missing or empty)"
  fi
  if [ ! -s "$left" ]; then
    echo "skip: baseline missing/empty"
    return 0
  fi
  if [ ! -s "$right" ]; then
    echo "skip: candidate missing/empty"
    return 0
  fi
  diff -u "$left" "$right" > "$out" || true
  if [ -s "$out" ]; then
    echo "result: different (${severity})"
    if [ "$severity" = "blocking" ]; then
      BLOCKING_FAILURE=1
      echo "blocking: ${label} mismatch"
    fi
    emit_theme_summary "$left" "$right" "$theme_mode"
    show_diff_preview "$out"
  else
    echo "result: identical"
  fi
}

filter_keyfiles_dynamic() {
  local src="$1" dst="$2"
  : > "$dst"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line##*  }"
    case "$path" in
      /var/lib/xymon/server/etc/xymonserver.cfg|/var/lib/xymon/client/etc/xymonclient.cfg)
        continue
        ;;
    esac
    printf '%s\n' "$line" >> "$dst"
  done < "$src"
}

normalize_needed_tsv() {
  local src="$1" dst="$2"
  : > "$dst"
  if [ ! -s "$src" ]; then
    return 0
  fi
  awk -F $'\t' '
    function norm(lib, out) {
      out = lib
      sub(/\.so(\.[0-9]+)+$/, ".so", out)
      sub(/^liblber(_r)?-[0-9]+(\.[0-9]+)?\.so$/, "liblber.so", out)
      sub(/^libldap(_r)?-[0-9]+(\.[0-9]+)?\.so$/, "libldap.so", out)
      return out
    }
    NF >= 2 {
      $2 = norm($2)
      print $1 "\t" $2
    }
  ' "$src" | sort -u > "$dst"
}

# Candidate snapshots exported from ci/generate-refs.sh output folder.
copy_if_present "${CANDIDATE_DIR}/binlinks" /tmp/legacy.bin.links
copy_if_present "${CANDIDATE_DIR}/needed.norm.tsv" /tmp/legacy.needed.norm.tsv
copy_if_present "${CANDIDATE_DIR}/embedded.paths" /tmp/legacy.embedded.paths
copy_if_present "${CANDIDATE_DIR}/keyfiles.sha256" /tmp/legacy.keyfiles.sha256
copy_if_present "${CANDIDATE_DIR}/inventory.tsv" /tmp/legacy.inventory.tsv

# Baseline files.
BASE_INVENTORY="$(resolve_baseline_file inventory.tsv)"
BASE_OWNER_PASSWD="$(resolve_baseline_file owners.passwd)"
BASE_OWNER_GROUP="$(resolve_baseline_file owners.group)"
BASE_KEYFILES="$(resolve_baseline_file keyfiles.sha256)"
BASE_BINLINKS="$(resolve_baseline_file binlinks)"
BASE_NEEDED_NORM="$(resolve_baseline_file needed.norm.tsv)"
BASE_EMBEDDED="$(resolve_baseline_file embedded.paths)"

if [ ! -s "${BASE_INVENTORY}" ]; then
  echo "Missing or empty baseline inventory: ${BASE_INVENTORY}" >&2
  exit 1
fi
if [ ! -s "${BASE_OWNER_PASSWD}" ]; then
  echo "Missing or empty baseline owner passwd map: ${BASE_OWNER_PASSWD}" >&2
  exit 1
fi
if [ ! -s "${BASE_OWNER_GROUP}" ]; then
  echo "Missing or empty baseline owner group map: ${BASE_OWNER_GROUP}" >&2
  exit 1
fi
if [ ! -s /tmp/legacy.inventory.tsv ]; then
  echo "Missing or empty candidate inventory: /tmp/legacy.inventory.tsv" >&2
  exit 1
fi

BASE_REF="/tmp/baseline.ref"
BASE_SYMLINKS="/tmp/baseline.symlinks"
BASE_PERMS="/tmp/baseline.perms"
BASE_OWNERS="/tmp/baseline.owners"
BASE_INVENTORY_SHAPE="/tmp/baseline.inventory.shape"
derive_views_from_inventory "${BASE_INVENTORY}" "${BASE_REF}" "${BASE_PERMS}" "${BASE_SYMLINKS}" "${BASE_OWNERS}" "${BASE_INVENTORY_SHAPE}"

CANDIDATE_REF="/tmp/cmake.list"
CANDIDATE_SYMLINKS="/tmp/legacy.symlinks.list"
CANDIDATE_PERMS="/tmp/legacy.perms.snapshot"
CANDIDATE_OWNERS="/tmp/legacy.owners.snapshot"
CANDIDATE_INVENTORY_SHAPE="/tmp/legacy.inventory.shape"
derive_views_from_inventory /tmp/legacy.inventory.tsv "${CANDIDATE_REF}" "${CANDIDATE_PERMS}" "${CANDIDATE_SYMLINKS}" "${CANDIDATE_OWNERS}" "${CANDIDATE_INVENTORY_SHAPE}"
write_allowed_extras
awk -F '|' '
  NR == FNR { skip[$1] = 1; next }
  !($1 in skip)
' /tmp/allowed-extras.list "${CANDIDATE_INVENTORY_SHAPE}" > /tmp/legacy.inventory.filtered.shape

: > /tmp/legacy.keyfiles.missing
if [ -s /tmp/legacy.keyfiles.sha256 ]; then
  { grep '^MISSING ' /tmp/legacy.keyfiles.sha256 || true; } > /tmp/legacy.keyfiles.missing
fi

# Optional richer metadata from actual staged root.
: > /tmp/legacy.symlinks.broken
: > /tmp/legacy.keyfiles.perms
if [ -n "$CANDIDATE_ROOT" ] && [ -d "$CANDIDATE_ROOT" ]; then
  while IFS= read -r link; do
    if [ ! -e "$link" ]; then
      printf '%s\n' "${link#/tmp/cmake-ref-root}" >> /tmp/legacy.symlinks.broken
    fi
  done < <(find "$CANDIDATE_ROOT" -type l)

  if [ -s /tmp/legacy.keyfiles.sha256 ]; then
    while IFS= read -r line; do
      case "$line" in
        MISSING\ *)
          continue
          ;;
      esac
      f="${line##*  }"
      p="${CANDIDATE_ROOT}${f#/var/lib/xymon}"
      [ -e "$p" ] || continue
      case "$(uname -s)" in
        Darwin|FreeBSD|OpenBSD|NetBSD)
          mode=$(stat -f '%Lp' "$p")
          uid=$(stat -f '%u' "$p")
          gid=$(stat -f '%g' "$p")
          size=$(stat -f '%z' "$p")
          printf '%s|%s|%s|%s|%s\n' "$f" "$mode" "$uid" "$gid" "$size" >> /tmp/legacy.keyfiles.perms
          ;;
        *)
          stat -c '%n|%a|%u|%g|%s' "$p" | sed "s|$p|$f|" >> /tmp/legacy.keyfiles.perms
          ;;
      esac
    done < /tmp/legacy.keyfiles.sha256
  fi
fi

emit_sorted_diff "$BASE_INVENTORY_SHAPE" /tmp/legacy.inventory.filtered.shape /tmp/legacy.inventory.diff "Inventory (path/type)" "inventory" "blocking"
filter_keyfiles_dynamic "$BASE_KEYFILES" /tmp/baseline.keyfiles.filtered
filter_keyfiles_dynamic /tmp/legacy.keyfiles.sha256 /tmp/legacy.keyfiles.filtered
emit_sorted_diff /tmp/baseline.keyfiles.filtered /tmp/legacy.keyfiles.filtered /tmp/legacy.keyfiles.sha256.diff "Key file content" "keyfiles" "blocking"
emit_sorted_diff "$BASE_SYMLINKS" "$CANDIDATE_SYMLINKS" /tmp/legacy.symlinks.diff "Symlink target" "symlink" "blocking"
emit_sorted_diff "$BASE_PERMS" "$CANDIDATE_PERMS" /tmp/legacy.perms.diff "Permissions (mode only)" "perms" "blocking"
emit_sorted_diff "$BASE_OWNERS" "$CANDIDATE_OWNERS" /tmp/legacy.owners.diff "Ownership (uid/gid, informational)" "owners"
if [ -s /tmp/legacy.owners.diff ]; then
  if is_container_runtime; then
    echo "note: container runtime detected; ownership uid/gid may differ from host refs unless ownership is applied."
  fi
  BASE_OWNERS_DISPLAY="/tmp/baseline.owners.display"
  CANDIDATE_OWNERS_DISPLAY="/tmp/legacy.owners.display"
  render_owner_names "$BASE_OWNERS" "$BASE_OWNERS_DISPLAY" "$BASE_OWNER_PASSWD" "$BASE_OWNER_GROUP"
  render_owner_names "$CANDIDATE_OWNERS" "$CANDIDATE_OWNERS_DISPLAY" "$BASE_OWNER_PASSWD" "$BASE_OWNER_GROUP"
  emit_sorted_diff "$BASE_OWNERS_DISPLAY" "$CANDIDATE_OWNERS_DISPLAY" /tmp/legacy.owners.names.diff "Ownership (user/group fallback, informational)" "owners"
fi
emit_diff "$BASE_BINLINKS" /tmp/legacy.bin.links /tmp/legacy.binlinks.diff "Binary linkage"
normalize_needed_tsv "$BASE_NEEDED_NORM" /tmp/baseline.needed.norm.canon
normalize_needed_tsv /tmp/legacy.needed.norm.tsv /tmp/legacy.needed.norm.canon
emit_sorted_diff /tmp/baseline.needed.norm.canon /tmp/legacy.needed.norm.canon /tmp/legacy.needed.norm.diff "Direct dependencies (normalized SONAME)" "needed" "non-blocking"
comm -23 /tmp/baseline.needed.norm.canon /tmp/legacy.needed.norm.canon > /tmp/legacy.needed.norm.missing
comm -13 /tmp/baseline.needed.norm.canon /tmp/legacy.needed.norm.canon > /tmp/legacy.needed.norm.extra
if [ -s /tmp/legacy.needed.norm.missing ]; then
  echo "blocking: candidate missing baseline direct dependencies"
  cat /tmp/legacy.needed.norm.missing
  BLOCKING_FAILURE=1
fi
if [ -s /tmp/legacy.needed.norm.extra ]; then
  echo "note: candidate introduces extra direct dependencies (bin/soname)"
  head -n 20 /tmp/legacy.needed.norm.extra
fi
emit_diff "$BASE_EMBEDDED" /tmp/legacy.embedded.paths /tmp/legacy.embedded.diff "Embedded path" "" "blocking"

: > /tmp/legacy.list
: > /tmp/cmake.filtered.list
: > /tmp/legacy-cmake.diff
echo "=== Compare: Tree reference ==="
if [ -s "$BASE_REF" ]; then
  echo "baseline: ${BASE_REF} ($(wc -l < "$BASE_REF") lines)"
else
  echo "baseline: ${BASE_REF} (missing or empty)"
fi
if [ -s "$CANDIDATE_REF" ]; then
  echo "candidate: ${CANDIDATE_REF} ($(wc -l < "$CANDIDATE_REF") lines)"
else
  echo "candidate: ${CANDIDATE_REF} (missing or empty)"
fi
if [ -s "$BASE_REF" ] && [ -s "$CANDIDATE_REF" ]; then
  grep -v '^[[:space:]]*#' "$BASE_REF" | grep -v '^[[:space:]]*$' \
    | sed 's|/var/lib/xymon/$|/var/lib/xymon|' | sort > /tmp/legacy.list
  sort "$CANDIDATE_REF" > /tmp/cmake.list.sorted
  mv /tmp/cmake.list.sorted "$CANDIDATE_REF"

  grep -v -F -x -f /tmp/allowed-extras.list "$CANDIDATE_REF" > /tmp/cmake.filtered.list
  diff -u /tmp/legacy.list /tmp/cmake.filtered.list > /tmp/legacy-cmake.diff || true
  if [ -s /tmp/legacy-cmake.diff ]; then
    echo "result: different (blocking)"
    BLOCKING_FAILURE=1
    echo "blocking: Tree reference mismatch"
    emit_theme_summary /tmp/legacy.list /tmp/cmake.filtered.list "tree"
    show_diff_preview /tmp/legacy-cmake.diff
  else
    echo "result: identical"
  fi
else
  echo "skip: baseline or candidate missing/empty"
fi

if [ "$BLOCKING_FAILURE" -ne 0 ]; then
  echo "Reference comparison failed due to blocking differences." >&2
  exit 1
fi

echo "Reference comparison completed."
