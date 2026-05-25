Xymon Native TLS — Prototype Design
====================================

Status: **DRAFT — for review**
Branch: `feat/tls-prototype`
Scope: First-cut prototype that proves end-to-end TLS + mTLS between a Xymon
client and `xymond`. Hardening, `xymonproxy`, and STARTTLS migration are
explicit follow-ups.


1. Goals
--------

- Encrypt the Xymon wire protocol between client and server.
- Authenticate the client to the server (close the "anyone on the network can
  submit status updates" gap that exists today).
- Authenticate the server to the client (prevent spoofing / MITM).
- Stay non-invasive to the existing plaintext path while the prototype is in
  flight: plaintext on 1984 keeps working unchanged.
- Reuse the OpenSSL detection that the build already does for `xymonnet`'s
  HTTPS probing.


2. Non-goals (for this PR)
--------------------------

- `xymonproxy` TLS support (tracked as a separate task).
- STARTTLS negotiation on port 1984 (production migration path, tracked as v2).
- Certificate revocation: CRL / OCSP / OCSP-stapling.
- Automated cert rotation / ACME integration.
- TLS 1.2 fallback nuances — prototype targets TLS 1.3 only.
- Config-file syntax (`xymonserver.cfg [tls]`) — env-var driven for now.


3. Threat model
---------------

Today, Xymon's `1984/tcp` protocol is plaintext and unauthenticated. An
attacker who can reach the port can:

  (a) Read every status update flowing in (host names, IPs, service state,
      sometimes credentials embedded in test output).
  (b) Inject forged status updates ("everything is green") to suppress alerts.
  (c) Disable monitoring by spamming `drop`/`rename` commands.

This design addresses (a), (b), and (c) on the encrypted listener. Plaintext
listeners remain vulnerable until operators flip the cutover (v2 / STARTTLS).

Out of threat-model scope: compromise of the server host itself, key
exfiltration from disk, side-channel attacks on OpenSSL.


4. Port strategy
----------------

**Prototype:** new listener on `1985/tcp`, TLS from byte zero. Plaintext
`1984/tcp` continues to work unchanged.

Rationale:
- Zero protocol-state machine to debug while also debugging TLS context setup.
- Trivially testable with `openssl s_client -connect host:1985`.
- Operators can run both ports in parallel during migration.

**v2 path:** add STARTTLS on `1984/tcp` so existing deployments can upgrade
in place. The prototype's `SSL_CTX` + cert/key plumbing is reused; only the
handshake trigger changes.


5. Authentication model
-----------------------

**mTLS (mutual TLS).**

- Server presents a cert; client verifies against `XYMON_TLS_CA`.
- When `--tls-ca` is set, the server **requires** a valid client cert
  (`SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`), verified against it;
  when omitted, no client cert is required (encrypt-only — see Trust modes).
- Client identity (CN or SAN) is logged and made available to xymond's
  message handler for future ACLs. The prototype does not enforce per-client
  authorization yet — any cert the trust file validates is accepted.


6. Configuration surface
------------------------

### Client (sendmsg.c consumers — `xymon`, `xymonclient`, etc.)

Triggered by the `XYMSRV` URL scheme:

  - `XYMSRV=hostname`                  → plaintext, port 1984 (unchanged)
  - `XYMSRV=xymon://host:1984`         → plaintext, explicit
  - `XYMSRV=xymons://host:1985`        → **TLS**

When the scheme is `xymons://`, these env vars are consulted:

  | Variable            | Purpose                                       | Required |
  |---------------------|-----------------------------------------------|----------|
  | `XYMON_TLS_VERIFY`  | `full` (default) / `peer` / `none` (see below)| no       |
  | `XYMON_TLS_CA`      | PEM trust file for the server cert            | unless `none` |
  | `XYMON_TLS_CERT`    | PEM client cert (for mTLS)                    | if server requires it |
  | `XYMON_TLS_KEY`     | PEM client private key                        | with `CERT` |
  | `XYMON_TLS_SNI`     | Override SNI / verification name (default=host)| no       |

### Server (`xymond`)

New CLI flags (parsed in the existing option loop in `xymond.c`):

  --tls-listen=[ADDR:]PORT     # default disabled; prototype example: 1985
  --tls-cert=FILE              # server cert chain (PEM)  -- required
  --tls-key=FILE               # server private key (PEM) -- required
  --tls-ca=FILE                # trust file for client certs (PEM) -- optional

`--tls-cert` and `--tls-key` are required when `--tls-listen` is set. `--tls-ca`
is optional: with it, client certs are required and verified (mTLS); without it,
the listener encrypts but does not authenticate clients.

### Trust modes (CA-free options)

The trust anchor never has to be a public/commercial CA. Three modes, from
strongest to most permissive:

  1. **CA (or private CA)** — `XYMON_TLS_VERIFY=full` (default). Server and
     client certs are signed by a CA; the cert's hostname/IP is checked.
     Helper: `tests/tls/gen-certs.sh`.
  2. **Self-signed pinning** — `XYMON_TLS_VERIFY=peer`. No CA at all: each side
     trusts the *other side's own self-signed cert* directly (`XYMON_TLS_CA` /
     `--tls-ca` point at the peer cert). The chain is verified but the name is
     not (the exact cert is already pinned). Full mutual authentication, zero
     CA to operate. Helper: `tests/tls/gen-selfsigned.sh`.
  3. **Encrypt-only** — `XYMON_TLS_VERIFY=none` on the client and omit
     `--tls-ca` on the server. No certs to manage beyond the server's own;
     stops passive eavesdropping but **not** an active MITM. For trusted
     private networks only. Both sides log a warning when verification is off.


