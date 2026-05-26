# Xymon IPv6 + TLS (A′) — plan

**Branch:** `feat/ipv6-tls`, off `main` (42f24171).
**Approach:** **A′** — adopt devel's `tcplib` async connection engine, but graft
our **modernized TLS** onto it instead of shipping its 2015 crypto.
**Status:** PLAN ONLY. No code yet.

---

## Decision record

Chosen: **A′** — the most powerful path. tcplib gives an async, event-driven,
IPv4/IPv6-unified connection layer (server listen + client connect + xymonnet),
and A′ keeps that engine while replacing its crypto with the portable, verifying
TLS the prototype already proved.

Rejected:
- **plain A** (tcplib as-is) — P0 shows it *builds* clean on OpenSSL 3, but its
  TLS is weak: no SAN/IP identity check (CN-string only), the client never
  verifies the server cert, no protocol floor. A′ keeps tcplib's engine and
  hardens exactly those, so it strictly dominates plain A.
- **B** (hand-roll IPv6 on the existing select loop) — reinvents tcplib's
  abstraction, keeps the blocking model, no async/TLS upside.
- **C** (transport-only) — smallest, but leaves the connection model and service
  checks where they are; not "most powerful".

---

## What A′ is, concretely

`tcplib` (async engine, from devel) + the prototype's TLS hardening
(`lib/xymon_tls.c` logic) wired into tcplib's existing `SSL_CTX`/`SSL` slots. We
keep tcplib's structure (STARTTLS states, server mTLS, SNI, close_notify, the
callback event loop) and add only the *identity/strength* checks it lacks:

P0 confirmed tcplib already has STARTTLS, server mTLS (verify client vs CA),
SNI, close_notify (`SSL_shutdown`), and — on OpenSSL 3 — TLS 1.3
(`SSLv23_method` ⇒ `TLS_method`). P2 is the additive graft of what's missing:

| Missing in tcplib | P2 adds (from prototype `lib/xymon_tls.c`) |
|---|---|
| identity check is CN-string only (no SAN, no IP) | `X509_VERIFY_PARAM_set1_host` / `set1_ip_asc` |
| client never verifies the server cert | client `SSL_CTX_set_verify` + full/peer/none modes |
| no protocol floor (only SSLv2 off; TLS1.0/1.1 allowed) | `SSL_CTX_set_min_proto_version(TLS1_2)` |
| single trust posture | pinning / encrypt-only selectable |

---

## Phases

**P0 — Feasibility spike. ✅ DONE.** Built `lib/tcplib.c` syntax-only against
OpenSSL 3.0.2 (`-DHAVE_OPENSSL`, stubbed `config.h`): **0 errors, 0 warnings**.
The "2015 APIs" are compat macros (`SSLv23_*_method` ⇒ `TLS_*_method`;
`SSL_library_init`/`OpenSSL_add_all_algorithms` ⇒ no-ops), so **no OpenSSL-3
build work is needed** (tcplib doesn't include `sslerr.h`, so the prototype's
LibreSSL guard is moot; LibreSSL still to confirm in CI). Result reframes P2 from
*portability* to the *identity/strength* graft above. A′ confirmed viable and
cheaper than estimated.

**P1 — tcplib + IPv6 transport, plaintext only (`CONN_SSL_NO`).**

- **Step 1 ✅ DONE** — `lib/tcplib.{c,h}` compiled into `libxymoncomm.a`
  (`XYMONCOMMLIBOBJS` + explicit `tcplib.o` rule w/ `$(SSLFLAGS)`); builds clean
  on OpenSSL 3.0.2, full server build still links. `tcplib.c` is the *only*
  cleanly-separable file.
- **Step 2 — FINDING: devel's `xymond.c`/`sendmsg.c` are NOT IPv6-only.** Beyond
  `conn_*` (tcplib, have it), devel's `xymond.c` calls `uncompress_message` /
  `compress` / `compressiontype` (devel **compression**) and the reworked
  sendmsg API (`sendmessage_safe/_buffer/_local`, `combo_addchar`,
  `backfeedqueuenumber`, `setup_feedback_queue`). They can't be lifted without
  pulling most of the 4.3 server. **Consequence:** step 2 = *hand-wire* tcplib
  into main's `xymond.c` (write `conn_init_server` + the read/write callback
  ourselves, no compression/backfeed) — genuine dev, ~the listener rewrite, not
  a file copy. Same for `sendmsg.c` client connect.

