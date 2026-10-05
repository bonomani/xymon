#!/usr/bin/env bash
set -euo pipefail
f=$1; n=$2
code=$(grep -vE '^[[:space:]]*#' "$f" || true)
echo "file $f: ${#code} bytes of code"
miss=0; rcs=""
for i in $(seq 1 "$n"); do
	if printf '%s\n' "$code" | grep -q 'xymon_cflags'; then :; else miss=$((miss+1)); rcs="$rcs ${PIPESTATUS[*]}"; fi
done
echo "false misses: $miss of $n  (pipe statuses:${rcs:- none})"