7. Build wiring
---------------

- New compile-time symbol: **`HAVE_XYMON_TLS`** (distinct from the existing
  `HAVE_OPENSSL`, which gates the HTTPS-probing code in `xymonnet`).
- CMake (active branch `cmake/bootstrap`):
  - Add `option(XYMON_ENABLE_TLS "Build with native TLS support" ON)`.
  - When ON, `find_package(OpenSSL 1.1.1 REQUIRED)`; define `HAVE_XYMON_TLS`;
    link `OpenSSL::SSL` and `OpenSSL::Crypto` into `libxymon`, `xymond`,
    and `xymonclient`.
- Legacy `configure.server` / `configure.client`:
  - Add `--enable-xymon-tls` / `--disable-xymon-tls`.
  - When enabled (default ON if OpenSSL is detected), append `HAVE_XYMON_TLS`
    to the generated `Makefile.local` defines.
- Both paths must keep working — the CMake migration's reference-mode parity
  validation will compare outputs.


8. Code layout
--------------

New files (kept small to ease review):

  lib/xymon_tls.h     — public API
  lib/xymon_tls.c     — SSL_CTX init, connect helper, accept helper,
                        thin BIO wrappers around the existing fd-based read/
                        write so callers change minimally

Existing-file edits (all guarded by `#ifdef HAVE_XYMON_TLS`):

  lib/sendmsg.c
    - Parse `xymons://` scheme alongside the existing host parsing (~L260).
    - After successful `connect()` (~L305), call
      `xymon_tls_client_handshake(sockfd, host, &ssl)`.
    - Replace the `write()`/`recv()` calls (L416, L362) with helpers that
      dispatch to `SSL_write`/`SSL_read` when `ssl != NULL`.
    - On exit / error, `xymon_tls_free(ssl)` then `close(sockfd)` as today.

  xymond/xymond.c
    - Add CLI flag parsing for `--tls-listen` / `--tls-cert` / `--tls-key`
      / `--tls-ca`.
    - At startup, after the existing `lsocket` setup (~L5526), create a
      second `lsocket_tls` bound to `--tls-listen` and a long-lived
      `SSL_CTX *server_ctx` from `xymon_tls_server_ctx_new(...)`.
    - In the accept loop (~L6004), poll both fds; when the TLS fd fires,
      call `xymon_tls_server_handshake(sock, server_ctx, &ssl)` and attach
      `ssl` to the connection record so downstream read/write paths use it.
    - Log peer CN/SAN on successful handshake.

  xymond connection record:
    - Add `SSL *ssl;` field. NULL → plaintext path (unchanged).


9. Test plan
------------

  tests/tls/
    gen-certs.sh        # openssl wrapper: builds CA, server cert (SAN=localhost),
                        # one client cert. Outputs under tests/tls/out/.
    run-prototype.sh    # boots xymond on 127.0.0.1:1985 with test certs in
                        # the background, sends one status message via
                        # `xymon` client with XYMON_TLS_* env, asserts the
                        # message appears in xymond's log.
    README.md           # how to run it locally + in CI.

CI: add a small job that runs `tests/tls/run-prototype.sh` after the existing
build. Skip on platforms where the build's OpenSSL detection is disabled.


10. Rollout strategy (post-prototype)
-------------------------------------

  Phase 1 (this PR)   Prototype on 1985, opt-in, mTLS, no proxy.
  Phase 2             Add STARTTLS on 1984. Server config: `tls-mode = off |
                      optional | required`. Operators move clients one by one,
                      then flip to `required`.
  Phase 3             `xymonproxy` TLS termination + re-encryption.
  Phase 4             Cert ACLs (per-CN authorization for sensitive commands
                      like `drop`/`rename`).
  Phase 5             Automation: cert-rotation hooks, optional ACME.


11. Open questions
------------------

- Does the active CMake migration's reference-mode validation diff against
  build outputs that would notice `HAVE_XYMON_TLS` in generated headers?
  → Verify before landing the build wiring; may need to gate the define
    behind a CMake option that defaults OFF during parity runs.
- Minimum OpenSSL version: 1.1.1 is the floor (TLS 1.3 support). Confirm
  this is acceptable on the targeted BSD/macOS CI runners.
- Should `XYMON_TLS_*` env vars be readable from `xymonclient.cfg` too, for
  parity with how clients already source other settings? Recommend yes in v2;
  out of scope for prototype.
