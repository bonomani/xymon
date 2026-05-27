Xymon over IPv6/TLS - deployment guide
=======================================

This is the practical setup guide. For the complete option and ACL reference,
see `ipv6-tls.md`.

For encrypted Xymon server-client communication, configure TLS first and add
client certificates later. Practically there are three security levels:

| Level | Encryption | Server authenticated | Client authenticated | Protects against |
|-------|------------|----------------------|----------------------|------------------|
| 1. TLS only | yes | no | no | passive sniffing |
| 2. TLS + server verification | yes | yes | no | sniffing + fake server/MITM |
| 3. Mutual TLS (mTLS) | yes | yes | yes | sniffing + MITM + unauthorized clients |

Minimum recommended deployment:

- Server: plaintext bound to `127.0.0.1` only, TLS exposed on port `1985`, and
  a server certificate installed.
- Client: `xymons://...`, `XYMON_TLS_VERIFY=full`, and `XYMON_TLS_CA`
  configured.

Client certificates are the next step, but they are not required for minimal
encryption.


Baseline TLS server
===================

Use this server layout for levels 1 and 2:

    xymond --listen=127.0.0.1:1984 \
           --tls-listen=0.0.0.0:1985,[::]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

Minimal ACL for levels 1 and 2:

    local       any  all
    0.0.0.0/0   tls  status,www
    ::/0        tls  status,www

This allows local administration on loopback and allows remote clients to report
and query only over TLS. It does not authenticate clients; any TLS client that
can reach the listener can use the granted `status,www` capabilities.

Important: `--listen=127.0.0.1:1984` keeps plaintext local only. Do not expose
these plaintext listeners unless plaintext monitoring traffic is acceptable:

    --listen=0.0.0.0:1984
    --listen=[::]:1984


Rules to know first
===================

1. The plaintext `--listen` port always exists.

   This branch does not have a "TLS only, no plaintext listener" mode. If you do
   not want plaintext exposed to clients, bind plaintext to loopback:

       --listen=127.0.0.1:1984

   or to a private management address:

       --listen=10.0.0.1:1984

   Put remote clients on the TLS listener. A single wildcard binds one family,
   so use a comma list to serve TLS on both IPv4 and IPv6:

       --tls-listen=0.0.0.0:1985,[::]:1985

   Specific IPv6 addresses must be bracketed, for example
   `[2001:db8::10]:1985`.

2. TLS is selected by the client recipient scheme.

   Plaintext:

       XYMSERVERS="monitor.example.com"
       XYMSERVERS="xymon://monitor.example.com:1984"

   TLS:

       XYMSERVERS="xymons://monitor.example.com:1985"

   A client using `xymons://` does not silently fall back to plaintext if TLS
   fails.

3. `--acl` decides who may do what.

   If xymond starts with no `--acl`, it allows everything, matching historical
   behavior. The shipped `tasks.cfg` uses `--acl=@XYMONHOME@/etc/xymonacl.cfg`,
   so installed systems normally use the shipped default ACL unless the operator
   removes that option.

   An ACL file is default-deny: if no rule matches, the request is denied.

   Rule format:

       SOURCE  TRANSPORT  CAPS  [force]

   Common examples:

       local         any   all
       10.0.0.0/8    any   status,www,maint
       cert:*        tls   status,www
       cert:ops      tls   all

   `SOURCE` is a CIDR, `local`, `cert:*`, or `cert:<CN>`.
   `TRANSPORT` is `any`, `plain`, or `tls`.
   `CAPS` is one or more of `status,www,maint,admin`, or `all`.

4. Keep admin narrow.

   Do not put `admin` or `all` on wide rules like `0.0.0.0/0`, `::/0`, or
   `cert:*`. xymond refuses broad admin rules unless they end in `force`.
   Prefer:

       local     any   all
       cert:ops  tls   all


IPv4, IPv6, and dual-stack bindings
====================================

Address-family choice is controlled by the address you put in `--listen` and
`--tls-listen`. The same rules apply to both options.

| Goal | Listener value | What xymond binds |
|------|----------------|-------------------|
| Dual-stack default | *omit `--listen`* | both `0.0.0.0:1984` and `[::]:1984` |
| Dual-stack, explicit | `0.0.0.0:1984,[::]:1984` | both `0.0.0.0:1984` and `[::]:1984` |
| All IPv4 interfaces | `0.0.0.0:1984` | IPv4 wildcard only |
| All IPv6 interfaces | `[::]:1984` | IPv6 wildcard only |
| IPv4 only, one address | `192.0.2.10:1984` | only that IPv4 address |
| IPv4 only, loopback | `127.0.0.1:1984` | only IPv4 loopback |
| IPv6 only, one address | `[2001:db8::10]:1984` | only that IPv6 address |
| IPv6 only, loopback | `[::1]:1984` | only IPv6 loopback |

