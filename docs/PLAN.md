# Xymon native TLS — remaining work to "production"

Scope: native TLS/mTLS for the Xymon wire protocol, **legacy `make`/`configure`
build**, permissive trust model (private networks; CA optional). Items are
removed as they land; refused items keep a one-line reason.

Status legend: the prototype currently handshakes, verifies certs (CA / pinning
/ none), frames requests, survives multi-record messages, returns correct exit
codes, bounds the handshake against stalls, and builds cleanly from a from-
scratch `./configure --server` + full `make` on Linux/OpenSSL 3.x (verified).
Test suite: `tests/tls/{test-handshake,test-largemsg,test-modes,test-concurrency}.sh`.

## P0 — still blocking production

- [ ] **LibreSSL / OpenSSL 1.1.1 build + runtime verification.** The macro use
      is now `#ifdef`-guarded, but it has only been *compiled* against OpenSSL
      3.x. Needs an actual build + test run on LibreSSL (BSD CI lanes) and on
      1.1.1 to confirm both the build and the SSL_ERROR_SYSCALL/errno-0 EOF
      path behave there. (Linux/OpenSSL-3.x CI now runs the suite; the build
      compiles the TLS code since configure emits `-DHAVE_XYMON_TLS`.)

## P1 — needed for a real deployment

- [ ] **Relay + remaining client tools over TLS.** `xymonproxy` (relay),
      `clientupdate`, `logfetch`, `msgcache` build with TLS but have not been
      exercised end-to-end over `xymons://`. `xymonproxy` upstream-over-TLS in
      particular needs a runtime test.
- [ ] **Soak / leak testing.** Short bounded runs and a 20-way concurrency
      burst pass; still need a longer soak and a valgrind/ASan pass over the
      per-connection paths (esp. error/abort paths and cross-direction SSL
      wants).
- [ ] **Cert/key reload on SIGHUP** — currently the SSL_CTX is built once at
      startup; rotation needs a restart.
- [ ] **IPv6 listener** — the TLS listener is IPv4-only (`sockaddr_in`).
- [ ] **Config-file integration** — fold `--tls-*` / `XYMON_TLS_*` into
      `xymonserver.cfg` / `xymonclient.cfg`; decide the port story (current
      hardcoded 1984/1985 split vs. an upgrade on 1984).

## P2 — polish

- [ ] Rate-limited, structured handshake-failure logging (peer, cipher,
      version, reason); expose counters as a xymond status.
- [ ] `make install` wiring: TLS defaults + cert-path conventions in the
      installed `*.cfg` templates.
- [ ] Admin docs: real-CA / pinning / encrypt-only setup + rotation guide.

## Deferred by design (permissive model)

- Per-client authorization (cert identity → permitted hosts). Skipped: single
  trust domain, mTLS-as-trust-boundary is sufficient. Revisit for multi-tenant.
- Revocation (CRL/OCSP). Skipped: rotate the (private) CA on a small network.
- Full non-blocking handshake state machine. Replaced by a handshake timeout;
  the single loop still serializes handshakes (acceptable for private/LAN
  scale). Revisit if a large/busy server is targeted.
