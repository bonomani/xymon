#!/bin/sh
# Multi-record TLS round-trip test for the Xymon native TLS prototype.
#
# Where test-handshake.sh proves a tiny "ping" works, this proves a LARGE
# message survives intact. A ~400KB body spans many TLS records (the record
# limit is 16KB) and forces xymond's input buffer to grow past its 128KB
# initial size, so it exercises:
#   - partial-record SSL_read handling in xymond's select loop (WANT_READ
#     must retry, not be mistaken for end-of-message),
#   - the input-buffer realloc/growth path,
#   - the client's end-of-request framing (close_notify) and response read.
#
# What it does:
#   1. Generates test certs via gen-certs.sh (idempotent, shared with the
#      handshake test).
#   2. Starts xymond with a TLS listener and a one-host stub config.
#   3. Sends a large `status` for that host over xymons://, with a unique
#      tail marker.
#   4. Reads it back over xymons:// (xymondlog) and checks the marker is
#      present -- i.e. nothing was truncated in either direction.
#
# Requirements:
#   - Built xymond ($XYMOND_BIN, default ../../xymond/xymond) and xymon
#     client ($XYMON_BIN, default ../../common/xymon).
#   - openssl(1) for cert gen + the readiness probe.
#
# Exit codes:
#   0  message survived the round-trip intact
#   1  missing prerequisite
#   3  message truncated / not returned (integrity failure)
#
# This program is released under the GNU General Public License (GPL),
# version 2. See the file "COPYING" for details.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CERT_DIR="$SCRIPT_DIR/out"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

XYMOND_BIN=${XYMOND_BIN:-$REPO_ROOT/xymond/xymond}
XYMON_BIN=${XYMON_BIN:-$REPO_ROOT/common/xymon}

TLS_PORT=${TLS_PORT:-1986}
TLS_HOST=127.0.0.1
PLAIN_PORT=${PLAIN_PORT:-21984}   # unprivileged plaintext port
MSG_SIZE=${MSG_SIZE:-400000}      # body bytes; >128KB forces a buffer realloc

HOST=tlstest
TEST=bigtest
MARKER=END_MARKER_9f3a7c

RUN_DIR=$(mktemp -d -t xymon-tls-large.XXXXXX)
PID_FILE="$RUN_DIR/xymond.pid"
LOG_FILE="$RUN_DIR/xymond.log"
HOSTS_FILE="$RUN_DIR/hosts.cfg"

# Valid XYMONHOME so xymond can set up its channels regardless of the build's
# configured install prefix (and in CI).
export XYMONHOME="$RUN_DIR"

cleanup() {
	rc=$?
	if [ -s "$PID_FILE" ]; then
		PID=$(cat "$PID_FILE" 2>/dev/null || true)
		[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
		sleep 1
		[ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
	fi
	if [ "$rc" -ne 0 ] && [ -f "$LOG_FILE" ]; then
		echo
		echo "--- xymond.log (last 40 lines) ---"
		tail -40 "$LOG_FILE" 2>/dev/null || true
	fi
	rm -rf "$RUN_DIR"
	exit $rc
}
trap cleanup EXIT INT TERM

echo "== Xymon TLS multi-record test =="
echo "  xymond:    $XYMOND_BIN"
echo "  client:    $XYMON_BIN"
echo "  TLS port:  $TLS_PORT"
echo "  msg size:  $MSG_SIZE bytes"
echo

# --- 0. preflight ----------------------------------------------------------
if [ ! -x "$XYMOND_BIN" ]; then
	echo "FAIL: xymond binary not found or not executable: $XYMOND_BIN" >&2
	exit 1
fi
if [ ! -x "$XYMON_BIN" ]; then
	echo "FAIL: xymon client not found or not executable: $XYMON_BIN" >&2
	exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
	echo "FAIL: openssl(1) is required" >&2
	exit 1
fi

# --- 1. certs + stub config -----------------------------------------------
echo "[1/4] Ensure test certs + stub config"
"$SCRIPT_DIR/gen-certs.sh" >/dev/null
for f in ca.crt server.crt server.key client.crt client.key; do
	[ -f "$CERT_DIR/$f" ] || { echo "FAIL: missing $CERT_DIR/$f" >&2; exit 1; }
done
printf '%s %s\n' "$TLS_HOST" "$HOST" > "$HOSTS_FILE"

# --- 2. start xymond ------------------------------------------------------
echo "[2/4] Start xymond with --tls-listen=$TLS_HOST:$TLS_PORT"
"$XYMOND_BIN" \
	--no-daemon \
	--listen="$TLS_HOST:$PLAIN_PORT" \
	--hosts="$HOSTS_FILE" \
	--tls-listen="$TLS_HOST:$TLS_PORT" \
	--tls-cert="$CERT_DIR/server.crt" \
	--tls-key="$CERT_DIR/server.key" \
	--tls-ca="$CERT_DIR/ca.crt" \
	>"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"

# Portable readiness probe: retry a real TLS handshake until it succeeds.
i=0
while [ $i -lt 50 ]; do
	if echo | openssl s_client -connect "$TLS_HOST:$TLS_PORT" \
			-cert "$CERT_DIR/client.crt" -key "$CERT_DIR/client.key" \
			-CAfile "$CERT_DIR/ca.crt" -tls1_3 >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 0.2
done
if [ $i -ge 50 ]; then
	echo "FAIL: xymond TLS listener never became ready on $TLS_HOST:$TLS_PORT" >&2
	exit 1
fi
echo "  xymond pid $(cat "$PID_FILE") listening"

export XYMON_TLS_CA="$CERT_DIR/ca.crt"
export XYMON_TLS_CERT="$CERT_DIR/client.crt"
export XYMON_TLS_KEY="$CERT_DIR/client.key"
URL="xymons://$TLS_HOST:$TLS_PORT"

# --- 3. send a large status over TLS --------------------------------------
echo "[3/4] Send $MSG_SIZE-byte status over $URL"
BODY="$(head -c "$MSG_SIZE" /dev/zero | tr '\0' x)$MARKER"
# "@" makes the xymon client read the whole message from stdin, sidestepping
# the OS single-argument length limit (~128KB).
if ! printf 'status %s.%s green %s' "$HOST" "$TEST" "$BODY" | "$XYMON_BIN" "$URL" "@"; then
	echo "FAIL: large status send returned an error" >&2
	exit 3
fi
sleep 1

# --- 4. read it back over TLS and check integrity -------------------------
echo "[4/4] Read back via xymondlog over TLS and verify the tail marker"
OUT=$("$XYMON_BIN" "$URL" "xymondlog $HOST.$TEST" 2>&1 || true)
if printf '%s' "$OUT" | grep -q "$MARKER"; then
	echo "  PASS: full multi-record message survived the round-trip"
else
	echo "FAIL: tail marker '$MARKER' missing from readback -> message truncated" >&2
	printf '%s' "$OUT" | tail -3 >&2
	exit 3
fi

echo
echo "All TLS multi-record checks passed."
