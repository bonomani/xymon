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

For copy-paste setup per deployment (isolated / internet / hybrid), see
`ipv6-tls-deployment.md`. This document is the reference for the *why* and the
full option/ACL detail.


IPv6
----
xymond can listen on IPv4, IPv6, or both, using a dedicated socket per address
family — it does not rely on IPv4-mapped IPv6 sockets, so behavior does not
depend on the host's `net.ipv6.bindv6only` setting.

When `--listen` is **omitted**, xymond defaults to dual-stack and opens both
`0.0.0.0:1984` and `[::]:1984`. An **explicit** value binds exactly what you ask
for: a wildcard binds a single family, and dual-stack is a comma list.

    xymond                                    # --listen omitted: dual-stack (0.0.0.0 + [::])
    xymond --listen=0.0.0.0:1984              # IPv4 wildcard only
    xymond --listen=[::]:1984                 # IPv6 wildcard only
    xymond --listen=0.0.0.0:1984,[::]:1984    # explicit dual-stack
    xymond --listen=192.0.2.10:1984           # one IPv4 address
    xymond --listen=[2001:db8::10]:1984       # one IPv6 address
    xymond --listen=127.0.0.1:1984            # IPv4 loopback only
    xymond --listen=[::1]:1984                # IPv6 loopback only

The same address syntax applies to `--tls-listen`.

The `xymon` client accepts IPv4/IPv6 literals and hostnames as the recipient:

    xymon 192.0.2.10:1984        "status ..."
    xymon [2001:db8::10]:1984    "status ..."
    xymon myserver.example:1984  "status ..."   # resolves to v4 or v6


TLS server
----------
Enable a TLS listener with a certificate and key:

    xymond --listen=0.0.0.0:1984,[::]:1984 \
           --tls-listen=0.0.0.0:1985,[::]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key

| Option | Meaning |
|--------|---------|
| `--tls-listen=SPEC` | Address(es) for the implicit-TLS listener; same binding rules as `--listen` (wildcard = one family, comma list = dual-stack), e.g. `0.0.0.0:1985,[::]:1985`. |
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

The client chooses its security level **explicitly, per recipient** — it never
silently downgrades. A `xymons://` recipient that cannot establish TLS *fails*
(it does not retry in plaintext), so a broken transport surfaces as an error
rather than being papered over. (The address-level retry across a host's
resolved IPv4/IPv6 addresses is connection failover, not a security downgrade.)


Rolling out TLS across a fleet
------------------------------
`XYMSERVERS` is a whitespace-separated recipient list, and **each entry's scheme
is independent**, so you can mix levels during a migration:

    XYMSERVERS="xymons://newsrv.example  xymon://legacy.example"

Per-recipient knob is the **scheme** (`xymons://` vs `xymon://`); the
`XYMON_TLS_*` variables are **process-global** — one cert/verify policy for all
TLS recipients in a given run.

Relax *verification*, never *encryption*. The safe way to onboard hosts before
every CA/cert is in place is to keep `xymons://` (encryption stays mandatory)
and loosen only `XYMON_TLS_VERIFY`:

1. `xymons://` + `XYMON_TLS_VERIFY=none` — encrypted, no verification (bootstrap).
2. `XYMON_TLS_VERIFY=peer` once the server cert is pinned/trusted.
3. `XYMON_TLS_VERIFY=full` (default) once names/SANs are correct.

Server-side, leave `--tls-require-clientcert` **off** until every client has a
cert: client certs are then optional — a client with one is a trusted sender,
one without falls back to the IP sender ACLs. Flip `--tls-require-clientcert`
on only after the fleet is fully enrolled.

There is deliberately **no automatic client fallback to plaintext**, and no
"plaintext-allowed" IP whitelist: an attacker who can break a TLS handshake
could otherwise force the cleartext path (a stripping/downgrade attack), and a
monitoring agent that silently sends in the clear hides exactly the transport
failure you want alerted. Encrypt-vs-plaintext is therefore an explicit,
per-recipient choice (the scheme), not a negotiated-down default.


Mutual TLS (mTLS)
-----------------
Server — require and verify client certs:

    xymond --tls-listen=[::]:1985 --tls-cert=server.pem --tls-key=server.key \
           --tls-ca=ca.pem --tls-require-clientcert

Client — present a certificate:

    XYMON_TLS_CA=ca.pem XYMON_TLS_CERT=client.pem XYMON_TLS_KEY=client.key \
      xymon "xymons://myserver.example:1985" "status ..."

A client without a (valid) cert is rejected at the handshake.


Access control (`--acl`)
------------------------
xymond's sender access control is a single, ordered, **capability-based,
transport-aware, IPv4/IPv6** rule table loaded with `--acl=FILE`. (The four
legacy IPv4-only `--*-senders` lists were removed; passing one now exits with a
"use --acl" error. `ipaccess.c` survives only for `msgcache` and `--trace`.)

Each line is `SOURCE TRANSPORT CAPS`:

