#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/client/fs-sentinel.sh
#
# Regression guard for the non-blocking remote-df sentinel in
# xymonclient-linux.sh. df_sentinel() keeps at most ONE outstanding df per tag:
# a df wedged on a dead NFS/CIFS server (can't be SIGKILLed in D-state) is left
# running and detected next cycle instead of spawning another -- the client never
# blocks, orphans never accumulate, and it self-recovers when the server returns.
#
# We extract df_sentinel() and drive it against a df stub. The stub MUST be a
# /bin/sh script named "df" so /proc/PID/comm == "df", which the PID-reuse guard
# checks (a bash-shebang stub would report comm == "bash" and defeat it).

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)
SCRIPT="${XYMONCLIENT_LINUX:-$ROOT/client/xymonclient-linux.sh}"
if [ ! -f "$SCRIPT" ]; then
	[ -z "${XYMONCLIENT_LINUX:-}" ] || fail "XYMONCLIENT_LINUX set to '$SCRIPT' but no such file -- broken package layout, not a skip"
	skip "$SCRIPT missing"
fi
# The sentinel is the feature under test; its absence is a regression, not a skip.
grep -q '^df_sentinel()' "$SCRIPT" || fail "df_sentinel() missing from $SCRIPT (sentinel regressed)"

TMP=$(mktempdir)
STUB="$TMP/bin"
mkdir -p "$STUB"
export DFTEST_HANG="$TMP/HANG"
# Kill any df stub still sleeping when the test exits (wedge cases leave one).
register_cleanup "pkill -f '$STUB/df' 2>/dev/null || true"

# df stub: when $DFTEST_HANG exists, sleep past the deadline (a wedged server);
# otherwise emit a header + one row. /bin/sh shebang so comm == "df".
cat > "$STUB/df" <<'EOF'
#!/bin/sh
if [ -f "$DFTEST_HANG" ]; then sleep 30; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'server:/exp 100 50 50 50%% /mnt/nfs\n'
EOF
chmod +x "$STUB/df"
export PATH="$STUB:$PATH"

# Bring df_sentinel() into this shell and give it the globals it reads.
eval "$(sed -n '/^df_sentinel()/,/^}/p' "$SCRIPT")"
DFPROBEDIR="$TMP"
DFTIMEOUT=1

# --- healthy: returns the row (header stripped), rc 0, no leftover state ------
set +e; out=$(df_sentinel disk -P); rc=$?; set -e
assert_equal 0 "$rc" "healthy probe returns rc 0"
assert_contains "/mnt/nfs" "$out" "healthy probe returns the df row"
assert_not_contains "Filesystem" "$out" "healthy probe strips the df header"
assert_equal "" "$(ls "$TMP"/df-probe-* 2>/dev/null || true)" \
	"healthy probe leaves no probe/pidfile behind"

# --- wedge: df hangs -> rc 124 after the deadline, sentinel left running ------
: > "$DFTEST_HANG"
set +e; df_sentinel disk -P >/dev/null; rc=$?; set -e
assert_equal 124 "$rc" "a wedged remote df must report unavailable (124)"
assert_file_exists "$TMP/df-probe-disk.pid" "a wedged probe must leave a sentinel pidfile"
sentinel_pid=$(cat "$TMP/df-probe-disk.pid")
kill -0 "$sentinel_pid" 2>/dev/null || fail "the sentinel df must still be running"

# --- reuse: next cycle while still wedged -> instant 124, NO second df --------
before=$(pgrep -f "$STUB/df" | wc -l | tr -d ' ')
set +e; df_sentinel disk -P >/dev/null; rc=$?; set -e
after=$(pgrep -f "$STUB/df" | wc -l | tr -d ' ')
assert_equal 124 "$rc" "reuse cycle must stay unavailable (124)"
assert_equal "$before" "$after" "reuse cycle must NOT launch a second df"
assert_equal "$sentinel_pid" "$(cat "$TMP/df-probe-disk.pid")" \
	"reuse cycle must keep the same sentinel, not replace it"

# --- recovery: probe finished with data -> next cycle reads it, cleans up -----
# Simulate the wedged df having returned: stop it and write a completed probe.
rm -f "$DFTEST_HANG"
kill -9 "$sentinel_pid" 2>/dev/null || true
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nserver:/exp 200 10 190 5%% /mnt/nfs\n' > "$TMP/df-probe-disk"
set +e; out=$(df_sentinel disk -P); rc=$?; set -e
assert_equal 0 "$rc" "recovery cycle returns rc 0 once the probe completes"
assert_contains "/mnt/nfs" "$out" "recovery cycle returns the recovered df row"
assert_not_contains "Filesystem" "$out" "recovery cycle strips the df header"
assert_equal "" "$(ls "$TMP"/df-probe-* 2>/dev/null || true)" \
	"recovery cycle cleans up the probe and pidfile"

# --- no writable probe dir -> unavailable (124), never a blocking df ----------
# If DFPROBEDIR is not writable the sentinel must fail safe with 124 (the caller
# then emits unavailable rows) instead of falling back to a SYNCHRONOUS remote df
# -- that foreground df would reintroduce the exact hang the sentinel prevents.
RODIR="$TMP/ro"
mkdir -p "$RODIR"
chmod 555 "$RODIR"
register_cleanup "chmod 755 '$RODIR' 2>/dev/null || true"
if ( : 2>/dev/null > "$RODIR/.probe" ); then
	rm -f "$RODIR/.probe"
	skip "probe dir stayed writable (running as root?) -- cannot exercise the fail-safe"
else
	# pgrep exits nonzero when nothing matches; guard it so pipefail/set -e don't
	# abort when no df is running.
	before=$({ pgrep -f "$STUB/df" || true; } | wc -l | tr -d ' ')
	( DFPROBEDIR="$RODIR"
	  set +e; df_sentinel disk -P >/dev/null; echo "$?" > "$TMP/ro.rc"; set -e )
	after=$({ pgrep -f "$STUB/df" || true; } | wc -l | tr -d ' ')
	assert_equal 124 "$(cat "$TMP/ro.rc")" \
		"a non-writable probe dir must report unavailable (124)"
	assert_equal "$before" "$after" \
		"a non-writable probe dir must NOT launch a (blocking) df"
fi

pass "df_sentinel: healthy, wedge, reuse (no second df), recovery, and probe-dir fail-safe all hold"
