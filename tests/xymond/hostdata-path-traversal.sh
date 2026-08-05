#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/xymond/hostdata-path-traversal.sh
#
# Regression guard: xymond_hostdata must not let a hostname taken from a
# channel message escape the client-log directory.
#
# The worker turns metadata[3] straight into a path component:
#
#   @@clichg    -> mkdir "$CLIENTLOGS/<host>" ; fopen "$CLIENTLOGS/<host>/<ts>"
#   @@drophost  -> dropdirectory("$CLIENTLOGS/<host>")   <- recursive delete
#   @@renamehost-> rename("$CLIENTLOGS/<old>", "$CLIENTLOGS/<new>")
#
# The drophost and renamehost handlers used basename(), which returns ".."
# for ".." and so confines nothing; the clichg handler had no filtering at
# all. With "--ghosts=allow" the hostname is whatever the reporting client
# called itself -- knownhost() returns an unknown name verbatim, and the
# character whitelist in log_ghost() is only reached when knownhost()
# returns NULL.
#
# Workers read their messages from stdin (xymond_worker.c), so this drives
# the real binary with crafted messages and checks the filesystem.

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

work=$(mktemp -d "${TMPDIR:-/tmp}/xymon-hostdata-traversal.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

make -C "$ROOT/lib" libxymon.a libxymoncomm.a libxymontime.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot build the xymon libraries"; }

# HOSTDATAOBJS = xymond_hostdata.o xymond_worker.o (xymond/Makefile).
# The archives are listed twice rather than wrapped in --start-group:
# --start-group is GNU ld only, and the Darwin linker rejects it.
"$CC" -I"$ROOT/include" -I"$ROOT/lib" -I"$ROOT/xymond" -o "$work/xymond_hostdata" \
	"$ROOT/xymond/xymond_hostdata.c" "$ROOT/xymond/xymond_worker.c" \
	"$ROOT/lib/libxymon.a" "$ROOT/lib/libxymoncomm.a" "$ROOT/lib/libxymontime.a" \
	"$ROOT/lib/libxymon.a" \
	$pcre_libs $ssllibs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "xymond_hostdata does not build -- cannot verify the traversal guards"; }

mkdir -p "$work/etc"
cp "$ROOT/xymond/etcfiles/xymonserver.cfg.DIST" "$work/etc/xymonserver.cfg"

setup() {  # rebuild a pristine XYMONVAR with a canary outside the client-log dir
	rm -rf "$work/var"
	mkdir -p "$work/var/hostdata/realhost" "$work/var/rrd"
	printf 'CANARY-OUTSIDE-CLIENTLOGS\n' >"$work/var/CANARY.txt"
	printf 'existing client data\n'      >"$work/var/hostdata/realhost/1785830400"
	printf 'rrd payload\n'               >"$work/var/rrd/some.rrd"
}

feed() {  # feed <message-first-line> [body]
	local rc
	set +e
	# --logdir= is checked before any environment lookup, so the target is
	# unambiguous. --minimum-free=0 keeps chkfreespace() (lib/misc.c) from
	# disabling writes on a filesystem low on space or inodes.
	# --recent-period=0 disables the save-throttle: it compares zeroed
	# timestamps against "gettimer() - recentperiod", and gettimer() is
	# CLOCK_MONOTONIC (lib/timing.c:44), so on a host whose uptime is below
	# the window that bound goes negative, every slot counts as recent, and
	# the save is skipped in silence. CI runners boot fresh, so the default
	# 3600s window would make every assertion below pass vacuously.
	printf '%s\n%s\n@@\n' "$1" "${2:-payload}" \
	| XYMONHOME="$work" XYMONVAR="$work/var" \
		"$work/xymond_hostdata" --env="$work/etc/xymonserver.cfg" \
		--logdir="$work/var/hostdata" --minimum-free=0 --recent-period=0 \
		>/dev/null 2>>"$work/worker.log"
	rc=$?
	set -e
	# The worker exits 0 when its input pipe closes. Anything else is a crash,
	# which must not be mistaken for "the guard held".
	[ "$rc" -le 1 ] || fail "xymond_hostdata exited $rc (crash?) on: $1"
}

