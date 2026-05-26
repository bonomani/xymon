Xymon over IPv6/TLS - deployment guide
=======================================

This is the practical setup guide. For the complete option and ACL reference, see
`ipv6-tls.md`.

Start by choosing one deployment profile:

| Profile | Use when | Plaintext listener | TLS listener | Client identity | Typical ACL |
|---------|----------|--------------------|--------------|-----------------|-------------|
| A. Intranet | all clients are on a trusted LAN or management network | LAN or management IP | optional | source IP | LAN can report/query |
| B. Internet | clients reach xymond over an untrusted network | loopback only | public or DMZ IP | verified client cert | `cert:* tls status,www` |
| C. Hybrid | some clients are on the LAN, some are remote | LAN or management IP | public or DMZ IP | LAN IPs and remote certs | LAN rule plus `cert:* tls` rule |

The safest default for a public deployment is Profile B. Profile A is only for
networks where plaintext monitoring traffic is acceptable.


Rules to know first
===================

1. The plaintext `--listen` port always exists.

   This branch does not have a "TLS only, no plaintext listener" mode. If you do
   not want plaintext exposed to clients, bind plaintext to loopback:

       --listen=127.0.0.1:1984

   or to a private management address:

       --listen=10.0.0.1:1984

   Put remote clients on the TLS listener:

       --tls-listen=0.0.0.0:1985

   Use `[::]:1985` instead of `0.0.0.0:1985` when you want the TLS listener on
   IPv6. Specific IPv6 addresses must be bracketed, for example
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


Profile A: intranet only
========================

Use this when all Xymon clients are on a trusted LAN or management network.
Plaintext may be acceptable here.

Server:

    xymond --listen=10.0.0.1:1984 \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

ACL:

    local        any   all
    10.0.0.0/8   any   status,www,maint

Client:

    XYMSERVERS="10.0.0.1"

Optional TLS on the same intranet:

    xymond --listen=10.0.0.1:1984 \
           --tls-listen=10.0.0.1:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

Client during bootstrap, encrypted but not verified:

    XYMON_TLS_VERIFY=none
    XYMSERVERS="xymons://10.0.0.1:1985"

Client after the server CA is installed:

    XYMON_TLS_CA=/etc/xymon/tls/server-ca.pem
    XYMON_TLS_VERIFY=full
    XYMSERVERS="xymons://monitor.example.com:1985"


Profile B: internet-facing server
=================================

Use this when any client reaches xymond across the internet or another
untrusted network. Bind plaintext to loopback, expose only the TLS listener, and
require client certificates.

Server:

    xymond --listen=127.0.0.1:1984 \
           --tls-listen=0.0.0.0:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key \
           --tls-ca=/etc/xymon/tls/client-ca.pem \
           --tls-require-clientcert \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

ACL:

    local    any   all
    cert:*   tls   status,www

This lets any client with a certificate signed by your private client CA report
status and use normal query/maintenance functions. It does not grant remote
admin.

To grant admin to one named certificate:

    local       any   all
    cert:ops    tls   all
    cert:*      tls   status,www

Put the named rule before `cert:*`, because ACL matching is first-match-wins.

Client:

    XYMON_TLS_CA=/etc/xymon/tls/server-ca.pem
    XYMON_TLS_CERT=/etc/xymon/tls/client.pem
    XYMON_TLS_KEY=/etc/xymon/tls/client.key
    XYMON_TLS_VERIFY=full
    XYMSERVERS="xymons://monitor.example.com:1985"

Use a DNS name covered by the server certificate. If the client connects to an
IP address but the cert names `monitor.example.com`, set:

    XYMON_TLS_SNI=monitor.example.com

There is no CRL/OCSP checking. Use short-lived client certificates and automate
renewal if clients are internet-facing.


Profile C: hybrid LAN plus remote clients
=========================================

Use this when local clients can report over a private network, but remote
clients must use TLS and client certificates.

Server:

    xymond --listen=10.0.0.1:1984 \
           --tls-listen=0.0.0.0:1985 \
           --tls-cert=/etc/xymon/tls/server.pem \
           --tls-key=/etc/xymon/tls/server.key \
           --tls-ca=/etc/xymon/tls/client-ca.pem \
           --tls-require-clientcert \
           --acl=/etc/xymon/acl.cfg \
           --hosts=/etc/xymon/hosts.cfg

ACL:

    local         any   all
    10.0.0.0/8    any   status,www,maint
    cert:*        tls   status,www

LAN client:

    XYMSERVERS="10.0.0.1"

Remote client:

    XYMON_TLS_CA=/etc/xymon/tls/server-ca.pem
    XYMON_TLS_CERT=/etc/xymon/tls/client.pem
    XYMON_TLS_KEY=/etc/xymon/tls/client.key
    XYMSERVERS="xymons://monitor.example.com:1985"


Rolling out gradually
=====================

You can move a fleet in stages. Each client chooses plaintext or TLS by its
`XYMSERVERS` entry, so old and new clients can coexist.

| Stage | Server config | Client config | Security |
|-------|---------------|---------------|----------|
| 0. Plaintext | `--listen` only | `xymon://server:1984` | no wire protection |
| 1. Encrypt only | add `--tls-listen`, cert/key | `xymons://server:1985`, `XYMON_TLS_VERIFY=none` | prevents passive sniffing, not MITM |
| 2. Verify server | same as stage 1 | add `XYMON_TLS_CA`, use `XYMON_TLS_VERIFY=full` | detects fake servers |
| 3. Optional client certs | add `--tls-ca`, ACL can use `cert:*` | add `XYMON_TLS_CERT` and `XYMON_TLS_KEY` | cert clients can be authorized |
| 4. Required client certs | add `--tls-require-clientcert` | all TLS clients need cert/key | rejects clients without valid certs |
| 5. Least privilege | tighten ACL | same | reporters cannot become admins |

Recommended order:

1. Add the TLS listener while leaving existing plaintext clients alone.
2. Move clients to `xymons://` with temporary `XYMON_TLS_VERIFY=none`.
3. Deploy the server CA to clients and switch them to `XYMON_TLS_VERIFY=full`.
4. Issue client certificates and add `--tls-ca`.
5. After every remote client has a cert, enable `--tls-require-clientcert`.
6. Tighten the ACL so remote clients match only `tls` rules.


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