Important: an explicit wildcard binds a single family — `0.0.0.0` is IPv4 only
and `[::]` is IPv6 only. Omitting `--listen` (the default) is dual-stack, and an
explicit dual-stack listener is the comma list `0.0.0.0:1984,[::]:1984`.

Examples:

    # Plaintext on IPv4 loopback only; TLS on public dual-stack.
    xymond --listen=127.0.0.1:1984 \
           --tls-listen=0.0.0.0:1985,[::]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem

    # Plaintext on a private IPv4 address; TLS on one public IPv6 address only.
    xymond --listen=10.0.0.1:1984 \
           --tls-listen=[2001:db8::10]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem

    # IPv6-only local deployment.
    xymond --listen=[::1]:1984

For single-family exposure across many interfaces, use the matching wildcard
(`0.0.0.0` for IPv4, `[::]` for IPv6); for one address, bind it directly.

ACLs are independent of the bind address. If both families are allowed, write
both IPv4 and IPv6 source rules:

    10.0.0.0/8        any   status,www,maint
    2001:db8:100::/48 any   status,www,maint


Level 1: encrypted, without verification
========================================

Use level 1 only as a bootstrap step or on a network where active MITM attacks
are not in scope. Traffic is encrypted, so passive sniffing is prevented, but an
attacker could impersonate the server.

Server: use the baseline TLS server shown above.

Client:

    XYMON_TLS_VERIFY=none
    XYMSERVERS="xymons://monitor.example.com:1985"

Risk:

- encrypted
- no server authentication
- a fake server/MITM can still receive client traffic


Level 2: encrypted, with server verification
============================================

This is the minimum recommended level for internet or other untrusted networks.
The client verifies the server certificate chain and the DNS/IP name it connects
to.

Server: use the baseline TLS server shown above, with a certificate whose SAN
matches the client recipient name.

Client:

    XYMON_TLS_CA=/etc/xymon/tls/server-ca.pem
    XYMON_TLS_VERIFY=full
    XYMSERVERS="xymons://monitor.example.com:1985"

Use a DNS name covered by the server certificate. If the client connects to an
IP address but the certificate names `monitor.example.com`, set:

    XYMON_TLS_SNI=monitor.example.com

Level 2 does not authenticate clients. The baseline ACL limits remote clients to
TLS transport and `status,www`, but any client that can connect to the TLS port
can use those capabilities.


Level 3: encrypted, with server verification and client certificates
====================================================================

Level 3 is proper mTLS. Use it when the server must reject unauthorized clients
instead of only encrypting the transport.

Server:

    xymond --listen=127.0.0.1:1984 \
           --tls-listen=0.0.0.0:1985,[::]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key \
           --tls-ca=/etc/xymon/tls/client-ca.pem \
           --tls-require-clientcert \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

ACL:

    local       any  all
    cert:*      tls  status,www

This lets any client with a certificate signed by your private client CA report
status and use normal query functions. It does not grant remote admin.

To grant admin to one named certificate:

    local       any  all
    cert:ops    tls  all
    cert:*      tls  status,www

Put the named rule before `cert:*`, because ACL matching is first-match-wins.

Client:

    XYMON_TLS_CA=/etc/xymon/tls/server-ca.pem
    XYMON_TLS_CERT=/etc/xymon/tls/client.pem
    XYMON_TLS_KEY=/etc/xymon/tls/client.key
    XYMON_TLS_VERIFY=full
    XYMSERVERS="xymons://monitor.example.com:1985"

There is no CRL/OCSP checking. Use short-lived client certificates and automate
renewal if clients are internet-facing.


Hybrid LAN plus remote clients
==============================

If local clients may report over a private network but remote clients must use
TLS, bind plaintext to the private address instead of the public wildcard and
make the ACL transport-aware:

    xymond --listen=10.0.0.1:1984 \
           --tls-listen=0.0.0.0:1985,[::]:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key \
           --tls-ca=/etc/xymon/tls/client-ca.pem \
           --tls-require-clientcert \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

ACL:

    local         any  all
    10.0.0.0/8    any  status,www,maint
    cert:*        tls  status,www

LAN client:

    XYMSERVERS="10.0.0.1"

Remote client:

    XYMON_TLS_CA=/etc/xymon/tls/server-ca.pem
    XYMON_TLS_CERT=/etc/xymon/tls/client.pem
    XYMON_TLS_KEY=/etc/xymon/tls/client.key
    XYMON_TLS_VERIFY=full
    XYMSERVERS="xymons://monitor.example.com:1985"


Rolling out gradually
=====================

You can move a fleet in stages. Each client chooses plaintext or TLS by its
`XYMSERVERS` entry, so old and new clients can coexist.

