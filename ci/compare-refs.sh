#!/usr/bin/env bash
set -euo pipefail

BASELINE_PREFIX=""
CANDIDATE_DIR=""
CANDIDATE_ROOT=""

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

emit_sorted_diff() {
  local left="$1" right="$2" out="$3" label="$4"
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
    cat "$out"
  else
    echo "result: identical"
  fi
}

emit_diff() {
  local left="$1" right="$2" out="$3" label="$4"
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
    cat "$out"
  else
    echo "result: identical"
  fi
}

# Candidate snapshots exported from ci/generate-refs.sh output folder.
copy_if_present "${CANDIDATE_DIR}/symlinks" /tmp/legacy.symlinks.list
copy_if_present "${CANDIDATE_DIR}/perms" /tmp/legacy.perms.snapshot
copy_if_present "${CANDIDATE_DIR}/binlinks" /tmp/legacy.bin.links
copy_if_present "${CANDIDATE_DIR}/embedded.paths" /tmp/legacy.embedded.paths
copy_if_present "${CANDIDATE_DIR}/keyfiles.sha256" /tmp/legacy.keyfiles.sha256
copy_if_present "${CANDIDATE_DIR}/ref" /tmp/cmake.list

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

# Baseline files.
BASE_KEYFILES="$(resolve_baseline_file keyfiles.sha256)"
BASE_SYMLINKS="$(resolve_baseline_file symlinks)"
BASE_PERMS="$(resolve_baseline_file perms)"
BASE_BINLINKS="$(resolve_baseline_file binlinks)"
BASE_EMBEDDED="$(resolve_baseline_file embedded.paths)"
BASE_REF="$(resolve_baseline_file ref)"

emit_sorted_diff "$BASE_KEYFILES" /tmp/legacy.keyfiles.sha256 /tmp/legacy.keyfiles.sha256.diff "Key file content"
emit_sorted_diff "$BASE_SYMLINKS" /tmp/legacy.symlinks.list /tmp/legacy.symlinks.diff "Symlink target"
emit_sorted_diff "$BASE_PERMS" /tmp/legacy.perms.snapshot /tmp/legacy.perms.diff "Permissions"
emit_diff "$BASE_BINLINKS" /tmp/legacy.bin.links /tmp/legacy.binlinks.diff "Binary linkage"
emit_diff "$BASE_EMBEDDED" /tmp/legacy.embedded.paths /tmp/legacy.embedded.diff "Embedded path"

: > /tmp/legacy.list
: > /tmp/cmake.filtered.list
: > /tmp/allowed-extras.list
: > /tmp/legacy-cmake.diff
echo "=== Compare: Tree reference ==="
if [ -s "$BASE_REF" ]; then
  echo "baseline: ${BASE_REF} ($(wc -l < "$BASE_REF") lines)"
else
  echo "baseline: ${BASE_REF} (missing or empty)"
fi
if [ -s /tmp/cmake.list ]; then
  echo "candidate: /tmp/cmake.list ($(wc -l < /tmp/cmake.list) lines)"
else
  echo "candidate: /tmp/cmake.list (missing or empty)"
fi
if [ -s "$BASE_REF" ] && [ -s /tmp/cmake.list ]; then
  grep -v '^[[:space:]]*#' "$BASE_REF" | grep -v '^[[:space:]]*$' \
    | sed 's|/var/lib/xymon/$|/var/lib/xymon|' | sort > /tmp/legacy.list
  sort /tmp/cmake.list > /tmp/cmake.list.sorted
  mv /tmp/cmake.list.sorted /tmp/cmake.list

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
  grep -v -F -x -f /tmp/allowed-extras.list /tmp/cmake.list > /tmp/cmake.filtered.list
  diff -u /tmp/legacy.list /tmp/cmake.filtered.list > /tmp/legacy-cmake.diff || true
  if [ -s /tmp/legacy-cmake.diff ]; then
    echo "result: different (non-blocking)"
    cat /tmp/legacy-cmake.diff
  else
    echo "result: identical"
  fi
else
  echo "skip: baseline or candidate missing/empty"
fi

echo "Reference comparison completed."
