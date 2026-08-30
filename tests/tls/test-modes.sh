#!/bin/sh
# Exercise the CA-free ("permissive") Xymon TLS trust modes end-to-end:
#
#   1. Pinning (XYMON_TLS_VERIFY=peer): no CA, mutual auth via self-signed
#      certs each side trusts directly. A round-trip must succeed, and a
#      client with NO cert must be rejected (mutual auth still enforced).
#   2. Encrypt-only (XYMON_TLS_VERIFY=none, server without --tls-ca): no CA,
#      no client cert. A round-trip must succeed.
#
# Self-signed certs come from gen-selfsigned.sh (idempotent).
#
# Exit codes: 0 all modes behaved correctly; 1 prerequisite; 2 a mode failed.
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
TLS_PORT=${TLS_PORT:-1988}
PLAIN_PORT=${PLAIN_PORT:-21988}

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xymon-tls-modes.XXXXXX")
HOSTS_FILE="$RUN_DIR/hosts.cfg"
PID=""

# Valid XYMONHOME so xymond can set up its channels regardless of the build's
# configured install prefix (and in CI).
export XYMONHOME="$RUN_DIR"

stop_xymond() {
	[ -n "$PID" ] && kill "$PID" 2>/dev/null || true
	[ -n "$PID" ] && { sleep 1; kill -9 "$PID" 2>/dev/null || true; }
	PID=""
}
cleanup() { rc=$?; stop_xymond; rm -rf "$RUN_DIR"; exit $rc; }
trap cleanup EXIT INT TERM

# start_xymond <logfile> [extra args...]   (always passes cert+key)
start_xymond() {
	_log="$1"; shift
	"$XYMOND_BIN" --no-daemon --listen="$TLS_HOST:$PLAIN_PORT" --hosts="$HOSTS_FILE" \
		--tls-listen="$TLS_HOST:$TLS_PORT" \
		--tls-cert="$CERT_DIR/ss-server.crt" --tls-key="$CERT_DIR/ss-server.key" \
		"$@" >"$_log" 2>&1 &
	PID=$!
	# Readiness: wait until the TCP port accepts a connection. Grep for
	# "CONNECTED" (printed before the handshake) so this doesn't depend on
	# the mTLS handshake succeeding or on OpenSSL-version exit-code quirks.
	_i=0
	while [ $_i -lt 50 ]; do
		if openssl s_client -connect "$TLS_HOST:$TLS_PORT" </dev/null 2>&1 | grep -q CONNECTED; then return 0; fi
		_i=$((_i + 1)); sleep 0.2
	done
	echo "FAIL: xymond did not open $TLS_HOST:$TLS_PORT" >&2; cat "$_log" >&2; exit 1
}

echo "== Xymon TLS trust-mode tests =="
[ -x "$XYMOND_BIN" ] || { echo "SKIP: xymond not built: $XYMOND_BIN" >&2; exit 77; }
[ -x "$XYMON_BIN" ]  || { echo "SKIP: xymon client not built: $XYMON_BIN" >&2; exit 77; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl required" >&2; exit 77; }

"$SCRIPT_DIR/gen-selfsigned.sh" >/dev/null
printf '%s testpage.test\n' "$TLS_HOST" > "$HOSTS_FILE"
URL="xymons://$TLS_HOST:$TLS_PORT"

# --- 1. Pinning: mutual auth, no CA ---------------------------------------
echo "[1/3] Pinning (VERIFY=peer): round-trip should succeed"
# --tls-ca alone means "verify a client cert if one is offered"; refusing a
# certless client is --tls-require-clientcert. Both are needed for pinning.
start_xymond "$RUN_DIR/pin.log" --tls-ca="$CERT_DIR/ss-client.crt" --tls-require-clientcert
OUT=$(XYMON_TLS_VERIFY=peer XYMON_TLS_CA="$CERT_DIR/ss-server.crt" \
	XYMON_TLS_CERT="$CERT_DIR/ss-client.crt" XYMON_TLS_KEY="$CERT_DIR/ss-client.key" \
	"$XYMON_BIN" "$URL" "ping" 2>&1 || true)
echo "$OUT" | grep -Eqi 'xymond is alive|^xymond|^OK' \
	&& echo "  PASS: pinned mutual-auth round-trip" \
	|| { echo "FAIL: pinning round-trip: $OUT" >&2; exit 2; }

# --- 2. Pinning must still reject a client with no cert -------------------
echo "[2/3] Pinning: a client with NO cert must be rejected"
OUT=$(XYMON_TLS_VERIFY=peer XYMON_TLS_CA="$CERT_DIR/ss-server.crt" \
	"$XYMON_BIN" "$URL" "ping" 2>&1 || true)
if echo "$OUT" | grep -Eqi 'xymond is alive|^xymond|^OK'; then
	echo "FAIL: certless client was accepted by an mTLS listener" >&2; exit 2
else
	echo "  PASS: certless client rejected (handshake failed as expected)"
fi
stop_xymond

# --- 3. Encrypt-only: no CA, no client cert -------------------------------
echo "[3/3] Encrypt-only (VERIFY=none, server without --tls-ca): should succeed"
start_xymond "$RUN_DIR/enc.log"   # no --tls-ca
OUT=$(XYMON_TLS_VERIFY=none "$XYMON_BIN" "$URL" "ping" 2>&1 || true)
echo "$OUT" | grep -Eqi 'xymond is alive|^xymond|^OK' \
	&& echo "  PASS: encrypt-only round-trip" \
	|| { echo "FAIL: encrypt-only round-trip: $OUT" >&2; exit 2; }
stop_xymond

echo
echo "All TLS trust-mode checks passed."
