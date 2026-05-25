#!/bin/sh
# Generate a self-signed CA + server cert + client cert for the Xymon TLS
# prototype's local test rig. Outputs PEM files under tests/tls/out/ (relative
# to the repository root) which the test harness and a developer can point
# XYMON_TLS_*, --tls-cert, --tls-key, --tls-ca at.
#
# The server cert has CN=xymon-test-server and SANs for localhost + 127.0.0.1.
# The client cert has CN=xymon-test-client.
#
# Idempotent: skips files that already exist. Pass --force to regenerate.
#
# Requires: openssl (any version with TLS 1.3 support, i.e. 1.1.1+).
#
# This program is released under the GNU General Public License (GPL),
# version 2. See the file "COPYING" for details.

set -eu

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

# Locate the repo root no matter where the script is invoked from.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="$SCRIPT_DIR/out"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if [ "$FORCE" = "1" ]; then
	rm -f ca.key ca.crt server.key server.csr server.crt client.key client.csr client.crt server.ext client.ext ca.srl
fi

# Tiny helper: skip a step if the named file already exists.
skip_if_present() {
	if [ -f "$1" ]; then
		echo "  exists, skipping: $1"
		return 0
	fi
	return 1
}

echo "== Xymon TLS test certificates =="
echo "Output dir: $OUT_DIR"
echo

# ----- CA --------------------------------------------------------------------
echo "[1/3] Self-signed CA"
if ! skip_if_present ca.crt; then
	openssl genrsa -out ca.key 4096 2>/dev/null
	openssl req -new -x509 -sha256 -days 365 -key ca.key -out ca.crt \
		-subj "/CN=xymon-tls-test-CA/O=Xymon TLS Test"
	echo "  wrote ca.key, ca.crt"
fi

# ----- Server cert -----------------------------------------------------------
echo "[2/3] Server cert (CN=xymon-test-server, SAN=localhost,127.0.0.1)"
if ! skip_if_present server.crt; then
	openssl genrsa -out server.key 2048 2>/dev/null
	openssl req -new -key server.key -out server.csr \
		-subj "/CN=xymon-test-server/O=Xymon TLS Test"
	cat >server.ext <<'EOF'
subjectAltName = DNS:localhost,IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF
	openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
		-out server.crt -days 365 -sha256 -extfile server.ext 2>/dev/null
	rm -f server.csr server.ext
	echo "  wrote server.key, server.crt"
fi

# ----- Client cert -----------------------------------------------------------
echo "[3/3] Client cert (CN=xymon-test-client)"
if ! skip_if_present client.crt; then
	openssl genrsa -out client.key 2048 2>/dev/null
	openssl req -new -key client.key -out client.csr \
		-subj "/CN=xymon-test-client/O=Xymon TLS Test"
	cat >client.ext <<'EOF'
extendedKeyUsage = clientAuth
EOF
	openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
		-out client.crt -days 365 -sha256 -extfile client.ext 2>/dev/null
	rm -f client.csr client.ext
	echo "  wrote client.key, client.crt"
fi

echo
echo "Done. To use:"
echo "  Server:  xymond ... --tls-listen=127.0.0.1:1985 \\"
echo "             --tls-cert=$OUT_DIR/server.crt \\"
echo "             --tls-key=$OUT_DIR/server.key \\"
echo "             --tls-ca=$OUT_DIR/ca.crt"
echo
echo "  Client:  XYMSRV=xymons://localhost:1985 \\"
echo "             XYMON_TLS_CA=$OUT_DIR/ca.crt \\"
echo "             XYMON_TLS_CERT=$OUT_DIR/client.crt \\"
echo "             XYMON_TLS_KEY=$OUT_DIR/client.key \\"
echo "             xymon localhost 'status testpage.test green hello'"
