#!/bin/sh
# Concurrency check for the Xymon native TLS listener.
#
# xymond is single-threaded and does the TLS handshake inline in its event
# loop, so this fires many TLS clients at once to confirm that concurrent
# handshakes + sends all complete with no loss, deadlock, or crash. Each
# client sends a uniquely-named status; afterwards every one must be present
# when read back, proving nothing was dropped or interleaved incorrectly.
#
# Exit codes: 0 all messages survived; 1 prerequisite; 2 loss/failure.
#
# This program is released under the GNU General Public License (GPL),
# version 2. See the file "COPYING" for details.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CERT_DIR="$SCRIPT_DIR/out"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
XYMOND_BIN=${XYMOND_BIN:-$REPO_ROOT/xymond/xymond}
XYMON_BIN=${XYMON_BIN:-$REPO_ROOT/common/xymon}
TLS_HOST=127.0.0.1
TLS_PORT=${TLS_PORT:-1991}
PLAIN_PORT=${PLAIN_PORT:-21991}
N=${N:-20}                        # number of concurrent clients
HOST=testpage.test

RUN_DIR=$(mktemp -d -t xymon-tls-conc.XXXXXX)
HOSTS_FILE="$RUN_DIR/hosts.cfg"
LOG_FILE="$RUN_DIR/xymond.log"
PID=""
export XYMONHOME="$RUN_DIR"

cleanup() {
	rc=$?
	[ -n "$PID" ] && kill "$PID" 2>/dev/null || true
	[ -n "$PID" ] && { sleep 1; kill -9 "$PID" 2>/dev/null || true; }
	[ "$rc" -ne 0 ] && [ -f "$LOG_FILE" ] && { echo "--- xymond.log tail ---"; tail -20 "$LOG_FILE"; }
	rm -rf "$RUN_DIR"
	exit $rc
}
trap cleanup EXIT INT TERM

echo "== Xymon TLS concurrency test (N=$N) =="
[ -x "$XYMOND_BIN" ] || { echo "FAIL: missing $XYMOND_BIN" >&2; exit 1; }
[ -x "$XYMON_BIN" ]  || { echo "FAIL: missing $XYMON_BIN"  >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "FAIL: openssl required" >&2; exit 1; }

"$SCRIPT_DIR/gen-certs.sh" >/dev/null
printf '%s %s\n' "$TLS_HOST" "$HOST" > "$HOSTS_FILE"

"$XYMOND_BIN" --no-daemon --listen="$TLS_HOST:$PLAIN_PORT" --hosts="$HOSTS_FILE" \
	--tls-listen="$TLS_HOST:$TLS_PORT" --tls-cert="$CERT_DIR/server.crt" \
	--tls-key="$CERT_DIR/server.key" --tls-ca="$CERT_DIR/ca.crt" \
	>"$LOG_FILE" 2>&1 &
PID=$!
i=0
while [ $i -lt 50 ]; do
	if openssl s_client -connect "$TLS_HOST:$TLS_PORT" </dev/null >/dev/null 2>&1; then break; fi
	i=$((i + 1)); sleep 0.2
done

export XYMON_TLS_CA="$CERT_DIR/ca.crt"
export XYMON_TLS_CERT="$CERT_DIR/client.crt"
export XYMON_TLS_KEY="$CERT_DIR/client.key"
URL="xymons://$TLS_HOST:$TLS_PORT"

echo "[1/2] Fire $N concurrent TLS status sends"
send_pids=""
i=1
while [ $i -le "$N" ]; do
	( "$XYMON_BIN" "$URL" "status $HOST.conc$i green concurrent-marker-$i" >/dev/null 2>&1 ) &
	send_pids="$send_pids $!"
	i=$((i + 1))
done
# Wait only for the sender jobs -- a bare `wait` would also block on the
# backgrounded xymond, which never exits.
wait $send_pids
sleep 1

echo "[2/2] Verify all $N messages were received intact"
missing=0
i=1
while [ $i -le "$N" ]; do
	if ! "$XYMON_BIN" "$URL" "xymondlog $HOST.conc$i" 2>/dev/null | grep -q "concurrent-marker-$i"; then
		echo "  missing: conc$i" >&2
		missing=$((missing + 1))
	fi
	i=$((i + 1))
done

if [ "$missing" -eq 0 ]; then
	echo "  PASS: all $N concurrent TLS messages received intact"
else
	echo "FAIL: $missing of $N concurrent messages lost" >&2
	exit 2
fi

# The server must still be alive after the burst.
if kill -0 "$PID" 2>/dev/null; then
	echo "  PASS: xymond survived the concurrent burst"
else
	echo "FAIL: xymond died during the concurrent burst" >&2
	exit 2
fi

echo
echo "All TLS concurrency checks passed."
