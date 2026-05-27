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
  response, with `conn_peer_in_addr()` bridging the peer to the IPv4 ACL: v4 and
  v4-mapped-v6 keep their real address; a pure-v6 peer has no IPv4 form so it is
  marked `255.255.255.255` and **fails the ACL closed** (option b — pure-v6
  senders must use a TLS client cert; earlier revisions mapped it to loopback,
  which let any v6 peer impersonate a trusted local sender). A v6-native
  `ipaccess`/`oksender` (`sockaddr_storage`, ~25 sites) remains the later phase.
  **Runtime
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

**P3 — IPv6 service checks (the prober).** Net-new development (devel left this
unfinished). Today an xymond *server* speaks v6/TLS, but the *prober* is v4-only:
`dns.c` resolves A records only (`ares_gethostbyname(..., AF_INET, ...)` :208,
`gethostbyname` :219); `contest.c` stores every target as `struct sockaddr_in`
(`contest.h:85`), `inet_aton`s the IP (`contest.c:179`), and opens `PF_INET`
sockets (:957); `lib/url.c`/`httptest.c` don't parse `http://[v6-literal]/`
(`:362` netloc parsing). 27 `addr.sin_*` sites in `contest.c` (17 are
`inet_ntoa` logging).

**Operator entry-point (no new syntax):** a v6 literal in the hosts.cfg IP column
(or a v6 URL) drives a v6 test — same model as v4 today. Name→AAAA resolution
(P3b) only matters for `IP=0.0.0.0` (resolve-by-name) hosts.

Sub-phases:
- **P3a — `contest.{c,h}` v6-capable engine.** `sockaddr_in` → `sockaddr_storage`
  (+ `socklen_t`); detect AF from the IP via `inet_pton` (v4/v6); `socket(family)`;
  `connect()` with stored len; v6-aware source-bind (:962); a `inet_ntop` helper
  for the 17 log sites. **IPv4 path must stay byte-identical.** No DNS/policy
  decision needed. *Compile-verifiable here; needs a real v6 service target to
  runtime-prove.*
- **P3b — DNS AAAA (`dns.c`).** SCOPE: the **host-name resolver** in `dns.c` —
  `dnsresolve()` / `add_host_to_dns_queue()` / `dns_simple_callback()` (the c-ares
  path), which turns a monitored host's name into the IP its tests connect to
  (callers: `xymonnet.c:846,873` via `ip_to_test`, `httptest.c:369,378`). This is
  A-only today and caches a single `struct in_addr` → make it resolve AAAA and
  carry a v6 result. **NOT in scope:** `dns_test_server()` (also in `dns.c`,
  `:285`) drives the `dns=` *service test* via `dns2.c` — a separate concern, and
  `dns2.c` already understands AAAA as a queryable record type. Policy
  **resolved (Q4):** default `auto` (`AF_UNSPEC`, first result, single-address),
  global `--ipproto=auto|ipv4|ipv6` flag (fleet default; `ipv4` preserves today),
  per-host `ip=4|6|auto` override. Ordered fallback / multi-address → P3e.
- **P3c — URL `[v6-literal]` parsing (`lib/url.c`, `httptest.c`).** Parse
  `http://[2001:db8::1]:port/path` (bracketed host, port after `]`). Additive,
  low-risk, compile-verifiable.
