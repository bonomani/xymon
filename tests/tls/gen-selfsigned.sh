#!/bin/sh
# Generate self-signed cert/key pairs for the CA-free ("permissive") Xymon TLS
# deployment modes -- no CA hierarchy at all. Outputs PEM files under
# tests/tls/out/ alongside the CA-based certs from gen-certs.sh:
#
#   ss-server.crt / ss-server.key  - self-signed server identity
#   ss-client.crt / ss-client.key  - self-signed client identity
#
# These support two CA-free modes:
#
#   Pinning (encrypt + mutual auth, no CA):
#     server:  --tls-cert=ss-server.crt --tls-key=ss-server.key \
#              --tls-ca=ss-client.crt          # trust the client's own cert
#     client:  XYMON_TLS_VERIFY=peer \
#              XYMON_TLS_CA=ss-server.crt       # trust the server's own cert
#              XYMON_TLS_CERT=ss-client.crt XYMON_TLS_KEY=ss-client.key
#
#   Encrypt-only (no auth, no CA, no client cert):
#     server:  --tls-cert=ss-server.crt --tls-key=ss-server.key  # omit --tls-ca
#     client:  XYMON_TLS_VERIFY=none                              # no CA/cert
#
# The server cert carries SANs for localhost + 127.0.0.1 so 'full' verification
# also works against it if desired.
#
# Idempotent: skips files that already exist. Pass --force to regenerate.
# Requires: openssl 1.1.1+ (TLS 1.3).
#
# This program is released under the GNU General Public License (GPL),
# version 2. See the file "COPYING" for details.

set -eu

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="$SCRIPT_DIR/out"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if [ "$FORCE" = "1" ]; then
	rm -f ss-server.key ss-server.crt ss-client.key ss-client.crt
fi

echo "== Xymon TLS self-signed (CA-free) certificates =="
echo "Output dir: $OUT_DIR"
echo

# Self-signed server identity, with SANs so 'full' verification is possible too.
echo "[1/2] Self-signed server (CN=xymon-ss-server, SAN=localhost,127.0.0.1)"
if [ -f ss-server.crt ]; then
	echo "  exists, skipping: ss-server.crt"
else
	openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 \
		-keyout ss-server.key -out ss-server.crt \
		-subj "/CN=xymon-ss-server/O=Xymon TLS Self-Signed" \
		-addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
		-addext "extendedKeyUsage=serverAuth" 2>/dev/null
	echo "  wrote ss-server.key, ss-server.crt"
fi

# Self-signed client identity.
echo "[2/2] Self-signed client (CN=xymon-ss-client)"
if [ -f ss-client.crt ]; then
	echo "  exists, skipping: ss-client.crt"
else
	openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 \
		-keyout ss-client.key -out ss-client.crt \
		-subj "/CN=xymon-ss-client/O=Xymon TLS Self-Signed" \
		-addext "extendedKeyUsage=clientAuth" 2>/dev/null
	echo "  wrote ss-client.key, ss-client.crt"
fi

echo
echo "Done. See the header of this script for pinning vs encrypt-only usage."
