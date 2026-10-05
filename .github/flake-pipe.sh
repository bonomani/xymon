#!/usr/bin/env bash
# The link-flags rule both ways, looped: the old pipe and the new here-string.
set -uo pipefail
f=$1; n=$2
code=$(grep -vE '^[[:space:]]*#' "$f" || true)
echo "file $f: ${#code} bytes of code"
pm=0; hm=0
for i in $(seq 1 "$n"); do
	printf '%s\n' "$code" | grep -q 'xymon_ldflags'; st="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
	[ "$st" = "0 0" ] || pm=$((pm+1))
	grep -q 'xymon_ldflags' <<<"$code" || hm=$((hm+1))
done
echo "pipe (old): $pm false misses of $n | here-string (new): $hm false misses of $n"
