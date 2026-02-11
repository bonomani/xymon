#!/usr/bin/env bash
set -euo pipefail

BASELINE_PREFIX=""
CANDIDATE_DIR=""
CANDIDATE_ROOT=""
DIFF_PREVIEW_LINES="${DIFF_PREVIEW_LINES:-120}"

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

write_allowed_extras() {
  cat > /tmp/allowed-extras.list <<'EOF'
/var/lib/xymon/cgi-bin/.stamp
/var/lib/xymon/cgi-secure/.stamp
/var/lib/xymon/install-cmake-legacy.log
/var/lib/xymon/server/bin/availability
/var/lib/xymon/server/bin/contest
/var/lib/xymon/server/bin/loadhosts
/var/lib/xymon/server/bin/locator
/var/lib/xymon/server/bin/md5
/var/lib/xymon/server/bin/rmd160
/var/lib/xymon/server/bin/sha1
/var/lib/xymon/server/bin/stackio
/var/lib/xymon/server/bin/tree
/var/lib/xymon/server/bin/xymon-snmpcollect
EOF
}

emit_sorted_diff() {
  local left="$1" right="$2" out="$3" label="$4" theme_mode="${5:-}"
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
    echo "result: different (non-blocking)"
    emit_theme_summary "$left" "$right" "$theme_mode"
    show_diff_preview "$out"
  else
    echo "result: identical"
  fi
}

emit_diff() {
  local left="$1" right="$2" out="$3" label="$4" theme_mode="${5:-}"
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
    echo "result: different (non-blocking)"
    emit_theme_summary "$left" "$right" "$theme_mode"
    show_diff_preview "$out"
  else
    echo "result: identical"
  fi
}

# Candidate snapshots exported from ci/generate-refs.sh output folder.
copy_if_present "${CANDIDATE_DIR}/binlinks" /tmp/legacy.bin.links
copy_if_present "${CANDIDATE_DIR}/embedded.paths" /tmp/legacy.embedded.paths
copy_if_present "${CANDIDATE_DIR}/keyfiles.sha256" /tmp/legacy.keyfiles.sha256
copy_if_present "${CANDIDATE_DIR}/inventory.tsv" /tmp/legacy.inventory.tsv

# Baseline files.
BASE_INVENTORY="$(resolve_baseline_file inventory.tsv)"
BASE_KEYFILES="$(resolve_baseline_file keyfiles.sha256)"
BASE_BINLINKS="$(resolve_baseline_file binlinks)"
BASE_EMBEDDED="$(resolve_baseline_file embedded.paths)"

if [ ! -s "${BASE_INVENTORY}" ]; then
  echo "Missing or empty baseline inventory: ${BASE_INVENTORY}" >&2
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

emit_sorted_diff "$BASE_INVENTORY_SHAPE" /tmp/legacy.inventory.filtered.shape /tmp/legacy.inventory.diff "Inventory (path/type)" "inventory"
emit_sorted_diff "$BASE_KEYFILES" /tmp/legacy.keyfiles.sha256 /tmp/legacy.keyfiles.sha256.diff "Key file content" "keyfiles"
emit_sorted_diff "$BASE_SYMLINKS" "$CANDIDATE_SYMLINKS" /tmp/legacy.symlinks.diff "Symlink target" "symlink"
emit_sorted_diff "$BASE_PERMS" "$CANDIDATE_PERMS" /tmp/legacy.perms.diff "Permissions (mode only)" "perms"
emit_sorted_diff "$BASE_OWNERS" "$CANDIDATE_OWNERS" /tmp/legacy.owners.diff "Ownership (uid/gid, informational)" "owners"
emit_diff "$BASE_BINLINKS" /tmp/legacy.bin.links /tmp/legacy.binlinks.diff "Binary linkage"
emit_diff "$BASE_EMBEDDED" /tmp/legacy.embedded.paths /tmp/legacy.embedded.diff "Embedded path"

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
    echo "result: different (non-blocking)"
    emit_theme_summary /tmp/legacy.list /tmp/cmake.filtered.list "tree"
    show_diff_preview /tmp/legacy-cmake.diff
  else
    echo "result: identical"
  fi
else
  echo "skip: baseline or candidate missing/empty"
fi

echo "Reference comparison completed."
