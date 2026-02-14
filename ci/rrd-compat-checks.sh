#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-all}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

create_mock_rrd_header() {
  local out="$1"
  local mode="$2"
  {
    echo '#ifndef RRD_H'
    echo '#define RRD_H'
    echo '#include <time.h>'
    echo 'typedef double rrd_value_t;'
    echo 'int rrd_clear_error(void);'
    if [[ "$mode" == "new" ]]; then
      echo 'int rrd_update(int, const char **);'
      echo 'int rrd_create(int, const char **);'
      echo 'int rrd_fetch(int, const char **, time_t *, time_t *, unsigned long *, unsigned long *, char ***, rrd_value_t **);'
      echo 'int rrd_graph(int, const char **, char ***, int *, int *);'
    else
      echo 'int rrd_update(int, char **);'
      echo 'int rrd_create(int, char **);'
      echo 'int rrd_fetch(int, char **, time_t *, time_t *, unsigned long *, unsigned long *, char ***, rrd_value_t **);'
      echo 'int rrd_graph(int, char **, char ***, int *, int *, void *, double *, double *);'
    fi
    echo '#endif'
  } >"$out"
}

run_abi_check() {
  (
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    mkdir -p "$tmpdir/old" "$tmpdir/new"
    create_mock_rrd_header "$tmpdir/old/rrd.h" old
    create_mock_rrd_header "$tmpdir/new/rrd.h" new

    cc -I"$tmpdir/old" -I"$ROOT_DIR/include" -DRRD_CONST_ARGS=0 -DRRDTOOL12 \
      -c "$ROOT_DIR/build/test-rrd.c" -o "$tmpdir/old.o"
    cc -I"$tmpdir/new" -I"$ROOT_DIR/include" -DRRD_CONST_ARGS=1 \
      -c "$ROOT_DIR/build/test-rrd.c" -o "$tmpdir/new.o"
  )
}

run_strict_policy_check() {
  (
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    mkdir -p "$tmpdir/old"
    create_mock_rrd_header "$tmpdir/old/rrd.h" old

    if cc -I"$tmpdir/old" -I"$ROOT_DIR/include" \
      -c "$ROOT_DIR/build/test-rrd.c" -o "$tmpdir/should-fail.o" \
      >/dev/null 2>"$tmpdir/err.log"; then
      echo "Expected failure when RRD_CONST_ARGS is undefined"
      exit 1
    fi

    cc -I"$tmpdir/old" -I"$ROOT_DIR/include" -DXYMON_ASSUME_RRD_MUTABLE_ARGS=1 -DRRDTOOL12 \
      -c "$ROOT_DIR/build/test-rrd.c" -o "$tmpdir/fallback-ok.o"
  )
}

run_direct_call_guard() {
  local file
  for file in "$ROOT_DIR/xymond/do_rrd.c" "$ROOT_DIR/web/perfdata.c" "$ROOT_DIR/web/showgraph.c"; do
    if rg -n '(^|[^a-zA-Z0-9_])rrd_(update|create|fetch|graph)\s*\(' "$file" \
      | rg -v '^[0-9]+:\s*(/\*|\*|//)' >/dev/null; then
      rg -n '(^|[^a-zA-Z0-9_])rrd_(update|create|fetch|graph)\s*\(' "$file" \
        | rg -v '^[0-9]+:\s*(/\*|\*|//)' || true
      echo "Direct RRDtool API call found in $file"
      return 1
    fi
  done
}

case "$MODE" in
  abi)
    run_abi_check
    ;;
  strict)
    run_strict_policy_check
    ;;
  guard)
    run_direct_call_guard
    ;;
  all)
    run_abi_check
    run_strict_policy_check
    run_direct_call_guard
    ;;
  *)
    echo "Usage: $0 [abi|strict|guard|all]" >&2
    exit 2
    ;;
esac