# dropdirectory() forks when called with background=1 (lib/files.c:35), so a
# @@drophost delete happens in a child that outlives the worker. Asserting
# straight after feed() is a race -- and it races the wrong way: "the canary
# is still there" would look like "the guard held" when it only means "the
# child had not got to it yet". Wait for the workers to be gone first.
settle() {
	local n=0
	while [ $n -lt 100 ]; do
		pgrep -f "$work/xymond_hostdata" >/dev/null 2>&1 || break
		sleep 0.1; n=$((n+1))
	done
	sleep 0.3	# the child may have exec'd past our pattern; small settle margin
}

# ---- sanity: the write path must actually work here --------------------------
# Every assertion below is of the form "nothing escaped". If the worker cannot
# write at all in this environment, they all hold vacuously -- so prove the
# write path works before trusting a single refusal.
setup
: >"$work/worker.log"
feed "@@clichg#1|1785830400|10.0.0.99|realhost|1785830500|linux" "sanity payload"
if [ ! -f "$work/var/hostdata/realhost/1785830500" ]; then
	# Say why, rather than leaving the next person to guess from a CI log.
	# --debug distinguishes "the message never arrived" from "it arrived and
	# was skipped", which are very different bugs.
	echo "--- worker stderr ---" >&2; cat "$work/worker.log" >&2
	echo "--- tree under \$work/var ---" >&2; find "$work/var" >&2
	echo "--- replay with --debug ---" >&2
	setup
	printf '%s\n%s\n@@\n' "@@clichg#1|1785830400|10.0.0.99|realhost|1785830500|linux" "sanity payload" \
	| XYMONHOME="$work" XYMONVAR="$work/var" \
		"$work/xymond_hostdata" --env="$work/etc/xymonserver.cfg" \
		--logdir="$work/var/hostdata" --minimum-free=0 --recent-period=0 \
		--debug 2>&1 >&2 | head -20 >&2
	echo "--- df / inodes for \$work ---" >&2; df -k "$work" >&2 2>/dev/null || true; df -i "$work" >&2 2>/dev/null || true
	fail "xymond_hostdata wrote nothing for a legitimate host -- the refusals below would pass vacuously"
fi

# ---- @@clichg must not write outside the client-log directory ----------------
for host in ".." "../.." "/" "." "../evil"; do
	setup
	feed "@@clichg#1|1785830400|10.0.0.99|$host|9999999999|linux" "escaped payload"
	found=$(find "$work/var" -mindepth 1 -maxdepth 1 -name '9999999999' -o -name 'evil' -type d | head -1)
	[ -z "$found" ] || fail "clichg with hostname '$host' wrote outside the client-log dir: $found"
done

# ---- @@drophost must not delete outside the client-log directory -------------
# This one deletes recursively, so an unconfined ".." takes out all of XYMONVAR.
for host in ".." "../.." "/" "."; do
	setup
	feed "@@drophost#1|1785830400|10.0.0.99|$host"
	settle
	[ -f "$work/var/CANARY.txt" ] \
		|| fail "drophost with hostname '$host' deleted outside the client-log dir"
	[ -f "$work/var/rrd/some.rrd" ] \
		|| fail "drophost with hostname '$host' deleted \$XYMONVAR/rrd"
done

# ---- @@renamehost must not move anything in or out of the directory ----------
setup
feed "@@renamehost#1|1785830400|10.0.0.99|..|stolen"
settle
[ -f "$work/var/CANARY.txt" ] || fail "renamehost with '..' moved the parent directory"
[ ! -e "$work/var/hostdata/stolen" ] || fail "renamehost with '..' created hostdata/stolen"

# ---- legitimate traffic still works -----------------------------------------
setup
feed "@@clichg#1|1785830400|10.0.0.99|realhost|1785830500|linux" "fresh client data"
[ -f "$work/var/hostdata/realhost/1785830500" ] \
	|| fail "legitimate clichg no longer saved"
assert_contains "fresh client data" "$(cat "$work/var/hostdata/realhost/1785830500")" \
	"legitimate clichg payload not stored"

setup
feed "@@renamehost#1|1785830400|10.0.0.99|realhost|renamedhost"
[ -d "$work/var/hostdata/renamedhost" ] || fail "legitimate renamehost no longer works"

setup
feed "@@drophost#1|1785830400|10.0.0.99|realhost"
settle
n=0
while [ -e "$work/var/hostdata/realhost" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
[ ! -e "$work/var/hostdata/realhost" ] || fail "legitimate drophost no longer works"
[ -f "$work/var/CANARY.txt" ] || fail "legitimate drophost deleted too much"

echo "OK $(basename "$0")"
