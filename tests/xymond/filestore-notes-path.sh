#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymond/filestore-notes-path.sh
#
# Regression guard for the two update_file() defects in xymond_filestore.
#
# 1. The @@notes handler built its destination as basename(filedir)/hostname
#    -- a cwd-relative base, from the basename of the configured directory --
#    with the host part taken verbatim from the message. xymond deliberately
#    does not validate the ID on notes messages.
#
# 2. update_file() wrote through its fopen() handle without checking it. A
#    destination that cannot be opened for writing therefore reached
#    fwrite(msg, len, 1, NULL) and crashed the worker. A "." ID reaches
#    exactly that: update_file() writes to "$dir/.$base", so "." lands on
#    the directory itself, which fopen(..., "w") refuses.
#
# Workers read their messages from stdin (xymond_worker.c), so this drives
# the real binary and checks the filesystem.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
command -v make >/dev/null 2>&1 || skip "make not available"
[ -f "$ROOT/include/config.h" ] || skip "tree not configured (no include/config.h)"
[ -f "$ROOT/Makefile" ] || skip "tree not configured (no Makefile)"

ssllibs=$(sed -n 's/^SSLLIBS *= *//p' "$ROOT/Makefile")
pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

work=$(mktemp -d "${TMPDIR:-/tmp}/xymon-filestore-notes.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

make -C "$ROOT/lib" libxymon.a libxymoncomm.a libxymontime.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot build the xymon libraries"; }

# FILESTOREOBJS = xymond_filestore.o xymond_worker.o (xymond/Makefile).
# Archives listed twice rather than --start-group, which is GNU ld only.
"$CC" -I"$ROOT/include" -I"$ROOT/lib" -I"$ROOT/xymond" -o "$work/xymond_filestore" \
	"$ROOT/xymond/xymond_filestore.c" "$ROOT/xymond/xymond_worker.c" \
	"$ROOT/lib/libxymon.a" "$ROOT/lib/libxymoncomm.a" "$ROOT/lib/libxymontime.a" \
	"$ROOT/lib/libxymon.a" \
	$pcre_libs $ssllibs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "xymond_filestore does not build -- cannot verify the notes path"; }

mkdir -p "$work/etc"
cp "$ROOT/xymond/etcfiles/xymonserver.cfg.DIST" "$work/etc/xymonserver.cfg"

setup() {
	rm -rf "$work/var"
	mkdir -p "$work/var/notes" "$work/var/sibling" "$work/var/logs" "$work/var/html"
	printf 'CANARY-OUTSIDE-NOTES\n' >"$work/var/CANARY.txt"
	printf 'sibling content\n'      >"$work/var/sibling/keepme"
}

notes() {  # notes <id>
	local rc
	set +e
	printf '@@notes#1|1785830400|10.0.0.99|%s\nNOTE PAYLOAD\n@@\n' "$1" \
	| XYMONHOME="$work" XYMONVAR="$work/var" \
		"$work/xymond_filestore" --env="$work/etc/xymonserver.cfg" \
		--notes --dir="$work/var/notes" >/dev/null 2>>"$work/worker.log"
	rc=$?
	set -e
	# 0 is the normal exit when the input pipe closes. A crash (139) is how
	# the unchecked fopen() handle failed, so it must not read as "refused".
	[ "$rc" -le 1 ] || fail "xymond_filestore exited $rc (crash?) on notes ID '$1'"
}

# Sanity first: if nothing is ever written here, every "did not escape"
# assertion below holds vacuously.
setup
: >"$work/worker.log"
notes "realhost"
[ -f "$work/var/notes/realhost" ] \
	|| { cat "$work/worker.log" >&2; fail "a legitimate notes message was not stored -- the checks below would pass vacuously"; }
assert_contains "NOTE PAYLOAD" "$(cat "$work/var/notes/realhost")" "notes payload not stored"

# No ID may put a file outside the configured notes directory, and none may
# crash the worker.
for id in ".." "." "../evil" "/etc/passwd" "a/b" "//"; do
	setup
	notes "$id"
	escaped=$(find "$work/var" -maxdepth 1 -type f ! -name 'CANARY.txt' | head -1)
	[ -z "$escaped" ] || fail "notes ID '$id' wrote outside the notes directory: $escaped"
	[ -f "$work/var/CANARY.txt" ] || fail "notes ID '$id' clobbered a file outside the notes directory"
	[ -f "$work/var/sibling/keepme" ] || fail "notes ID '$id' touched a sibling directory"
done

# ---- the "--status --html" role writes a second file, from the same name ----
# It inserts the hostname raw into "$htmldir/<host>.<test>.html", so a '/'
# in the name lands the file outside htmldir. Shipped DISABLED in tasks.cfg
# ("storestatus"), but the code path is the same class as the one above.
status_html() {  # status_html <hostname>
	local rc
	set +e
	printf '@@status#1|1785830400.000000|10.0.0.99|origin|%s|conn|0|green|flags|green|1785830000|0||0||0|0\nSTATUS BODY\n@@\n' "$1" \
	| XYMONHOME="$work" XYMONVAR="$work/var" \
		"$work/xymond_filestore" --env="$work/etc/xymonserver.cfg" \
		--status --dir="$work/var/logs" --htmldir="$work/var/html" \
		>/dev/null 2>>"$work/worker.log"
	rc=$?
	set -e
	[ "$rc" -le 1 ] || fail "xymond_filestore exited $rc (crash?) on status hostname '$1'"
}

setup
status_html "realhost"
[ -f "$work/var/html/realhost.conn.html" ] \
	|| { cat "$work/worker.log" >&2; fail "a legitimate status HTML log was not written -- the checks below would pass vacuously"; }

for host in ".." "../evil" "a/b" "/etc/passwd"; do
	setup
	status_html "$host"
	stray=$(find "$work/var" -maxdepth 1 -name '*.html' | head -1)
	[ -z "$stray" ] || fail "status hostname '$host' wrote an HTML log outside htmldir: $stray"
	[ -f "$work/var/CANARY.txt" ] || fail "status hostname '$host' clobbered a file outside htmldir"
	[ -f "$work/var/sibling/keepme" ] || fail "status hostname '$host' touched a sibling directory"
done

echo "OK $(basename "$0")"