- **P3d — IPv6 `conn`/ping.** Two possible routes, neither done; **devel does
  NEITHER** (devel's `xymonping.c` has zero IPv6, and its fping invocation is
  byte-identical to main — no `-6`/`fping6`/family-split). The ping test just
  shells out to `$FPING $FPINGOPTS` (default `xymonping -Ae`) and feeds it a list
  of **IPs on stdin** (`xymonnet.c:1136`→`:1172`).
  - *Route 1 — built-in `xymonping`:* port it to ICMPv6 (raw ICMP6 socket).
    Larger; required only if the deployment uses the built-in pinger.
  - *Route 2 — external `fping`:* a v6-capable fping can ping v6 with little/no C
    change — BUT note: **xymonnet pre-resolves and feeds fping IP addresses, not
    hostnames, so fping's own resolver (incl. AAAA) is bypassed.** The list is
    built from `ip_to_test()` (`:1136`) and written verbatim to fping stdin
    (`:1243`). For `0.0.0.0` (resolve-by-name) hosts the name is resolved by
    xymonnet's own **A-only `dnsresolve`** first, so by-name hosts get a **v4-only**
    ping target — v6 ping for them needs P3b regardless of pinger. A v6 IP must
    already be in the list (v6 literal today, or P3b). Remaining xymonnet work:
    the list is one combined v4+v6 feed to one process → may need fping 4.x
    (auto-detects/mixes) or splitting into v4/`fping6` runs; `FPINGOPTS=-Ae` has
    no `-6`. So this route is mostly config + a possible list-split, not a port.
    (Pre-existing edge, not v6-specific: the ping loop checks `dnserror` *before*
    calling `ip_to_test` (`:1134`), and the feed has no `0.0.0.0` filter, so an
    unresolvable **ping-only** by-name host can leak a literal `0.0.0.0` to fping.)
  Either way: deferred.

  **v6 address-reuse audit (does a resolved/literal v6 address actually get used
  by a test?).** Name resolution (`dnsresolve`) is A-only, so it **never yields
  v6** today — only a **literal** v6 in the hosts.cfg IP column introduces one
  (`h->ip` is `IP_ADDR_STRLEN`=46, fits; `ip_to_test` returns it unchanged). Given
  a v6 literal, per consumer:
  - `tcp`/`ssl` (`add_tcp_test`←`ip_to_test`): **reused** ✓ (P3a connects v6).
  - `conn`/ping (fping list): **reused** — the v6 string is fed to fping as-is, no
    v4 validation; success then depends on the pinger (built-in xymonping fails;
    v6 fping works).
  - `http`/`https` (`httptest.c:686` `add_tcp_test(desturl->ip,…)`): **NOT reused**
    — http ignores the host IP and connects to the *URL's own host*, resolved
    separately via `dnsresolve` (v4-only) or a URL forced-IP. Needs P3b + P3c.
  - `dns=` service test (`dns_test_server`, `dns.c:303`): **rejected** — it does
    `inet_aton(serverip)` and bails "(not a valid IP)" on a v6 server IP → P3g.
- **P3g — `dns=` service test over v6 (deferred).** `dns_test_server()` parses the
  DNS server IP with `inet_aton` (v4-only) and feeds c-ares a `struct in_addr`;
  a v6 server IP is rejected. Make it accept a v6 server (inet_pton + ares v6
  server option). Note `dns2.c` already understands AAAA as a *record type*; this
  is about *reaching the DNS server over v6*. Deferred.