| Step | Security level | Server config | Client config |
|------|----------------|---------------|---------------|
| 0 | Plaintext only | `--listen` only | `xymon://server:1984` |
| 1 | Level 1: TLS only | baseline TLS server | `xymons://server:1985`, `XYMON_TLS_VERIFY=none` |
| 2 | Level 2: TLS + server verification | same server, valid server cert | add `XYMON_TLS_CA`, use `XYMON_TLS_VERIFY=full` |
| 3 | Level 3: mTLS | add `--tls-ca`, `--tls-require-clientcert`, and `cert:*` ACL rules | add `XYMON_TLS_CERT` and `XYMON_TLS_KEY` |

After level 3, tighten the ACL as needed: grant `admin` only to named client
certificates or narrow management source ranges, not to `cert:*`.

Recommended order:

1. Add the TLS listener while leaving existing plaintext clients alone.
2. Move clients to `xymons://` with temporary `XYMON_TLS_VERIFY=none`.
3. Deploy the server CA to clients and switch them to `XYMON_TLS_VERIFY=full`.
4. Issue client certificates, add `--tls-ca`, and test `cert:*` ACL rules.
5. After every remote client has a cert, enable `--tls-require-clientcert`.
6. Tighten the ACL so remote clients match only `tls` or `cert:*` rules.


Certificate authorities
=======================

There are two different trust directions. Keep them conceptually separate:

| CA | Signs | Trusted by | Can be public? |
|----|-------|------------|----------------|
| Server CA | the xymond server certificate | Xymon clients via `XYMON_TLS_CA` | yes, public ACME is fine |
| Client CA | client certificates for mTLS | xymond via `--tls-ca` | no, use a private dedicated CA |

The client CA must not be a public CA. If the server trusts a public CA for
client certificates, then `cert:*` can mean "any public certificate from the
internet", which is not useful as Xymon client identity.

The CA certificate is public. The CA private key is secret and should not live
on monitored hosts.


Server certificates
===================

The server certificate must match how clients connect:

| Client connects to | Server cert needs |
|--------------------|-------------------|
| `xymons://monitor.example.com:1985` | `DNS:monitor.example.com` in SAN |
| `xymons://[2001:db8::10]:1985` | `IP:2001:db8::10` in SAN |
| `xymons://192.0.2.10:1985` | `IP:192.0.2.10` in SAN |

For normal internet-facing deployments, use a public ACME certificate for the
server and make clients connect by DNS name.

If clients must connect to an IP address but the certificate names a DNS host,
set `XYMON_TLS_SNI` on the client to the certificate name.


Client certificates
===================

A client certificate identifies a Xymon sender. `cert:*` matches any verified
client certificate, even a certificate without a Common Name. `cert:<CN>` rules
match the certificate Common Name, so use a CN when you want per-host or
per-role ACL rules.

Best practice:

1. Generate the private key on the client.
2. Generate a CSR on the client.
3. Send only the CSR to the client CA.
4. Copy the signed certificate and CA certificate back to the client.
5. Configure `XYMON_TLS_CERT`, `XYMON_TLS_KEY`, and `XYMON_TLS_CA`.

Example key and CSR generated on the client:

    openssl req -newkey rsa:2048 -nodes \
      -keyout client.key \
      -out client.csr \
      -subj "/CN=host-01"

Do not generate one shared client certificate for the whole fleet. Use one
certificate per client, or at least one per trust group, so a compromised client
can be replaced without changing every host.


Renewal and restart
===================

xymond reads TLS files once at startup. It does not hot-reload certificates or
CA files.

When renewing:

1. Write new files to temporary paths.
2. Validate them:

       xymond --check-tls \
              --tls-cert=/etc/xymon/tls/server.pem \
              --tls-key=/etc/xymon/tls/server.key \
              --tls-ca=/etc/xymon/tls/client-ca.pem

3. Rename the new files into place atomically.
4. Restart xymond.

Run `--check-tls` as the same user that starts xymond, so file permissions are
tested correctly. Exit code `0` means the TLS material is usable; non-zero means
TLS would be disabled at startup.

`--check-tls` does not test whether the listen port can bind. Port conflicts and
firewall policy are still deployment checks.


Minimal test certificate recipe
===============================

This is enough for a lab or smoke test. Use a real PKI or ACME for production.

Create a CA:

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout ca.key -out ca.pem -subj "/CN=Xymon Test CA"

Create a server certificate with DNS and IPv6 SANs:

    openssl req -newkey rsa:2048 -nodes \
      -keyout server.key -out server.csr \
      -subj "/CN=monitor.example.com"
    printf 'subjectAltName=DNS:monitor.example.com,IP:2001:db8::10\n' > server.ext
    openssl x509 -req -in server.csr \
      -CA ca.pem -CAkey ca.key -CAcreateserial \
      -out server.pem -days 365 -extfile server.ext

Create a client certificate:

    openssl req -newkey rsa:2048 -nodes \
      -keyout client.key -out client.csr \
      -subj "/CN=host-01"
    openssl x509 -req -in client.csr \
      -CA ca.pem -CAkey ca.key -CAcreateserial \
      -out client.pem -days 365

For production, prefer separate server and client CAs. The single-CA example is
only to keep the test recipe short.
