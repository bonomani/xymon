#!/usr/bin/env bash
# The link-flags rule's pipe, looped; on a miss, record each stage's status
# immediately (PIPESTATUS is reset by the next command).
set -uo pipefail
f=$1; n=$2
code=$(grep -vE '^[[:space:]]*#' "$f" || true)
echo "file $f: ${#code} bytes of code"
miss=0; seen=""
for i in $(seq 1 "$n"); do
	printf '%s\n' "$code" | grep -q 'xymon_ldflags'
	st="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
	if [ "$st" != "0 0" ]; then
		miss=$((miss+1)); seen="$seen [$st]"
	fi
done
echo "false misses: $miss of $n  (printf grep statuses:${seen:- none})"