- **P3h — reverse DNS (PTR) — INVESTIGATE if wanted (deferred).** First disambiguate:
  the `!` "reverse" *test* flag (`xymonnet.c:502`, "service should be DOWN") is a
  negated test, **unrelated to reverse DNS**. Reverse DNS proper has two angles:
  - *As a service test:* `dns2.c` already supports a `PTR` record type
    (`:105,:372`), so monitoring "does this server answer PTR?" is possible today
    — the operator supplies the reverse name. The v6 dimension is forming the
    **`ip6.arpa`** nibble query name and reaching the server over v6 (P3g); the
    PTR parsing itself is reused as-is.
  - *As a resolver feature (IP→hostname for xymonnet's own use):* **does not exist**
    anywhere — no `gethostbyaddr`/`ares_gethostbyaddr`/`getnameinfo`. If we ever
    want it (e.g. show/verify the PTR name of a monitored IP, or forward/reverse
    consistency checks), it's net-new: `ares_gethostbyaddr`/`getnameinfo` with
    `AF_INET6` + `ip6.arpa` for v6. No current use case — flagged for investigation
    only, not scheduled.
- **P3e — multi-address resolution + ordered fallback (deferred).** Today `dns.c`
  keeps only `h_addr_list[0]` (`:120`) — a name with several A records tests just
  the first, and there's no fallback even within IPv4. P3e stores the full
  `getaddrinfo` list (A + AAAA) and has `contest` try addresses in order
  (happy-eyeballs-ish). This single phase delivers BOTH "test multiple resolved
  IPs" and the Q4 "v4-then-v6 / v6-then-v4" fallback forms. CNAME chains are
  already followed by the resolver (the final addresses are what's returned); the
  canonical name / `h_aliases` are ignored, which is fine. Largest resolver
  change; do only if multi-address robustness is required.
- **P3f — DNS resolution caching / TTL knob (deferred).** Today `dns.c`'s cache
  (`dnscache`, `:59`) is **per-process with no TTL/expiry**: built fresh by
  `dns_init()` each run, a name resolves once per run (`find_dnscache` short-circuits,
  `:190`), and `resolvetime` (`:56`) is stats-only. Since xymonnet re-runs each
  test cycle, it effectively re-resolves every cycle — no knob to honor DNS record
  TTL or cache across cycles. A `--dns-cache-ttl=N` (or similar) arg would allow
  non-default caching. Deferred.

**Deferred for now (explicit):** P3d (`conn`/ping v6), P3e (multi-address +
ordered fallback), P3f (resolution caching/TTL), P3g (`dns=` test over v6), and
P3h (reverse DNS / PTR — investigate-only) are all **out of scope** for the
current P3 effort. P3 now targets P3a (done) +
P3b (single-address family selection) + P3c (URL brackets); P3d/P3e/P3f/P3g are
later follow-ups.

**Verification gap:** xymonnet compiles here (pcre2/pcre/ares/rrd headers present)
but cannot be runtime-proven on this box (needs reachable v6 HTTP/TCP targets).
P3a/P3c land as compile-verified; runtime proof deferred to CI or a v6 test host.

Recommended order (active scope): **P3a (done) → P3c → P3b**. P3a+P3c give "test a
v6 service by literal address/URL" with no policy decision; P3b adds single-address
name resolution under the settled Q4 policy. **P3d (ICMPv6), P3e (multi-address +
fallback), P3f (resolution TTL/caching) are deferred follow-ups**, not in current
scope.

**P4 — Tests + CI** *(unchanged; see below)*.

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
2. **Dual-stack** — RESOLVED: true two-socket listen implemented (separate v4 +
   v6 wildcard binds, `IPV6_V6ONLY` forced on), not the single v6+mapped socket.
3. **Prototype reconciliation** — `feat/tls-prototype` becomes the *source* of the
   P2 TLS, then retires; confirm nothing else depends on it.
4. **P3b DNS address-family selection — RESOLVED.** Two-level policy:
   - **Default `auto`** = `getaddrinfo(AF_UNSPEC)`, take the **first** result
     (family per OS/RFC-6724 order). NOTE: this is a **single-address** resolve, no
     connect-time fallback — matching today's resolver, which already keeps only
     `h_addr_list[0]` (`dns.c:120`) and discards any further addresses. (Earlier
     wording said "first *working* address with fallback"; that was inaccurate —
     fallback needs the full address list, see the new deferred phase below.)
   - **Global fleet default** — a new xymonnet flag `--ipproto=auto|ipv4|ipv6`
     (set in `tasks.cfg`, same style as `--dns=`), default `auto`. `--ipproto=ipv4`
     preserves today's IPv4-only behavior fleet-wide. (No such global exists today:
     `--dns=` is IP-vs-name, orthogonal to family; the prober is *implicitly* v4.)
   - **Per-host override** — a hosts.cfg tag `ip=4|6|auto` that wins over the global.
   - Resolution order per test: per-host tag → global `--ipproto` → `auto`. A literal
     v4/v6 IP in the hosts.cfg IP column pins the family regardless (no resolution).
   - **Deferred → P3e:** the ordered "v4-then-v6 / v6-then-v4" fallback forms.
     These are the **same work** as treating *multiple* resolved addresses (today
     only the first is kept), so they're folded into a new multi-address phase
     (P3e). No devel precedent (devel's prober is A-only; its tcplib only has an
     internal `CONN_IPPROTO_ANY/V4/V6` hint with no fallback). Revisit only if
     needed.

- **Step 3 (client) ✅ DONE & PROVEN.** `sendmsg.c` connect rewritten to
  `getaddrinfo(AF_UNSPEC)` + non-blocking connect loop (select/IO loop
  unchanged). Recipient may be a v4/v6 literal or a hostname. **Proof (real
  `xymon` client):** `ping` → `xymond 4.3.30` over `127.0.0.1` and `localhost`;
  a `status` report lands on the board, no ACL rejection. Pure non-mapped v6
  client path → CI.
  - ✅ **Dual-stack connect fallback.** The connect loop no longer commits to
    the first address: `start_connect()` walks the `getaddrinfo` list, and if an
    async connect fails the IO loop falls back to the next address (e.g. IPv4
    after an unreachable IPv6) instead of returning `ECONNFAILED`. The list now
    stays live until `done:`. **Proven:** with a name resolving to a dead `::1`
    (first) + live `127.0.0.1`, the client falls back and gets `xymond 4.3.30`;
    smoke suite still 11/11.

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
- ✅ **BUG 2 FIXED — the `select(): Bad file descriptor` crash.** Root cause:
  `xymond_conn_cb` treated `conn_read()==0` as EOF even during the SSL handshake
  (`CONN_SSL_ACCEPT_READ` etc.), firing `do_message` on an empty buffer
  mid-handshake and tearing the conn down. Now guards those states (return
  `CBRESULT_OK`), per devel's pattern. Also: `try_ssl_io` now surfaces a clean
  close_notify (`SSL_ERROR_ZERO_RETURN`) as EOF without tearing down. Verified:
  TLSv1.3 handshake, no crash on handshake/teardown; plaintext + IPv4 unaffected.
- ✅ **BUG 1 RESOLVED (server) — functional TLS delivery via `size:` framing.**
  The half-close/EOF model can't delimit a message over TLS (records sit in
  OpenSSL's buffer; `select` never re-fires). Server now dispatches on a declared
  byte-count: a `size:N\n` header → `conn_t.msgsz` → dispatch when `buflen >= N`,
  no EOF needed. Also fixed: `n==0` is EOF only for `CONN_PLAINTEXT` (for SSL it
  means "no data yet"). **PROVEN over pure IPv6 `::1` + TLSv1.3:** size-framed
  `ping` → `xymond 4.3.30` (request/response), size-framed `status` → board
  (`localhost|tlsframed|green`); no crash; plaintext/IPv4 (EOF-framed) unaffected.
- ✅ **Client TLS DONE & PROVEN.** Ported the prototype's synchronous helper
  `lib/xymon_tls.{c,h}` and wired it into `sendmsg.c`: `xymons://host[:port]`
  scheme (default `:1985`, `[v6]` ok), blocking handshake, `size:N\n`-framed
  write + reply read. Build: `xymon_tls.o` in the comm libs, `HAVE_XYMON_TLS`
  gated on `SSLFLAGS`. **Proven with the real `xymon` client over `::1` +
  TLSv1.3:** `xymons://localhost` + `XYMON_TLS_CA` (full verify) → `xymond
  4.3.30`; `status` → board; `XYMON_TLS_VERIFY=none` → MITM warning + works.
- ✅ **Verification graft DONE.** `xymon_tls.c` does server-cert verification
  (`set1_host`/`set1_ip`, modes `full|peer|none`) — and **fails closed**:
  `verify=full` with no `XYMON_TLS_CA` refuses the handshake (proven).
- ✅ **mTLS DONE & PROVEN** (`XYMON_TLS_CERT/KEY` ↔ server `--tls-ca` +
  `--tls-require-clientcert`): client-with-cert → `xymond 4.3.30` and status →
  board; client-without-cert → server rejects (`tlsv13 alert certificate
  required`). Mutual authentication confirmed.
- ✅ **Listener hardening DONE & PROVEN.** Replaced the single
  v6+IPv4-mapped socket with deterministic dual-stack and fixed the listen-spec
  parsing/error paths in `xymond.c` + `lib/tcplib.c`:
  - `build_listenspec()` parses addresses bracket-aware (host, `host:port`,
    `[v6]`, `[v6]:port`); a wildcard expands to `0.0.0.0:p,[::]:p` (two sockets).
    `listen_port()` forces `IPV6_V6ONLY` so the v4/v6 binds never collide and v4
    no longer depends on `net.ipv6.bindv6only` (BSD/macOS-safe). Same expansion
    applied to `--tls-listen`.
  - `conn_listen`/`conn_init_server` now return the count of sockets bound
    (was an inverted `(result==0)` that was always discarded); xymond logs
    `FATAL` and `exit(1)` if zero listeners bind instead of running headless.
  - **Proven:** `--listen=[::1]:P` binds `[::1]` only (v6 ping ok, v4 refused);
    `--listen=0.0.0.0:P` binds both `0.0.0.0:P` and `[::]:P`; unbindable
    `192.0.2.1:P` → exit 1 + FATAL log; full smoke suite 11/11 (incl. IPv4
    `localhost` TLS against the `[::]` listener).
  - **SUPERSEDED by P5g (below):** at the time of this entry an *explicit*
    `0.0.0.0`/`[::]` wildcard expanded to dual-stack. P5g changed that — now only
    an **omitted** `--listen` (or an explicit comma-list) is dual-stack; explicit
    `0.0.0.0` is IPv4-only and `[::]` is IPv6-only. The dual-stack claims in this
    P2 bullet are historical, not current behavior.

## Next step

Done & proven (all lower-priority items now complete):
- ✅ **cert-based sender ACL** — a verified TLS client cert authorizes the sender,
  bypassing the IP `oksender` ACL (status/data/www/maint) and closing the pure-v6
  stopgap. Decision taken: **trust except admin** — admin/config still requires
  `adminsenders` (via `ok_admin_sender`). Proven (smoke phase 3, 11/11): with
  `--status-senders` restricted, a non-cert sender is dropped, a cert sender gets
  through.
  - **SUPERSEDED by P5 (unified `--acl`):** the final design removed `oksender`
    and the `--*-senders` lists entirely. A cert is no longer a *bypass* — it is
    matched by `cert:*` / `cert:<id>` rules in the rule table; admin is data
    (omitted from `cert:*` by default, grantable only with `force`), not a
    hard-coded `ok_admin_sender` exception. The bypass / `--status-senders`
    wording above is historical.
- ✅ **Build hygiene** — `IPV*_SUPPORT` via a `configure` probe
  (`build/ipv6.sh` → `IPV6DEF`); `HAVE_XYMON_TLS` gated on `$(SSLFLAGS)`.

Remaining items:
- **CI execution** — the manual `ipv6-test.yml` lane runs `tests/ipv6-tls/smoke.sh`;
  it'll run once GitHub's Actions auth incident (2026-05-26) is mitigated. Code +
  lane are ready; nothing to fix.
- **P5 — unified capability ACL** (below): the v6-native `ipaccess` rework, done
  as one capability-based rule engine instead of four IPv4-only sender lists.

Status: **IPv6 (P1) and TLS/mTLS (P2) complete & proven** — handshake, TLS 1.3
floor, request/response + ingest, `xymons://` client with enforced server-cert
verification, mutual TLS, and cert-based sender authorization, all over pure
`::1` (smoke test 22/22). TLS is opt-in; plaintext + IPv4 unaffected.

---

## P5 — Unified, capability-based, v6-native ACL

**Why.** Today access control is four parallel IPv4-only sender lists
(`--status-senders` / `--www-senders` / `--maint-senders` / `--admin-senders`,
`oksender` at ~25 call sites) plus a cert-trust bypass that's a special case in
code (`ok_admin_sender` zeroes the cert flag so a cert can't grant admin), plus
*no* way to require encryption. Three weaknesses converge: (1) IPv4-only — a
native-v6 sender can't be expressed, so it fails the ACL closed and *must* use a
cert (P1 Step-2 FINDING 2); (2) the privilege tiers and the cert/admin rule are
scattered logic, not inspectable config; (3) plaintext is always accepted from
anyone the IP list allows — encryption can't be mandated.

This is the same ~25-site rework that v6-native `ipaccess` needs anyway. Do it
**once** as a single rule engine rather than generalizing four lists to v6.

**Model.** One ordered rule table; each rule is `SOURCE TRANSPORT CAPS`:
- SOURCE: v4/v6 CIDR (bare = host), `local` (loopback v4 127/8 + v6 `::1`),
  `cert:*` (any verified cert), `cert:<id>` (a named cert identity).
- TRANSPORT: `tls` (require encryption), `plain` (require cleartext), `any`.
- CAPS: any of `status,www,maint,admin` or `all`.

**First-match-wins**, default-deny; order rules specific-before-general. The
admin/cert rule is now *data*: a `cert:*` rule simply omits `admin`, so the
`ok_admin_sender` special case disappears. Example expressing the whole desired
posture (localhost-full, intranet-may-use-plaintext, remote-must-TLS+cert):

```
cert:ops-admin  tls   all                  # named admin identity (before cert:*)
local           any   all
10.0.0.0/8      any   status,www,maint     # intranet: plaintext or TLS, no admin
2001:db8::/32   any   status,www,maint
cert:*          tls   status,www           # any verified cert: reporter only
# (no match -> deny)
```

**Backward compatibility.** The four legacy `--*-senders` flags are *removed*:
xymond exits with a fatal error pointing the operator at `--acl=FILE`, rather
than silently dropping the access restriction they intended. When *no* `--acl`
is configured, `access_check()` allows everything (today's "no sender list"
default), so unrestricted deployments are unaffected. The restrictive posture is
opt-in, never a silent default flip.

When an `--acl` *is* loaded it is the sole sender chokepoint: every protocol
command that writes state or exposes data is gated through `access_check()` —
including `summary` (status), `flush filecache` / `reload` / `rotate` /
`schedule` / `senderstats` (admin). `ping`/`dummy` stay open as liveness probes.
Scheduled commands are re-checked against their original sender when they run.

**Phasing.**
- **P5a — engine. ✅ DONE (this change).** Self-contained `lib/acl.{c,h}`:
  rule struct, `acl_parse_line`, `acl_append`, `acl_check`, `acl_free`. v4+v6
  CIDR, `local`, `cert:*`/`cert:<id>`, transport filter, capability bitmask,
  first-match-wins, default-deny. Standalone unit test `tests/acl/test_acl.c`
  (no libxymon dep) — **18/18**, builds clean under `-Wall -Wextra`. Not yet
  wired into the build or daemon (keeps the tree green).
- **P5b — integration. ✅ DONE & PROVEN.** `lib/acl.c` built into `libxymon`
  (`XYMONLIBOBJS`); `acl.h` exposed via `include/libxymon.h`. `conn_t` now
  carries `encrypted` (set at `CONN_CB_SSLHANDSHAKE_OK`), the verified-cert CN
  (`certcn`, for `cert:<id>`), and the native v4/v6 peer (`conn_peer_acl_addr`,
  v4-mapped normalized to AF_INET). All ~25 `oksender(...)` call sites + the two
  `if (statussenders)` guards route through one `access_check(msg, cap, tip,
  log)`; `ok_admin_sender` is now a thin `access_check(…, ACL_CAP_ADMIN, …)`
  wrapper (admin-not-cert is preserved). New `--acl=FILE` loads the rule table
  (parse error = fatal); when set it supersedes the `--*-senders` lists, else
  the legacy `oksender` path runs **byte-for-byte unchanged** (default backend,
  proven by smoke 1-5 at 22/22). New smoke phase 6 exercises the unified path:
  local-plaintext allowed, verified-cert-over-TLS allowed, TLS-without-cert
  denied (default-deny + transport gating). Full suite **25/25**.
  - Backfeed IPC (sender 0.0.0.0) is still trusted in both backends. Under the
    unified ACL the legacy self-report / 0.0.0.0-target bypass is *not* carried
    over -- the rule table is authoritative (opt-in, default-deny).
  - `ipaccess.c`/`oksender` are NOT retired: they remain the legacy backend.
- **P5c — legacy removed. ✅ DONE.** The four `--*-senders` lists/flags/globals,
  the `oksender` branch in `access_check`, and the per-message
  `sender_cert_authorized` assignment are gone from xymond; `--acl` is the sole
  sender access control. Decisions: **no `--acl` ⇒ allow all** (historical
  default preserved); a removed `--*-senders` flag ⇒ **fatal** ("use --acl").
  `ipaccess.c`/`oksender`/`sender_t`/`getsenderlist` remain (used by
  `client/msgcache.c` and xymond `--trace`). Admin is no longer special-cased in
  code -- it follows the table's default-deny; "a cert is not an admin" is now a
  convention (keep `admin` off `cert:*`), not a hard guard.
- **P5c — admin-breadth safety net. ✅ DONE.** Replacing the old hard "cert is
  never admin" guard: `acl_audit_admin()` makes xymond **refuse to start** if a
  rule grants admin (`admin`/`all`) to a broad source -- `cert:*` or a CIDR
  wider than /24 (v4) / /120 (v6); `local`/`cert:<id>` exempt. A trailing
  `force` token acknowledges an intentional broad grant. Data-driven, but
  accidental "everyone is admin" is fatal. Unit test 28/28, smoke 28/28
  (phase 3 on `--acl`; assertions: removed flag exits, broad-admin exits,
  broad-admin+force starts).
- **P5d — review hardening. ✅ DONE.** Six issues from a branch review:
  1. A configured-but-empty `--acl` (file present, only blank/comment lines) no
     longer falls through to "no ACL ⇒ allow all" — it is now **fatal** at load
     (would otherwise silently fail open against default-deny).
  2. Stock `tasks.cfg.DIST` no longer passes the removed `--admin-senders` (which
     is now fatal and would block startup); it loads a shipped default
     `etcfiles/xymonacl.cfg` (loopback=admin, everyone else status/www/maint),
     installed copy-if-absent so an operator's policy is never clobbered.
  3. `acl_parse_line` accepts trailing inline `# comments` (used in the docs)
     and blank/whitespace-only lines (the leading skip now eats `\r`/`\n`).
  4. CIDR prefix parsing uses strict `strtol` end-pointer validation, not
     `atoi` — `/junk` (→ silent `/0` = match-all) and `/24junk` are now rejected.
  5. `conn_print_address_and_port`'s buffer sized `INET6_ADDRSTRLEN +
     sizeof("[]:65535")` — the old 48-byte buffer could overflow on a long
     `[IPv6]:port`.
  6. `--check-tls` with no `--tls-cert` now exits non-zero (TLS would be
     disabled), matching the documented "exit 0 = TLS would be served" contract.
  Unit test `tests/acl/test_acl.c` **42/42** under `-Wall -Wextra`. Smoke phase 4
  gains two assertions (empty-`--acl` aborts; `--check-tls` no-cert fails).
- **P5e — reference docs. ✅ DONE.** `xymond.8` rewritten: the four removed
  `--*-senders` entries are gone, replaced by `--acl`, `--tls-listen`,
  `--tls-cert`, `--tls-key`, `--tls-ca`, `--tls-require-clientcert`, `--check-tls`,
  plus a `COMPATIBILITY` section documenting the removal/migration. HTML manpage
  regenerated via `build/makehtml.sh`'s `man2html` invocation (boilerplate
  normalized to match siblings; content-only diff). `xymond -h` now lists the
  `--tls-*` flags. (The manpage previously documented only the removed flags,
  which now fatally abort startup.)
- **P5f — second-pass review fixes. ✅ DONE.** Five items from a re-review:
  1. `size:N` TLS framing tightened both ends: client sends `size:%zu` (was an
     `(int)` cast that mis-frames a >2GB body); server parses with strict
     `strtol` end-pointer validation (was `atol`, which took `size:100x` as 100)
     and dispatches **exactly** `msgsz` bytes (terminating at the declared
     length) so trailing bytes can't be folded into the message body.
  2. Default ACL now reproduces the old `--admin-senders` server-IP coverage:
     `xymonacl.cfg.DIST` carries an `@XYMONHOSTIP_ADMIN@` marker that
     `make cfgfiles` replaces with `<server-ip> any all` (ordered before the
     catch-alls), or drops when the server IP is loopback. /32 host => passes
     the broad-admin audit.
  3. `conn_check_tls_server_config` now returns failure in **non-OpenSSL** builds
     too (TLS can never be served there) — the twin of the OpenSSL no-cert fix.
  4. Docs/help corrected: `--tls-key` is optional (key may live in the
     `--tls-cert` file) — `xymond.8`, regenerated HTML, and `xymond -h`.
  5. Stale `acl.h` comment fixed: admin to `cert:*` is allowed *with* `force`.
- **P5g — explicit `--listen` wildcards bind a single family. ✅ DONE.** Finalized
  semantics: `--listen` omitted => dual-stack `0.0.0.0:p,[::]:p`; `0.0.0.0` =>
  IPv4 wildcard only; `[::]` => IPv6 wildcard only; a comma list (e.g.
  `0.0.0.0:p,[::]:p`) => explicit dual-stack; same rules for `--tls-listen`.
  Code: `build_one_listenspec()` no longer expands explicit `0.0.0.0`/`::` to
  dual-stack, and the default `listenip` is now NULL so the omitted case (not an
  explicit wildcard) is what produces dual-stack (`[::]` is `IPV6_V6ONLY`).
  Comma-list support already existed. Docs (`ipv6-tls.md`, deployment guide,
  `xymond.8` + HTML) updated; smoke binds explicit dual-stack and a new phase 9
  asserts v4-only / v6-only / comma-dual / omitted-default. Smoke 44/44.
- **Remaining / deliberately out of scope:**
  - OpenSSL 3 — **verify-only**: builds clean against 3.0.2 with the deprecated
    (but present) `SSL_library_init`/`SSLv23_*_method`/`SSL_get_peer_certificate`
    APIs; only matters under a `no-deprecated` OpenSSL. Optional cleanup.
  - systemd unit, compression, BFQ scaling, RRD/graph polish, packaging,
    distro/client portability, and devel's older IPv6/TLS implementation — all
    separate follow-up branches, not this one.
