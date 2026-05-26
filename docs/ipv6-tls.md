Xymon over IPv6 and TLS
=======================

This branch adds native **IPv6** and **TLS/mTLS** transport to xymond and the
`xymon` client. Both are opt-in; an unconfigured server behaves exactly as
before (IPv4 + plaintext), and the changes are compiled out entirely when the
build has no OpenSSL.

- **IPv6** — xymond listens dual-stack and the client can reach v4/v6 literals
  or hostnames.
- **TLS** — an encrypted listener (`xymons://`), with the client verifying the
  server certificate by default.
- **mTLS** — the server can require + verify a client certificate.
- **Certificate-based sender authorization** — a verified client cert is a
  trusted sender, bypassing the IP-based access list (admin commands excepted).


IPv6
----
xymond's listener is now dual-stack. With the usual `--listen=0.0.0.0:1984`
(or no `--listen`), it binds `[::]:1984`, which on Linux (`net.ipv6.bindv6only=0`)
accepts both IPv6 and IPv4-mapped clients. To bind a specific address use
`--listen=<ip>:<port>`; an IPv6 literal is written `[2001:db8::1]:1984`.

The `xymon` client accepts IPv4/IPv6 literals and hostnames as the recipient:

    xymon 192.0.2.10:1984        "status ..."
    xymon [2001:db8::10]:1984    "status ..."
    xymon myserver.example:1984  "status ..."   # resolves to v4 or v6


TLS server
----------
Enable a TLS listener with a certificate and key:

    xymond --listen=0.0.0.0:1984 \
           --tls-listen=[::]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key

| Option | Meaning |
|--------|---------|
| `--tls-listen=SPEC` | Address(es) for the implicit-TLS listener, e.g. `[::]:1985` or `0.0.0.0:1985`. |
| `--tls-cert=FILE` | PEM server certificate. |
| `--tls-key=FILE` | PEM private key (defaults to the cert file if omitted). |
| `--tls-ca=FILE` | PEM trust store for **client** certificates — enables mTLS verification. |
| `--tls-require-clientcert` | Reject connections that don't present a (CA-verified) client cert. |

The plaintext `--listen` port keeps working alongside the TLS port.


TLS client (`xymons://`)
------------------------
Send over TLS by using the `xymons://` recipient scheme (default port **1985**):

    XYMON_TLS_CA=/etc/xymon/tls/ca.pem \
      xymon "xymons://myserver.example:1985" "status ..."

Client behaviour is controlled by environment variables:

| Variable | Meaning |
|----------|---------|
| `XYMON_TLS_VERIFY` | `full` (default) = verify the server cert chain **and** hostname/IP; `peer` = verify the chain only (pinning, no name check); `none` = no verification (encryption only — MITM-able, logs a warning). |
| `XYMON_TLS_CA` | PEM trust file for the server cert (a real CA, or a pinned self-signed cert). **Required unless `XYMON_TLS_VERIFY=none`** — the client fails closed otherwise. |
| `XYMON_TLS_CERT` / `XYMON_TLS_KEY` | Client certificate + key, for mTLS. Set both or neither. |
| `XYMON_TLS_SNI` | Override the name used for SNI + cert verification (e.g. when connecting to an IP whose cert names a hostname). |

Name matching follows RFC 6066/6125: a DNS name is sent as SNI and matched
against `dNSName` SANs; an IP literal is matched against `iPAddress` SANs (and
not sent as SNI).


Mutual TLS (mTLS)
-----------------
Server — require and verify client certs:

    xymond --tls-listen=[::]:1985 --tls-cert=server.pem --tls-key=server.key \
           --tls-ca=ca.pem --tls-require-clientcert

Client — present a certificate:

    XYMON_TLS_CA=ca.pem XYMON_TLS_CERT=client.pem XYMON_TLS_KEY=client.key \
      xymon "xymons://myserver.example:1985" "status ..."

A client without a (valid) cert is rejected at the handshake.


Certificate-based sender authorization
---------------------------------------
When a client presents a TLS certificate that verifies against `--tls-ca`, that
connection is a **trusted sender**: its `status`/`data`/notification/query
messages bypass the IP-based sender access lists (`--status-senders`,
`--www-senders`, `--maint-senders`). The CA is the trust anchor, so you no
longer have to enumerate sender IPs — and it works for IPv6 senders, where the
legacy IPv4 access list can't express the address.

**Admin/config commands are excluded**: `drop`, `rename`, etc. still require the
source IP to be in `--admin-senders`, even over a cert-verified connection. A
certificate grants "trusted reporter", not "administrator".


Generating test certificates
-----------------------------
A self-signed server cert (encrypt + pin):

    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
      -keyout server.key -out server.pem -subj "/CN=myserver.example" \
      -addext "subjectAltName=DNS:myserver.example,IP:2001:db8::10"

A CA that signs a server and a client cert (for verification + mTLS):

    # CA
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout ca.key -out ca.pem -subj "/CN=Xymon CA"
    # server (with SANs)
    openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
      -subj "/CN=myserver.example"
    printf 'subjectAltName=DNS:myserver.example,IP:2001:db8::10\n' > server.ext
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
      -out server.pem -days 365 -extfile server.ext
    # client
    openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
      -subj "/CN=xymon-client-01"
    openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
      -out client.pem -days 365

Point the client at `ca.pem` (`XYMON_TLS_CA`) and the server at the same
`ca.pem` (`--tls-ca`) to verify each other.


Notes
-----
- **Wire framing over TLS:** TLS messages are length-prefixed (`size:N\n`), so a
  message is delimited by its declared size rather than connection close. The
  `xymon` client does this automatically; plaintext keeps the classic
  read-to-EOF framing.
- **Protocol floor:** TLS 1.2 minimum (SSLv3/TLS 1.0/1.1 refused); TLS 1.3 is
  negotiated where available.
- **Build:** IPv6 is detected by a `configure` probe; TLS support follows the
  existing OpenSSL/`--enable-ssl` detection. Works with OpenSSL 1.1.1+/3.x and
  LibreSSL.


Testing
-------
`tests/ipv6-tls/smoke.sh` is a self-contained end-to-end test (generates its own
certs, starts xymond, exercises IPv4/IPv6 plaintext, TLS with verification,
encrypt-only, mTLS, and the cert-based ACL). It needs a usable `::1`
(`sudo ip addr add ::1/128 dev lo` on a host that lacks one):

    sh tests/ipv6-tls/smoke.sh        # 11 checks
