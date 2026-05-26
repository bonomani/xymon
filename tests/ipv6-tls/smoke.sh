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
#   - unified --acl, broad-admin guard, --check-tls, deferred-command context
#   - size:N framing: malformed frames rejected, trailing bytes truncated
#   - --listen address-family binding (single-family wildcards, dual-stack)
#
# Requires a usable ::1 on loopback (GitHub Ubuntu runners have it; on a bare
# WSL box: `sudo ip addr add ::1/128 dev lo`). The size:N framing phase needs
# python3 (skipped if absent). Binaries are taken from the repo build unless
# XYMONDBIN/XYMONBIN are set.
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
		--listen=0.0.0.0:$PORT,[::]:$PORT --hosts="$H/etc/hosts.cfg" \
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

# raw_frame HOST PORT SIZESPEC BODY TAIL
# Send a literal "size:<SIZESPEC>\n<BODY><TAIL>" over plaintext TCP, half-close,
# print the reply. SIZESPEC="auto" => decimal byte-length of BODY. The official
# xymon client always frames correctly, so a deliberately *malformed* size:
# header (or trailing bytes past the count) can only be produced by hand.
raw_frame() {
	python3 -c '
import socket,sys
host=sys.argv[1]; port=int(sys.argv[2]); spec=sys.argv[3]
body=sys.argv[4].encode(); tail=sys.argv[5].encode()
n=str(len(body)) if spec=="auto" else spec
frame=b"size:"+n.encode()+b"\n"+body+tail
s=socket.create_connection((host,port),timeout=5)
s.sendall(frame); s.shutdown(socket.SHUT_WR)
out=b""
try:
    while True:
        b=s.recv(4096)
        if not b: break
        out+=b
except Exception: pass
sys.stdout.write(out.decode("utf-8","replace"))
' "$1" "$2" "$3" "$4" "$5"
}

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
# A CN-less client cert (subject has no commonName) to prove trust is gated on
# verification, not CN extraction.
openssl req -newkey rsa:2048 -keyout "$C/cnless.key" -out "$C/cnless.csr" -nodes -subj "/O=Xymon/OU=clients" 2>/dev/null
openssl x509 -req -in "$C/cnless.csr" -CA "$C/ca.pem" -CAkey "$C/ca.key" -CAcreateserial -out "$C/cnless.pem" -days 1 2>/dev/null
# An already-expired server cert, for the --check-tls validation phase.
openssl req -newkey rsa:2048 -keyout "$C/expired.key" -out "$C/expired.csr" -nodes -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in "$C/expired.csr" -CA "$C/ca.pem" -CAkey "$C/ca.key" -CAcreateserial -out "$C/expired.pem" -days -1 2>/dev/null

if ! ip -6 addr show lo 2>/dev/null | grep -qw "::1"; then
	echo "SKIP: no ::1 on loopback (run: sudo ip addr add ::1/128 dev lo)"; exit 77
fi

# ---- phase 1: TLS listener, client-cert optional --------------------------
echo "== phase 1: plaintext + TLS (verify) =="
start_xymond --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$C/ca.pem" || exit 1

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
start_xymond --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$C/ca.pem" --tls-require-clientcert || exit 1

has  "mTLS ping (with client cert)" "$(XYMON_TLS_CA=$C/ca.pem XYMON_TLS_CERT=$C/cli.pem XYMON_TLS_KEY=$C/cli.key cli "xymons://localhost:$TLSPORT" ping)" "xymond "
hasnot "no client cert -> rejected"  "$(XYMON_TLS_CA=$C/ca.pem cli "xymons://localhost:$TLSPORT" ping)"  "xymond "
stop_xymond

# ---- phase 3: cert-based ACL (status-senders restricted to exclude us) ----
echo "== phase 3: a verified cert is a trusted sender (via --acl) =="
# ACL: loopback may read the board in cleartext but NOT post status; only a
# verified client cert (over TLS) may post status. So a non-cert sender is
# rejected and only a cert-verified one gets through.
cat > "$work/acl3.cfg" <<EOF
local   plain   www
cert:*  tls     status
EOF
start_xymond --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" \
             --tls-ca="$C/ca.pem" --acl="$work/acl3.cfg" || exit 1

# no client cert: no rule grants it status -> dropped
XYMON_TLS_CA=$C/ca.pem cli "xymons://localhost:$TLSPORT" "status localhost.noaclcol green rejected?" >/dev/null
# client cert: 'cert:* tls status' -> accepted
XYMON_TLS_CA=$C/ca.pem XYMON_TLS_CERT=$C/cli.pem XYMON_TLS_KEY=$C/cli.key \
  cli "xymons://localhost:$TLSPORT" "status localhost.certaclcol green via cert" >/dev/null