- **SOURCE** — a v4/v6 CIDR (bare address = host), `local` (loopback `127/8` +
  `::1`), `cert:*` (any verified client cert), or `cert:<id>` (a cert whose CN
  matches `<id>`).
- **TRANSPORT** — `tls` (require encryption), `plain` (require cleartext), `any`.
- **CAPS** — any of `status,www,maint,admin` (or `all`).

**Matching:** first match wins; **if no rule matches, the request is denied**;
order rules specific-before-general. There are no built-in rules — the table is
exactly what you write. Two things sit outside it: the **local backfeed IPC
channel** (sender `0.0.0.0`) is always trusted, and if **no `--acl` is given at
all** xymond allows everything (the historical "no sender list" default) — so
access control is opt-in, but once opted in it is default-deny. A file that is
present but holds **no rules** (only blank/comment lines) is a configuration
error and aborts startup, rather than silently reverting to allow-all.

The default install ships `etc/xymonacl.cfg` and `tasks.cfg` points `--acl` at
it. Its shipped policy gives the loopback host full admin and lets every other
sender report status / run www+maint queries but not admin — edit it for your
site. (Comment out the `--acl` line in `tasks.cfg` for the fully-open default.)

Example expressing localhost-full, intranet-may-use-plaintext, remote-must-be-
TLS+cert, and a named admin identity:

    cert:ops-admin  tls   all                 # named admin identity (before cert:*)
    local           any   all                 # loopback: anything
    10.0.0.0/8      any   status,www,maint    # intranet: report/query, no admin
    2001:db8::/32   any   status,www,maint
    cert:*          tls   status,www          # any verified cert: reporter only
    # anything else: denied

A **verified client certificate** that chains to `--tls-ca` is matched by
`cert:*` / `cert:<id>` rules — the CA is the trust anchor, so you don't enumerate
sender IPs, and it works for IPv6 senders that the old IPv4 list couldn't
express. **Admin is not special-cased**: a cert is "admin" only if a rule grants
it `admin`/`all`. `--acl` is also where you **require encryption** from untrusted
networks — give them only a `tls` rule.

**Admin-breadth safety net.** Since admin is no longer hard-guarded, xymond
**refuses to start** if a rule grants admin (via `admin` or `all`) to a *broad*
source — `cert:*` (any verified cert) or a CIDR wider than `/24` (v4) / `/120`
(v6). `local` and a named `cert:<id>` are never broad. This makes "everyone is
an admin" hard to do by accident; an intentionally broad admin grant must
acknowledge it with a trailing `force`:

    cert:*        tls   all          # FATAL at startup (broad admin)
    cert:*        tls   all   force  # allowed: explicitly acknowledged
    cert:ops      tls   all          # fine: a specific cert identity
    local         any   all          # fine: loopback only

So the safe pattern is to grant `admin` to specific hosts or named cert
identities, and keep it off your wide `cert:*` / network rules.


Operations: TLS failure handling and pre-flight checks
------------------------------------------------------
TLS is **decoupled from plaintext, and fails closed on the TLS side only**. The
plaintext `--listen` port is always present and is never taken down by a TLS
problem, so clients can always reach the daemon. But a broken TLS setup never
results in *weakened* TLS either: the affected TLS service is **disabled** (the
port is simply not opened, and STARTTLS on the plaintext port is turned off too,
since both share one context), and the failure is **logged loudly**:

- `--tls-cert`/`--tls-key` that won't load → TLS disabled, plaintext kept.
- `--tls-ca` that won't load → TLS disabled (never served with client-cert
  verification silently off — that would be a fail-open bypass), plaintext kept.
- `--tls-listen` requested but no TLS socket binds (port in use, pure-IPv6 on a
  host without IPv6, …) → TLS port absent, plaintext kept.