- **Step 2 — FINDING 2: the sender ACL is IPv4-only.** `do_message` authorizes
  senders via `oksender(..., struct in_addr sender, ...)` — **~25 call sites**,
  all assuming a 32-bit IPv4 address (`ipaccess.c`). A v6 sender can't be passed
  to it. This is the *real* reason devel fused v6 with TLS: its commit says
  *"TLS client-certificate validation replaces IP-based access controls"* —
  **v6 invalidates IP-based auth, so cert auth (TLS) becomes necessary.**
  Consequence: a *plaintext* v6 server can carry traffic but **cannot authorize
  v6 senders** with the current ACL. Coherent v6 needs one of:
  (a) generalize `ipaccess`/`oksender` to v6 (`sockaddr_storage`; ~25 sites +
  `ipaccess.c`); (b) cert-based auth for v6 senders (= bring P2/TLS forward —
  v6 and TLS done together); (c) stopgap for the proof (map v4-in-v6, bypass ACL
  on loopback) and defer real v6 auth.

Goal unchanged: v6 client→xymond report end-to-end; **IPv4 must stay unbroken**.
Open: the v6-sender-ACL decision (a/b/c) gates how P1 finishes.

- **Step 2 ✅ DONE & PROVEN (server listener).** Hand-wired tcplib into xymond:
  `conn_init_server` on `[::]:port`, loop now `conn_fdset`/`conn_process_*`/
  `conn_trimactive`, new `xymond_conn_cb()` accumulates to EOF → `do_message` →
  response, with the stopgap `conn_peer_in_addr()` for the IPv4 ACL. **Runtime
  proof:** xymond listens on tcp6 `*:PORT`; a `ping` over the `[::]` socket
  (v4-mapped `127.0.0.1`, i.e. an `AF_INET6` peer) returns `xymond 4.3.30`
  end-to-end; IPv4 preserved. Pure non-mapped v6 peer **not testable on the dev
  box** (no `::1`, dummy0 link-local won't loop back TCP) → verify on CI/BSD.
  - Build-hygiene notes (follow-up): `IPV4_SUPPORT`/`IPV6_SUPPORT` are hardcoded
    on the `tcplib.o` rule — should come from a `build/test-ipv6` probe like
    devel's. And changing only the Makefile recipe doesn't rebuild `tcplib.o`
    (needs `rm lib/tcplib.o` / clean build) — fine from clean.

**P2 — Graft TLS hardening (the A′ core).** *Additive*, per P0 — keep tcplib's
crypto, add what it lacks (reuse `lib/xymon_tls.c`): client-side
`SSL_CTX_set_verify` + full/peer/none modes, `X509_VERIFY_PARAM_set1_host`/
`set1_ip_asc` SAN identity check (replacing the CN-string match),
`SSL_CTX_set_min_proto_version(TLS1_2)`, selectable trust modes. Keep tcplib's
STARTTLS, server mTLS, SNI, close_notify. Goal: client verifies server, server
verifies client by SAN, no sub-TLS-1.2.

**P3 — Alpha gaps (scope-dependent, see Q1).** HTTP/TCP service checks over v6
(`xymonnet.c`, `httptest.c`, `httpresult.c`, `contest.c`), URL `[literal]`
parsing, and **true dual-stack listen** (two sockets) instead of devel's single
v6+IPv4-mapped socket. devel left all of these unfinished — this is net-new work.

**P4 — Tests + CI.** Extend the existing OpenBSD/LibreSSL BSD CI; smoke tests for
v4 + v6 + TLS; reuse `tests/tls/` scripts.

---

## Risks

- **10-year-old alpha** — P1 source applies (identical base), but build-system
  hooks must be lifted out of unrelated 4.3 trunk work by hand.
- **xymond.c event-loop rewrite is large** — regression risk to the core daemon;
  P1 must prove IPv4 parity before P2.
- **P3 is genuinely unsolved upstream** — budget it as new development, not a port.
- TLS graft (P2) is de-risked by reusing the already-CI-proven prototype.

---

## Open questions (carry until decided)

1. **Scope** — stop after P2 (transport + TLS over v6), or do P3 (full v6 service
   checks)?
2. **Dual-stack** — true two-socket listen (P3), or accept devel's single
   v6+mapped socket for now?
3. **Prototype reconciliation** — `feat/tls-prototype` becomes the *source* of the
   P2 TLS, then retires; confirm nothing else depends on it.

- **Step 3 (client) ✅ DONE & PROVEN.** `sendmsg.c` connect rewritten to
  `getaddrinfo(AF_UNSPEC)` + non-blocking connect loop (select/IO loop
  unchanged). Recipient may be a v4/v6 literal or a hostname. **Proof (real
  `xymon` client):** `ping` → `xymond 4.3.30` over `127.0.0.1` and `localhost`;
  a `status` report lands on the board, no ACL rejection. Pure non-mapped v6
  client path → CI.

**P1 is COMPLETE and fully proven.** After adding `::1` to the dev box loopback
(`ip addr add ::1/128 dev lo`): `xymon [::1]:PORT ping` → `xymond 4.3.30` and a
`status` lands on the board (`localhost|v6native|green`) — a genuine
**non-mapped** IPv6 connection (`::1` can't be v4-mapped). IPv4 ping still works.
Client + server speak IPv6 end-to-end; pure v6 and v4 both verified.

A CI lane (`.github/workflows/ipv6-e2e`) is committed to run the same e2e on a
runner's real `::1` for ongoing regression. NOTE: GitHub stopped creating Actions
runs for the repo on 2026-05-26 ~10:23Z (repo-wide — `build.yml` too; public
repo so not a quota cap; can't `workflow_dispatch` as the default branch
`cmake/bootstrap` lacks the file). The lane will run when triggering resumes.

## P2 — TLS (IN PROGRESS)

- ✅ **Hardening** — `SSL_CTX_set_min_proto_version(TLS1_2)` on tcplib's server +
  client contexts (no SSLv3/TLS1.0/1.1).
- ✅ **Listener wiring (opt-in)** — xymond `--tls-listen` / `--tls-cert` /
  `--tls-key` / `--tls-ca` / `--tls-require-clientcert` → `conn_init_server`
  (implicit TLS + optional client-cert mTLS). Plaintext path unchanged when no
  `--tls-cert` (P1 unaffected).
- ✅ **Handshake proven** — `openssl s_client [::1]:tlsport` gets the server cert
  (CN=localhost), negotiates, min-proto enforced.
- ❌ **BUG 1 — request/response framing over TLS.** xymon delimits a message by
  the client half-closing (`SHUT_WR`); over plaintext the server reads EOF yet
  still writes the reply. tcplib's `try_ssl_io` treats `SSL_read()==0` (peer
  close_notify) as a *full* close → `conn_cleanup` → `conn_read` returns -1 →
  my callback never dispatches and the fd is gone, so no reply. Fix: handle
  close_notify as a *half*-close (peer done writing, server may still reply),
  per `feat/tls-prototype`'s `xymon_tls_shutdown_write()` approach.
- ❌ **BUG 2 — `select(): Bad file descriptor`** crashes xymond on TLS teardown
  (a closed fd reaches `select`). Investigate the SSL close path's fd lifecycle.
- ⬜ **Verification graft (deferred)** — client-side server-cert verification
  (`SSL_CTX_set_verify` + `X509_VERIFY_PARAM_set1_host`/`set1_ip_asc`) needs the
  `xymon` client to speak TLS first (its `sendmsg.c` connect is plain
  getaddrinfo). Then mTLS cert-auth can replace the IPv4 sender ACL.

## Next step

Fix BUG 1 + BUG 2 to make TLS functional (the close_notify half-close is the
crux; `feat/tls-prototype` is the reference). Then the client-TLS + verification
graft. Lower priority: v6 sender ACL (a/b/c); build hygiene (`IPV*_SUPPORT` from
a `build/test-ipv6` probe, not hardcoded `tcplib.o` flags).