# CN-less client cert: still verified, so still trusted (trust != CN extraction)
XYMON_TLS_CA=$C/ca.pem XYMON_TLS_CERT=$C/cnless.pem XYMON_TLS_KEY=$C/cnless.key \
  cli "xymons://localhost:$TLSPORT" "status localhost.cnlesscol green via CN-less cert" >/dev/null

board=$(cli "127.0.0.1:$PORT" "xymondboard fields=hostname,testname,color")
hasnot "non-cert sender denied by ACL"       "$board" "localhost|noaclcol|green"
has    "cert sender trusted by ACL"          "$board" "localhost|certaclcol|green"
has    "CN-less verified cert is trusted"    "$board" "localhost|cnlesscol|green"
stop_xymond

echo "== phase 4: --check-tls validation (exit 0 = ok, 1 = bad) =="
checktls() { XYMONHOME="$H" "$XYMONDBIN" --check-tls "$@" >/dev/null 2>&1; }
checktls --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$C/ca.pem" --tls-require-clientcert \
  && ok "check: valid mTLS material" || bad "check: valid mTLS material"
checktls --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" \
  && ok "check: valid encrypt-only" || bad "check: valid encrypt-only"
checktls --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-require-clientcert \
  && bad "check: require-clientcert without CA -> fail" || ok "check: require-clientcert without CA -> fail"
checktls --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$work/missing.pem" \
  && bad "check: missing CA -> fail" || ok "check: missing CA -> fail"
checktls --tls-cert="$C/expired.pem" --tls-key="$C/expired.key" \
  && bad "check: expired server cert -> fail" || ok "check: expired server cert -> fail"
# no server cert at all: TLS would be disabled, so the pre-flight must FAIL
# (exit 0 is reserved for "TLS would actually be served").
checktls \
  && bad "check: no --tls-cert -> fail (TLS disabled)" || ok "check: no --tls-cert -> fail (TLS disabled)"
# the removed legacy flag must be a hard error (migrate to --acl)
if XYMONHOME="$H" "$XYMONDBIN" --no-daemon --listen=0.0.0.0:$PORT --hosts="$H/etc/hosts.cfg" \
     --status-senders=127.0.0.1 >/dev/null 2>&1; then bad "removed --status-senders -> exit"; else ok "removed --status-senders -> exit"; fi
# a configured-but-empty ACL (file present, only blank/comment lines) must refuse
# to start, not silently fall through to "no --acl -> allow all" (fail-open).
printf '# only a comment, no rules\n\n' > "$work/acl-empty.cfg"
if XYMONHOME="$H" "$XYMONDBIN" --no-daemon --listen=0.0.0.0:$PORT --hosts="$H/etc/hosts.cfg" \
     --acl="$work/acl-empty.cfg" >/dev/null 2>&1; then bad "empty --acl -> exit"; else ok "empty --acl -> exit"; fi
# admin-breadth guard: granting admin to cert:* must refuse to start...
printf 'cert:*\ttls\tall\n' > "$work/acl-broad.cfg"
if XYMONHOME="$H" "$XYMONDBIN" --no-daemon --listen=0.0.0.0:$PORT --hosts="$H/etc/hosts.cfg" \
     --acl="$work/acl-broad.cfg" >/dev/null 2>&1; then bad "broad admin (cert:* all) -> exit"; else ok "broad admin (cert:* all) -> exit"; fi
# ...unless explicitly forced
printf 'cert:*\ttls\tall\tforce\n' > "$work/acl-forced.cfg"
XYMONHOME="$H" MAXACCEPTSPERLOOP=20 "$XYMONDBIN" --no-daemon --listen=0.0.0.0:$PORT --hosts="$H/etc/hosts.cfg" \
     --pidfile="$H/xymond.pid" --acl="$work/acl-forced.cfg" >/dev/null 2>&1 &
fp=$!; i=0; up=0
while [ $i -lt 20 ]; do ss -ltn 2>/dev/null | grep -q ":$PORT" && { up=1; break; }; kill -0 "$fp" 2>/dev/null || break; i=$((i+1)); sleep 0.1; done
kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
[ $up = 1 ] && ok "broad admin + force -> starts" || bad "broad admin + force -> starts"