- `--tls-require-clientcert` without `--tls-ca` → TLS disabled (nothing to verify
  client certs against, so "require" can't be honoured), plaintext kept.
- Incoherent flags (`--tls-cert` without `--tls-listen`, `--tls-listen` without
  `--tls-cert`, or `--tls-key`/`--tls-ca`/`--tls-require-clientcert` without
  `--tls-cert`) → warned, no TLS, plaintext kept.

The daemon only exits if it can bind **no** listener at all (not even plaintext).
A TLS client hitting a disabled TLS port gets a connection failure (loud), never
a silent downgrade — there is intentionally no auto-fallback to plaintext.

The TLS material is read **once, at startup** — there is no hot reload (a `reload`
or `SIGHUP` only re-reads `hosts.cfg`/client config). A running daemon therefore
never changes TLS state because the cert or CA file later changes on disk. The
flip side: a bad `--tls-ca` (e.g. a half-written file mid-rotation) stays latent
until the next restart, and *then* disables TLS. So **replace cert/CA files
atomically** (write a temp file, then `rename()` it into place).

Because startup now *degrades* rather than aborting, use `--check-tls` to get a
non-zero exit on a broken TLS config — validate the material without binding or
daemonizing:

    xymond --check-tls --tls-cert=server.pem --tls-key=server.key --tls-ca=ca.pem

Exit code `0` means TLS **would actually be served**; `1` means TLS would be
**disabled** (the daemon would still come up on plaintext). The check enforces
the same flag-coherence rules as startup and additionally fails an **expired /
not-yet-valid** server certificate. Run it in a cert-rotation pipeline before
bouncing xymond — **as the service user**, so file permissions match what the
daemon will see.

What `--check-tls` does *not* cover (so a `0` is necessary, not sufficient):

- **Listener binds** — port already in use, a privileged port without
  privileges, or a pure-IPv6 `--tls-listen` on a host without IPv6. At startup
  these disable the TLS port (plaintext stays up); the check binds nothing, so
  it can't see them.
- **TOCTOU** — the file can still change between the check and the restart;
  this is why atomic replacement matters.
- **Certificate *content* beyond validity dates** — SAN/hostname match and full
  chain construction are not verified (the client verifies those).
- **Revocation** — there is **no CRL/OCSP checking**. A revoked but unexpired
  client certificate is still accepted as a trusted sender until it expires;
  rotate the CA or reissue to revoke trust in practice.

A verified client certificate is treated as a trusted sender based on the
**verification result**, not on whether a Common Name can be extracted — a valid
CA-signed cert with only SANs and no CN is still trusted.


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


Distributing certificates
--------------------------
Xymon distributes **nothing** — it only reads PEM files from the paths/env you
give it (`--tls-cert`/`--tls-key`/`--tls-ca` on the server;
`XYMON_TLS_CA`/`XYMON_TLS_CERT`/`XYMON_TLS_KEY` on the client). `clientupdate`
ships client *binaries*, not certificates. Provisioning is your infrastructure's
job. The two pieces have very different rules:

- **The CA cert is public — distribute it freely.** It is not a secret; every
  node needs it. Ship `ca.pem` via config management, bake it into the client
  config, or fetch it during a plaintext bootstrap. Losing it costs nothing.
- **A private key must be born on its host and never transit the network.**
  Generate the key + CSR *on the client*, sign the CSR on the CA, copy only the
  signed cert back. Never mint the key centrally and push it out — and never
  send a key over the monitoring channel (that is the credential the channel
  relies on; keys-on-the-wire is the classic PKI mistake).

Patterns, smallest to largest:

1. **Manual** (a few hosts): the `openssl` recipe above — key+CSR on each host,
   sign on the CA, cert back.
2. **Config management** (Ansible/Puppet/Salt): push `ca.pem` as an ordinary
   file; generate each host's key+CSR locally and sign it (e.g. Ansible's
   `openssl_privatekey`/`openssl_csr`/`openssl_certificate`); set the
   `XYMON_TLS_*` env in the client's launch config.
3. **A PKI / enrollment service** (step-ca, Vault PKI, cert-manager, EST/SCEP/
   ACME): the client enrolls, gets a short-lived cert, and auto-renews; the key
   never leaves the host. Pair this with **atomic rotation** (write a temp file,
   then `rename()`), since xymond reads its TLS material once at startup.

**Bootstrap (before a host is enrolled):** the plaintext `--listen` port is
always available, so a not-yet-enrolled host reports in cleartext under your
`--acl` (e.g. `10.0.0.0/8 any status`), or over TLS with
`XYMON_TLS_VERIFY=none`/`peer` (encrypted, no client cert) — then you tighten as
certs land. See "Rolling out TLS across a fleet" above.

**CN governance is part of distribution.** `cert:<id>` matches the certificate
CN, so the rules you grant `admin`/`all` are only as strong as your CA's control
over *who can obtain a cert with that CN*. Use a **dedicated** client-cert CA and
issue admin CNs only to real admins; a shared or loosely-issuing CA undermines
`cert:<id>` (and the admin-breadth guard only catches `cert:*`/wide CIDRs, not a
CA that hands out `CN=ops-admin` to the wrong party).


Notes
-----
- **Wire framing over TLS:** TLS messages are length-prefixed (`size:N\n`), so a
  message is delimited by its declared size rather than connection close. The
  `xymon` client does this automatically; plaintext keeps the classic
  read-to-EOF framing.
- **Protocol floor:** the xymond server accepts TLS 1.2 or later (SSLv3/TLS
  1.0/1.1 refused; TLS 1.3 negotiated where available), while the `xymons://`
  client requires TLS 1.3 — liberal in what it accepts, conservative in what it
  sends. Client/server therefore always settle on TLS 1.3.
- **Build:** IPv6 is detected by a `configure` probe; TLS support follows the
  existing OpenSSL/`--enable-ssl` detection. Works with OpenSSL 1.1.1+/3.x and
  LibreSSL.


Testing
-------
`tests/ipv6-tls/smoke.sh` is a self-contained end-to-end test (generates its own
certs, starts xymond, exercises IPv4/IPv6 plaintext, TLS with verification,
encrypt-only, mTLS, and the cert-based ACL). It needs a usable `::1`
(`sudo ip addr add ::1/128 dev lo` on a host that lacks one):

    sh tests/ipv6-tls/smoke.sh        # prints "N passed, 0 failed"; exit 0 = all pass
