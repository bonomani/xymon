#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/network/dialogue-starttls.sh
#
# Explicit TLS: plaintext, then an upgrade in the middle of the conversation.
#
# "options ssl" means TLS from the first byte, which is a different port and a
# different service. SMTP on 25, submission on 587 and IMAP on 143 open in
# plaintext and upgrade with STARTTLS -- and that is the mode most mail
# actually uses, since opportunistic TLS between servers is STARTTLS on 25 and
# implicit TLS is the minority case on 465 and 993.
#
# Until "start tls" existed there was no way to say it, so those services could
# not be checked past the greeting and could never reach a certificate at all.
#
# LAYER: the driver, end to end, against a server that speaks the protocol.
# Three things have to hold, and the third is the point:
#
#   1. the EHLO goes out BEFORE the upgrade and a second one AFTER it, so the
#      upgrade really happened mid-conversation rather than at connect;
#   2. the certificate is read off the UPGRADED session -- that is the half
#      people ask for, since a plaintext port has no certificate before it;
#   3. a server that agrees to STARTTLS and then fails the handshake is NOT
#      reported up. That is the failure this could most easily get wrong,
#      because everything up to the handshake looked fine.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

root=$(find_root)
require_bin XYMONNET xymonnet/xymonnet
: "${CC:=cc}"
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
command -v openssl >/dev/null 2>&1 || skip "openssl CLI needed for the test certificate"

work=$(mktempdir); register_cleanup "rm -rf '$work'"
mkdir -p "$work/home/etc"

openssl req -x509 -newkey rsa:2048 -keyout "$work/key.pem" -out "$work/cert.pem" \
	-days 30 -nodes -subj "/CN=mail.test.local" >"$work/ssl.log" 2>&1 \
	|| skip "openssl could not generate a test certificate"

"$CC" -o "$work/peer" "$root/tests/lib/dialogue-peer.c" -lssl -lcrypto 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; skip "dialogue-peer does not compile against libssl"; }

# A server that upgrades properly, and one that agrees and then does not.
printf '%s\n' 'send "220 mail.test.local ESMTP\r\n"' \
	      'recv ehlo' \
	      'send "250-mail.test.local\r\n250 STARTTLS\r\n"' \
	      'recv starttls' \
	      'send "220 2.0.0 Ready to start TLS\r\n"' \
	      'starttls' \
	      'recv ehlo' \
	      'send "250 mail.test.local\r\n"' \
	      'hangup'                                   > "$work/good.script"

printf '%s\n' 'send "220 mail.test.local ESMTP\r\n"' \
	      'recv ehlo' \
	      'send "250-mail.test.local\r\n250 STARTTLS\r\n"' \
	      'recv starttls' \
	      'send "220 2.0.0 Ready to start TLS\r\n"' \
	      'send "this is not a ServerHello\r\n"' \
	      'hold 10'                                  > "$work/bad.script"

: > "$work/pids"
start_peer() {	# script portfile obsfile
	"$work/peer" "$1" "$3" "$work/cert.pem" "$work/key.pem" > "$2" &
	echo $! >> "$work/pids"
	i=0
	while [ "$i" -lt 60 ]; do [ -s "$2" ] && break; sleep 0.1; i=$((i + 1)); done
	cat "$2"
}
pgood=$(start_peer "$work/good.script" "$work/pg" "$work/og")
pbad=$(start_peer  "$work/bad.script"  "$work/pb" "$work/ob")
register_cleanup "kill $(tr '\n' ' ' < "$work/pids") 2>/dev/null || :"
[ -n "$pgood" ] && [ -n "$pbad" ] || skip "a peer never named its port"

entry() {	# name port
	printf '[%s]\n   expect "220" until "220 "\n   send "ehlo xymonnet\\r\\n"\n   expect "250" until "250 "\n   send "starttls\\r\\n"\n   expect "220"\n   start tls\n   send "ehlo xymonnet\\r\\n"\n   expect "250"\n   options banner\n   port %s\n\n' "$1" "$2"
}
{ entry tlsok "$pgood"; entry tlsbad "$pbad"; } > "$work/home/etc/protocols.cfg"
printf '127.0.0.1\tgood\t# tlsok\n127.0.0.1\tbad\t# tlsbad\n' > "$work/home/etc/hosts.cfg"

XYMONHOME="$work/home" "$XYMONNET" --no-update --noping --checkresponse=red \
	--dns=ip --timeout=30 >"$work/out.txt" 2>&1 || :

colour_of() { grep -oE "status\+[0-9]+ $1 (green|yellow|red|clear)" "$work/out.txt" | awk '{print $3}' | head -1; }

# 1. the conversation completes, over an upgraded connection
[ "$(colour_of good.tlsok)" = green ] || fail \
	"a server that upgraded properly was not green (got '$(colour_of good.tlsok)'):
$(grep -i tlsok "$work/out.txt" | head -4)
peer recorded: $(tr '\n' ' ' < "$work/og")"

# 2. the upgrade happened in the MIDDLE: an EHLO before it and one after.
#    A green reached without the second EHLO would mean the probe stopped at
#    the handshake and never spoke over the encrypted connection at all.
awk '/^tls-ok/{seen=1} /^got ehlo/{n++; if (seen) after=1} END{exit !(n >= 2 && after)}' "$work/og" || fail \
	"the second EHLO did not arrive after the upgrade, so nothing was sent
over the encrypted connection:
$(cat "$work/og")"

# 3. THE CERTIFICATE, read off the upgraded session. This is what a plaintext
#    port cannot otherwise reach, and the reason for the whole exercise.
grep -qE "status\+[0-9]+ good\.sslcert " "$work/out.txt" || fail \
	"no sslcert status was sent for the upgraded connection, so the certificate
was never read:
$(grep -iE 'sslcert|tlsok' "$work/out.txt" | head -5)"

# 4. an upgrade that fails is not success
[ "$(colour_of bad.tlsbad)" != green ] || fail \
	"a server that agreed to STARTTLS and then failed the handshake was reported
GREEN. Everything before the handshake looked fine, which is exactly why this
has to be checked:
$(grep -i tlsbad "$work/out.txt" | head -4)"

pass "a dialogue upgrades mid-conversation, speaks over the upgraded session, reaches the certificate, and does not call a failed handshake success"
