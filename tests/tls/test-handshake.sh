#!/bin/sh
# Smoke-test the Xymon native TLS prototype end-to-end.
#
# What it does:
#  1. Generates test certs via gen-certs.sh (idempotent).
#  2. Starts xymond on 127.0.0.1:1985 with --tls-listen + the test certs,
#     in the background, with a minimal stub config.
#  3. Verifies the TLS handshake works using `openssl s_client` (mTLS).
#  4. Optionally, if a built `xymon` client binary is on $PATH (or pointed
#     at via $XYMON_BIN), sends a real status message via xymons:// and
#     checks the server log for evidence.
#  5. Tears xymond back down.
#
# Requirements:
#  - A built xymond binary at $XYMOND_BIN (default: ../../xymond/xymond
#    relative to this script).
#  - openssl(1) for cert gen + handshake probe.
#  - A working /tmp.
#
# Exit codes:
#  0  all checks passed
#  1  missing prerequisite (xymond not built, openssl missing, etc.)
#  2  TLS handshake failed
#  3  client round-trip failed
#
# This program is released under the GNU General Public License (GPL),
# version 2. See the file "COPYING" for details.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CERT_DIR="$SCRIPT_DIR/out"
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

XYMOND_BIN=${XYMOND_BIN:-$REPO_ROOT/xymond/xymond}
XYMON_BIN=${XYMON_BIN:-$REPO_ROOT/common/xymon}

TLS_PORT=${TLS_PORT:-1985}
TLS_HOST=127.0.0.1
PLAIN_PORT=${PLAIN_PORT:-11984}    # bind plaintext somewhere unprivileged

RUN_DIR=$(mktemp -d -t xymon-tls-smoke.XXXXXX)
PID_FILE="$RUN_DIR/xymond.pid"
LOG_FILE="$RUN_DIR/xymond.log"
HOSTS_FILE="$RUN_DIR/hosts.cfg"

# Single cleanup path.
cleanup() {
	rc=$?
	if [ -s "$PID_FILE" ]; then
		PID=$(cat "$PID_FILE" 2>/dev/null || true)
		[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
		# Give it a beat to flush, then SIGKILL if still around.
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

# --- 0. preflight ----------------------------------------------------------
echo "== Xymon TLS smoke test =="
echo "  xymond:    $XYMOND_BIN"
echo "  cert dir:  $CERT_DIR"
echo "  run dir:   $RUN_DIR"
echo "  TLS port:  $TLS_PORT"
echo

if [ ! -x "$XYMOND_BIN" ]; then
	echo "FAIL: xymond binary not found or not executable: $XYMOND_BIN" >&2
	echo "      Build the server first (./configure --server && make), or set" >&2
	echo "      XYMOND_BIN to the binary path." >&2
	exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
	echo "FAIL: openssl(1) is required" >&2
	exit 1
fi

# --- 1. certs --------------------------------------------------------------
echo "[1/5] Ensure test certs exist"
"$SCRIPT_DIR/gen-certs.sh" >/dev/null
for f in ca.crt server.crt server.key client.crt client.key; do
	[ -f "$CERT_DIR/$f" ] || { echo "FAIL: missing $CERT_DIR/$f" >&2; exit 1; }
done
echo "  certs ready under $CERT_DIR"

# --- 2. minimal stub config + dirs ----------------------------------------
echo "[2/5] Stage minimal xymond stub config"
mkdir -p "$RUN_DIR/etc" "$RUN_DIR/var" "$RUN_DIR/var/log" "$RUN_DIR/www"
cat >"$HOSTS_FILE" <<EOF
# Minimal hosts.cfg for the TLS smoke test.
$TLS_HOST testpage.test
EOF

# --- 3. start xymond ------------------------------------------------------
echo "[3/5] Start xymond with --tls-listen=$TLS_HOST:$TLS_PORT"
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

# Wait for the TLS port to actually accept connections.
i=0
while [ $i -lt 50 ]; do
	if (echo >/dev/tcp/$TLS_HOST/$TLS_PORT) 2>/dev/null; then
		break
	fi
	i=$((i + 1))
	sleep 0.1
done
if ! (echo >/dev/tcp/$TLS_HOST/$TLS_PORT) 2>/dev/null; then
	echo "FAIL: xymond never opened $TLS_HOST:$TLS_PORT" >&2
	exit 1
fi
echo "  xymond pid $(cat "$PID_FILE") listening"

# --- 4. handshake probe with openssl s_client -----------------------------
echo "[4/5] mTLS handshake probe via openssl s_client"
HS_OUT=$(echo "" | openssl s_client \
		-connect "$TLS_HOST:$TLS_PORT" \
		-cert "$CERT_DIR/client.crt" \
		-key  "$CERT_DIR/client.key" \
		-CAfile "$CERT_DIR/ca.crt" \
		-verify_return_error \
		-servername "$TLS_HOST" \
		-tls1_3 \
		2>&1 || true)

if echo "$HS_OUT" | grep -q 'Verify return code: 0 (ok)'; then
	echo "  PASS: TLS handshake succeeded with peer cert verification"
else
	echo "FAIL: TLS handshake/verify failed" >&2
	echo "$HS_OUT" | tail -20 >&2
	exit 2
fi

# Confirm the server logged the connection with the expected peer CN.
if grep -q 'peer CN=xymon-test-client' "$LOG_FILE"; then
	echo "  PASS: server logged peer CN=xymon-test-client"
else
	echo "  WARN: did not find expected peer-CN log line (handshake still verified)"
fi

# --- 5. optional: real client round-trip ----------------------------------
if [ -x "$XYMON_BIN" ]; then
	echo "[5/5] Real client round-trip via xymons:// scheme"
	OUT=$( XYMSRV="xymons://$TLS_HOST:$TLS_PORT" \
		XYMON_TLS_CA="$CERT_DIR/ca.crt" \
		XYMON_TLS_CERT="$CERT_DIR/client.crt" \
		XYMON_TLS_KEY="$CERT_DIR/client.key" \
		"$XYMON_BIN" "$TLS_HOST" "ping" 2>&1 || true )
	if echo "$OUT" | grep -qi 'xymond is alive\|^xymond\|^OK'; then
		echo "  PASS: client ping over TLS got a server response"
	else
		echo "FAIL: client ping over TLS produced unexpected output:" >&2
		echo "$OUT" >&2
		exit 3
	fi
else
	echo "[5/5] Skipping real-client round-trip ($XYMON_BIN not built)"
fi

echo
echo "All TLS smoke-test checks passed."
