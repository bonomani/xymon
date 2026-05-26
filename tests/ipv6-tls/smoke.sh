#!/bin/sh
#
# End-to-end smoke test for the IPv6 + TLS work on feat/ipv6-tls.
#
# Exercises, against a freshly-built xymond + xymon client, over a real IPv6
# loopback (::1) and IPv4:
#   - plaintext ping/status over IPv4 and pure IPv6
#   - TLS (xymons://) ping/status with enforced server-cert verification
#   - encrypt-only (XYMON_TLS_VERIFY=none)
#   - verification fails closed (verify=full with no CA -> refused)
#   - mTLS: client cert accepted; missing client cert rejected
#
# Requires a usable ::1 on loopback (GitHub Ubuntu runners have it; on a bare
# WSL box: `sudo ip addr add ::1/128 dev lo`). Binaries are taken from the repo
# build unless XYMONDBIN/XYMONBIN are set.
#
# Exit 0 = all checks passed; non-zero = a check failed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
XYMONDBIN=${XYMONDBIN:-$repo/xymond/xymond}
XYMONBIN=${XYMONBIN:-$repo/common/xymon}
PORT=${PORT:-19840}
TLSPORT=${TLSPORT:-19841}

work=$(mktemp -d "${TMPDIR:-/tmp}/xy-tls-smoke.XXXXXX")
H="$work/home"
pass=0; fail=0; xymond_pid=

cleanup() {
	[ -n "$xymond_pid" ] && kill "$xymond_pid" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

ok()   { echo "  ok   - $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $1"; fail=$((fail+1)); }
# assert that "$2" (haystack) contains "$3" (needle)
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (got: $(echo "$2" | head -1))" ;; esac; }
hasnot() { case "$2" in *"$3"*) bad "$1 (unexpectedly got: $3)" ;; *) ok "$1" ;; esac; }

start_xymond() {  # extra args...
	XYMONHOME="$H" MAXACCEPTSPERLOOP=20 "$XYMONDBIN" --no-daemon \
		--listen=0.0.0.0:$PORT --hosts="$H/etc/hosts.cfg" \
		--pidfile="$H/xymond.pid" "$@" > "$work/xymond.log" 2>&1 &
	xymond_pid=$!
	i=0
	while [ $i -lt 50 ]; do
		ss -ltn 2>/dev/null | grep -q ":$PORT" && return 0
		i=$((i+1)); sleep 0.1
	done
	echo "xymond failed to start:"; cat "$work/xymond.log"; return 1
}
stop_xymond() { [ -n "$xymond_pid" ] && kill "$xymond_pid" 2>/dev/null; wait "$xymond_pid" 2>/dev/null; xymond_pid=; }

cli() { XYMONHOME="$H" "$XYMONBIN" "$@" 2>&1; }

# ---- setup: home + certs --------------------------------------------------
mkdir -p "$H/etc" "$H/tmp" "$H/logs" "$H/data" "$H/www/rep" "$H/www/snap"
printf '0.0.0.0\tlocalhost\t#\n' > "$H/etc/hosts.cfg"
[ -f "$repo/xymond/etcfiles/xymonserver.cfg" ] && cp "$repo/xymond/etcfiles/xymonserver.cfg" "$H/etc/" 2>/dev/null

C="$work/certs"; mkdir -p "$C"
openssl req -x509 -newkey rsa:2048 -keyout "$C/ca.key" -out "$C/ca.pem" -days 1 -nodes -subj "/CN=Xymon Test CA" 2>/dev/null
openssl req -newkey rsa:2048 -keyout "$C/srv.key" -out "$C/srv.csr" -nodes -subj "/CN=localhost" 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:::1\n' > "$C/srv.ext"
openssl x509 -req -in "$C/srv.csr" -CA "$C/ca.pem" -CAkey "$C/ca.key" -CAcreateserial -out "$C/srv.pem" -days 1 -extfile "$C/srv.ext" 2>/dev/null
openssl req -newkey rsa:2048 -keyout "$C/cli.key" -out "$C/cli.csr" -nodes -subj "/CN=xymon-client-01" 2>/dev/null
openssl x509 -req -in "$C/cli.csr" -CA "$C/ca.pem" -CAkey "$C/ca.key" -CAcreateserial -out "$C/cli.pem" -days 1 2>/dev/null

if ! ip -6 addr show lo 2>/dev/null | grep -qw "::1"; then
	echo "SKIP: no ::1 on loopback (run: sudo ip addr add ::1/128 dev lo)"; exit 77
fi

# ---- phase 1: TLS listener, client-cert optional --------------------------
echo "== phase 1: plaintext + TLS (verify) =="
start_xymond --tls-listen="[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$C/ca.pem" || exit 1

has  "IPv4 plaintext ping"        "$(cli "127.0.0.1:$PORT" ping)"                                   "xymond "
has  "pure IPv6 plaintext ping"   "$(cli "[::1]:$PORT" ping)"                                       "xymond "
has  "TLS ping (verify w/ CA)"     "$(XYMON_TLS_CA=$C/ca.pem cli "xymons://localhost:$TLSPORT" ping)" "xymond "
XYMON_TLS_CA=$C/ca.pem cli "xymons://localhost:$TLSPORT" "status localhost.tlssmoke green smoke" >/dev/null
has  "TLS status -> board"        "$(cli "127.0.0.1:$PORT" "xymondboard fields=hostname,testname,color")" "localhost|tlssmoke|green"
has  "TLS encrypt-only (none)"    "$(XYMON_TLS_VERIFY=none cli "xymons://[::1]:$TLSPORT" ping)"      "xymond "
hasnot "verify=full, no CA -> refused" "$(cli "xymons://localhost:$TLSPORT" ping)"                  "xymond "
has  "mTLS ping (client cert)"    "$(XYMON_TLS_CA=$C/ca.pem XYMON_TLS_CERT=$C/cli.pem XYMON_TLS_KEY=$C/cli.key cli "xymons://localhost:$TLSPORT" ping)" "xymond "
stop_xymond

# ---- phase 2: client cert REQUIRED ----------------------------------------
echo "== phase 2: mTLS required =="
start_xymond --tls-listen="[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$C/ca.pem" --tls-require-clientcert || exit 1

has  "mTLS ping (with client cert)" "$(XYMON_TLS_CA=$C/ca.pem XYMON_TLS_CERT=$C/cli.pem XYMON_TLS_KEY=$C/cli.key cli "xymons://localhost:$TLSPORT" ping)" "xymond "
hasnot "no client cert -> rejected"  "$(XYMON_TLS_CA=$C/ca.pem cli "xymons://localhost:$TLSPORT" ping)"  "xymond "
stop_xymond

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