echo "== phase 5: a broken TLS config degrades to plaintext (never kills the daemon) =="
# TLS setup failure must DISABLE TLS but keep the plaintext listener up: the
# daemon comes up on $PORT, and no broken/unverified TLS port is opened.
degrades() {  # label, extra args...
	label=$1; shift
	XYMONHOME="$H" MAXACCEPTSPERLOOP=20 "$XYMONDBIN" --no-daemon \
		--listen=0.0.0.0:$PORT --hosts="$H/etc/hosts.cfg" \
		--pidfile="$H/xymond.pid" "$@" >/dev/null 2>&1 &
	p=$!; i=0
	while [ $i -lt 30 ]; do ss -ltn 2>/dev/null | grep -q ":$PORT" && break; kill -0 "$p" 2>/dev/null || break; i=$((i+1)); sleep 0.1; done
	if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
		# plaintext up; the broken TLS port must NOT be listening
		if ss -ltn 2>/dev/null | grep -q ":$TLSPORT"; then bad "$label (broken TLS port opened!)"; else ok "$label"; fi
	else
		bad "$label (daemon did not come up on plaintext)"
	fi
	kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
}
degrades "require-clientcert without CA -> plaintext only" --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-require-clientcert
degrades "unloadable --tls-ca -> plaintext only"           --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" --tls-ca="$work/missing.pem"
degrades "unloadable --tls-cert -> plaintext only"         --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$work/missing.pem" --tls-key="$work/missing.key"
degrades "cert without --tls-listen -> plaintext only"     --tls-cert="$C/srv.pem" --tls-key="$C/srv.key"
degrades "--tls-listen without cert -> plaintext only"     --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT"

echo "== phase 6: unified capability ACL (--acl) =="
# loopback may do anything but only in cleartext; remote needs a verified cert.
cat > "$work/acl.cfg" <<EOF
# unified capability ACL
local   plain   all
cert:*  tls     status,www
EOF
start_xymond --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" \
             --tls-ca="$C/ca.pem" --acl="$work/acl.cfg" || exit 1
# 1. plaintext loopback -> 'local plain all' -> allowed
cli "127.0.0.1:$PORT" "status localhost.aclplain green via plaintext local" >/dev/null
# 2. TLS + verified client cert -> 'cert:* tls status' -> allowed
XYMON_TLS_CA=$C/ca.pem XYMON_TLS_CERT=$C/cli.pem XYMON_TLS_KEY=$C/cli.key \
  cli "xymons://localhost:$TLSPORT" "status localhost.aclcert green via cert" >/dev/null
# 3. TLS WITHOUT cert -> local rule is plaintext-only, cert:* needs a cert -> denied
XYMON_TLS_CA=$C/ca.pem \
  cli "xymons://localhost:$TLSPORT" "status localhost.acltlsnocert green should be denied" >/dev/null
board=$(cli "127.0.0.1:$PORT" "xymondboard fields=hostname,testname,color")   # 'local plain all' grants www
has    "ACL: plaintext loopback allowed"       "$board" "localhost|aclplain|green"
has    "ACL: verified cert over TLS allowed"   "$board" "localhost|aclcert|green"
hasnot "ACL: TLS-without-cert denied (default deny + transport)" "$board" "localhost|acltlsnocert|green"
stop_xymond

echo "== phase 7: a scheduled command runs with the submitter's ACL context =="
# Loopback may do anything, but only over TLS. The deferred command therefore
# only runs if the scheduler replays the submitter's encrypted/cert context
# (not just the source IP): a plaintext replay would fail this rule's transport.
cat > "$work/acl-sched.cfg" <<EOF
local   tls   all
EOF
start_xymond --tls-listen="0.0.0.0:$TLSPORT,[::]:$TLSPORT" --tls-cert="$C/srv.pem" --tls-key="$C/srv.key" \
             --tls-ca="$C/ca.pem" --acl="$work/acl-sched.cfg" || exit 1
# Seed the test (status), then schedule a disable for "now" over the SAME TLS
# connection kind. 'schedule' needs admin, the deferred 'disable' needs maint;
# 'local tls all' grants both, but only because the run-time check sees TLS.
XYMON_TLS_VERIFY=none cli "xymons://[::1]:$TLSPORT" "status localhost.schedtest green seed" >/dev/null
XYMON_TLS_VERIFY=none cli "xymons://[::1]:$TLSPORT" "schedule $(date +%s) disable localhost.schedtest 5 deferred-via-tls" >/dev/null
# Wait for the scheduler loop to fire; a disabled test shows blue.
i=0; board=
while [ $i -lt 30 ]; do
	board=$(XYMON_TLS_VERIFY=none cli "xymons://[::1]:$TLSPORT" "xymondboard fields=hostname,testname,color")
	case "$board" in *"localhost|schedtest|blue"*) break ;; esac
	i=$((i+1)); sleep 0.2
done
has "ACL: scheduled disable ran (TLS context replayed)" "$board" "localhost|schedtest|blue"
stop_xymond

echo "== phase 8: size:N framing -- malformed frames rejected, trailing bytes truncated =="
# The size:N frame is parsed on any transport (it's how TLS dispatches without a
# reliable EOF), so we exercise it cheaply over plaintext with hand-built frames.
if ! command -v python3 >/dev/null 2>&1; then
	echo "  SKIP - phase 8 needs python3 to send raw (deliberately malformed) frames"
