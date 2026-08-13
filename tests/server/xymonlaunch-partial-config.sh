#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymonlaunch-partial-config.sh
#
# xymonlaunch re-reads its config whenever the file's timestamp changes, and
# the re-read begins by clearing every task's settings so that it can tell
# afterwards what actually changed. Nothing checked that it had read a whole
# file before acting on it, and a config file being rewritten in place - by a
# package upgrade, say - is readable in that state, because the re-read is
# driven by the timestamp and not by whoever is writing.
#
# Acting on a short read costs two different things:
#
#   (A) a section read without its CMD line leaves a task with no command,
#       which is fatal - the forked child hands the NULL to expand_env(), which
#       strdup()s it and dies before it can exec, so the task never reaches the
#       point where a failure would be reported. Restoring only the command is
#       not enough either: a task that also lost its ENVFILE gets bounced and
#       restarted without its environment.
#   (B) every section the read did not reach looks deleted, so the tasks below
#       the cut - xymond among them - are killed as if that had been asked for.
#
#   (C) a config file that cannot be opened at all on the re-read, which used
#       to return after the clearing loop had already run.
#
# All three are driven against a live xymonlaunch. SIGHUP forces the re-read
# (sig_handler sets nextcfgload = 0) so the test does not wait out the
# 30-second poll, and each supervised task appends a line every second so that
# "is it still running" is a question the test can answer by watching a file.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMONLAUNCH "common/xymonlaunch"

work=$(mktempdir)
cfg="$work/tasks.cfg"
log="$work/launch.log"

# beat refuses to run without the variable its ENVFILE provides, so "still
# ticking" proves the whole configuration survived, not just the command.
printf 'BEAT_OK=1\n' >"$work/beat.env"
cat >"$work/beat.sh" <<EOF
#!/bin/sh
[ -n "\$BEAT_OK" ] || exit 42
while :; do echo tick >>"$work/beat"; sleep 1; done
EOF
cat >"$work/beat2.sh" <<EOF
#!/bin/sh
while :; do echo tick >>"$work/beat2"; sleep 1; done
EOF
chmod +x "$work/beat.sh" "$work/beat2.sh"

good_config() {
	cat >"$cfg" <<EOF
[beat]
	CMD $work/beat.sh
	ENVFILE $work/beat.env

[beat2]
	CMD $work/beat2.sh
EOF
}

# ---- helpers ---------------------------------------------------------------
# Poll rather than sleep a fixed time, so a slow machine gets its chance and a
# fast one does not pay for it.
wait_for() {
	local deadline=$((SECONDS + $1)); shift
	while [ "$SECONDS" -lt "$deadline" ]; do
		if eval "$@"; then return 0; fi
		sleep 0.2
	done
	return 1
}
lines()     { [ -f "$1" ] && wc -l <"$1" || echo 0; }
grew()      { [ "$(lines "$1")" -gt "$2" ]; }
loadcount() { grep -c 'Loading tasklist configuration' "$log" || true; }
loads_gt()  { [ "$(loadcount)" -gt "$1" ]; }
# Force a re-read and wait until it has actually been attempted, so what
# follows cannot race the SIGHUP.
reload() {
	local n; n=$(loadcount)
	kill -HUP "$launcher"
	wait_for 15 "loads_gt $n" || fail "xymonlaunch did not re-read its config after SIGHUP"
}

good_config
"$XYMONLAUNCH" --config="$cfg" --no-daemon >"$log" 2>&1 &
launcher=$!
register_cleanup "kill $launcher 2>/dev/null || true; pkill -f ${work}/beat.sh 2>/dev/null || true; pkill -f ${work}/beat2.sh 2>/dev/null || true"

wait_for 20 '[ -s "$work/beat" ] && [ -s "$work/beat2" ]' \
	|| fail "the supervised tasks never started: $(cat "$log")"

# ---- (A) + (B) a read that stopped in the middle of the first section ------
# [beat] loses its CMD and its ENVFILE; [beat2] is not in the file at all.
# Both must come through untouched, and neither may be restarted: beat would
# come back without BEAT_OK and exit 42, beat2 would be killed as deleted.
b1=$(lines "$work/beat"); b2=$(lines "$work/beat2")
printf '[beat]\n' >"$cfg"
reload

assert_contains "no command for task beat" "$(cat "$log")" \
	"the short read did not report the task it left without a command"
assert_contains "keeping the previous one" "$(cat "$log")" \
	"the short read was applied instead of being refused"
assert_not_contains "terminated" "$(cat "$log")" \
	"a task was killed or exited over a config read that did not see the whole file"

wait_for 20 "grew $work/beat $b1" \
	|| fail "the task whose section lost its CMD line stopped: $(cat "$log")"
wait_for 20 "grew $work/beat2 $b2" \
	|| fail "the task that was simply absent from the short read was killed as deleted: $(cat "$log")"

# A good config is picked up again straight away - refusing one read must not
# wedge the launcher into ignoring the file.
good_config
reload
assert_not_contains "terminated" "$(cat "$log")" \
	"the re-read of a restored config bounced tasks that had not changed"

# ---- (C) a config that cannot be opened on the re-read ---------------------
rm -f "$cfg"
reload
assert_contains "Cannot open configuration file" "$(cat "$log")" \
	"a re-read that could not open the config did not report it"

# Nothing proves the task list survived while the tasks keep running -- it is
# the *next* restart that reads the command back. So force one.
b1=$(lines "$work/beat")
pkill -f "$work/beat.sh"
wait_for 30 "grew $work/beat $b1" \
	|| fail "the task did not restart after a re-read that could not open its config: $(cat "$log")"

pass "a config read that stopped short, or could not be opened, is refused whole and leaves every running task alone"