else
	start_xymond || exit 1   # plaintext-only; no --acl => sends are accepted
	# 1. a well-formed raw size:N frame is delivered (positive control)
	raw_frame 127.0.0.1 $PORT auto "status localhost.rawok green raw-ok" "" >/dev/null
	# 2. trailing garbage in the count ("size:99x") must be rejected, not read as 99
	raw_frame 127.0.0.1 $PORT "99x" "status localhost.rawbadnum green should-drop" "" >/dev/null
	# 3. a zero count is rejected
	raw_frame 127.0.0.1 $PORT "0" "status localhost.rawzero green should-drop" "" >/dev/null
	# 4. bytes past the declared size are truncated, not folded into the body:
	#    size = len(BODY); the MARKER_TAIL bytes that follow must be discarded.
	raw_frame 127.0.0.1 $PORT auto "status localhost.rawtrunc green MARKER_CLEAN" "MARKER_TAIL" >/dev/null
	i=0; board=
	while [ $i -lt 25 ]; do
		board=$(cli "127.0.0.1:$PORT" "xymondboard fields=hostname,testname,color,msg")
		case "$board" in *"localhost|rawok|green"*) break ;; esac
		i=$((i+1)); sleep 0.2
	done
	has    "raw size:N frame delivered"                  "$board" "localhost|rawok|green"
	hasnot "size:N trailing garbage in count rejected"   "$board" "localhost|rawbadnum|green"
	hasnot "size:0 rejected"                             "$board" "localhost|rawzero|green"
	has    "trailing bytes truncated (declared body kept)" "$board" "MARKER_CLEAN"
	hasnot "trailing bytes truncated (excess discarded)"   "$board" "MARKER_TAIL"
	stop_xymond
fi

echo "== phase 9: --listen address-family binding (single-family wildcards) =="
# An explicit wildcard binds ONE family (0.0.0.0 => IPv4, [::] => IPv6); omitting
# --listen is dual-stack; a comma list is explicit dual-stack.
# lstart SPEC : start plaintext-only xymond with --listen=SPEC; 0 if $PORT is up.
lstart() {
	XYMONHOME="$H" MAXACCEPTSPERLOOP=20 "$XYMONDBIN" --no-daemon \
		--listen="$1" --hosts="$H/etc/hosts.cfg" --pidfile="$H/xymond.pid" \
		> "$work/xymond.log" 2>&1 &
	xymond_pid=$!
	i=0
	while [ $i -lt 50 ]; do
		ss -ltn 2>/dev/null | grep -q ":$PORT" && return 0
		kill -0 "$xymond_pid" 2>/dev/null || return 1
		i=$((i+1)); sleep 0.1
	done
	return 1
}

if lstart "0.0.0.0:$PORT"; then
	has    "0.0.0.0 wildcard: IPv4 served"      "$(cli "127.0.0.1:$PORT" ping)" "xymond "
	hasnot "0.0.0.0 wildcard: IPv6 NOT served"  "$(cli "[::1]:$PORT" ping)"     "xymond "
else bad "0.0.0.0 wildcard: daemon failed to start"; fi
stop_xymond

if lstart "[::]:$PORT"; then
	has    "[::] wildcard: IPv6 served"         "$(cli "[::1]:$PORT" ping)"     "xymond "
	hasnot "[::] wildcard: IPv4 NOT served"     "$(cli "127.0.0.1:$PORT" ping)" "xymond "
else bad "[::] wildcard: daemon failed to start"; fi
stop_xymond

if lstart "0.0.0.0:$PORT,[::]:$PORT"; then
	has    "comma list: IPv4 served"            "$(cli "127.0.0.1:$PORT" ping)" "xymond "
	has    "comma list: IPv6 served"            "$(cli "[::1]:$PORT" ping)"     "xymond "
else bad "comma list: daemon failed to start"; fi
stop_xymond

# --listen omitted => dual-stack default (port from XYMONDPORT)
XYMONHOME="$H" XYMONDPORT=$PORT MAXACCEPTSPERLOOP=20 "$XYMONDBIN" --no-daemon \
	--hosts="$H/etc/hosts.cfg" --pidfile="$H/xymond.pid" > "$work/xymond.log" 2>&1 &
xymond_pid=$!
i=0; while [ $i -lt 50 ]; do ss -ltn 2>/dev/null | grep -q ":$PORT" && break; kill -0 "$xymond_pid" 2>/dev/null || break; i=$((i+1)); sleep 0.1; done
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
	has "omitted --listen: IPv4 served (dual-stack default)" "$(cli "127.0.0.1:$PORT" ping)" "xymond "
	has "omitted --listen: IPv6 served (dual-stack default)" "$(cli "[::1]:$PORT" ping)"     "xymond "
else bad "omitted --listen: daemon failed to start on dual-stack default"; fi
stop_xymond

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
