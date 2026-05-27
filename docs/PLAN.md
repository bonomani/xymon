# Xymon IPv6 + TLS — plan

**Branch:** `feat/ipv6-tls`, off `main` (42f24171).
**Approach (A′):** adopt devel's async `tcplib` connection engine, but graft a
**modernized, verifying TLS** onto it instead of shipping its 2015 crypto.

This file tracks the *decisions* and the *remaining* work. Completed work is in
the commit history; only a one-line status summary is kept here.

---

## Decision record

- **A′ over plain devel:** keep tcplib's async, IPv4/IPv6-unified engine; replace
  its weak TLS (CN-only identity, client never verifies the server, no protocol
  floor) with the prototype's hardening. Rejected: hand-rolling v6 on the old
  select loop (B), transport-only (C).
- **`--listen` semantics:** omitted ⇒ dual-stack (`0.0.0.0:p` + `[::]:p`, two
  sockets, `IPV6_V6ONLY` forced); an explicit wildcard binds **one** family
  (`0.0.0.0`=v4, `[::]`=v6); a comma list is explicit dual-stack. Same for
  `--tls-listen`.
- **Sender access control:** one unified, capability-based, transport-aware
  IPv4/IPv6 `--acl` rule table replaces the four `--*-senders` lists (which now
  fatally error). A verified client cert is matched by `cert:*`/`cert:<id>`
  rules; admin to a broad source needs an explicit `force`.
- **Q4 — prober DNS address-family (gates P3b only):** default `auto`
  (`getaddrinfo(AF_UNSPEC)`, first result, single-address), a global
  `--ipproto=auto|ipv4|ipv6` xymonnet flag (fleet default; `ipv4` preserves
  today), and a per-host hosts.cfg `ip=4|6|auto` override. Ordered v4↔v6 fallback
  and multi-address are deferred (P3e).

---

## Status — done (proven)

- **Transport (P1):** tcplib hand-wired into xymond; deterministic dual-stack
  listen; client (`sendmsg`) uses `getaddrinfo(AF_UNSPEC)` with cross-address
  fallback. Proven by `tests/ipv6-tls/smoke.sh`.
- **TLS (P2):** server cert/key, client verifies server (full/peer/none),
  SAN/IP identity, TLS≥1.2, mTLS, `--check-tls`, `size:N` framing. In smoke.
- **Unified ACL (P5):** `lib/acl.{c,h}` + integration; legacy `--*-senders`
  removed; admin-breadth `force` guard; `--acl` default-deny. Unit test 42/42;
  smoke phases 3/6/7.
- **Reference docs:** `xymond.8` rewritten (`--acl`, `--tls-*`, `--check-tls`,
  bracketed-v6 listen, COMPATIBILITY); `docs/ipv6-tls{,-deployment}.md`.
- **IPv6 prober, by literal:**
  - **P3-pre** — `loadhosts_file.c` accepts a v6 literal in the hosts.cfg IP
    column (`conn_is_ip` validate + verbatim store; local `inet_pton` helpers so
    the client comm lib doesn't pull tcplib). Runtime-proven via the standalone
    `loadhosts` test.
  - **P3a** — `contest.c` v6-capable connect engine (`sockaddr_storage`,
    AF-aware socket/connect/source-bind, `inet_ntop` logging). v4 byte-identical.
    v6 TCP connect runtime-proven via `tests/ipv6-tls/prober-smoke.sh`
    (`::1` open + banner; v4 parity; refused-v6 fails closed).

So **a v6-literal host is testable end-to-end** (tcp/ssl/http-by-IP via P3a;
conn/ping carried to fping). Not yet proven: the full xymonnet→xymond pipeline
and HTTPS over v6 (need a reachable v6 service target).

---

## Remaining work (deferred)

The *prober* is IPv4-only upstream too (devel's `contest`/`dns`/`url`/ping are
v4), so each of these is net-new (P3-pre being the one exception, ported from
devel). All compile-checkable here; runtime proof needs a v6 target / CI v6 lane.

- **P3b — by-name v6.** `dns.c` host-name resolver (`dnsresolve`/
  `add_host_to_dns_queue`/`dns_simple_callback`) is A-only and caches a single
  `struct in_addr`; make it resolve AAAA per the Q4 policy (global `--ipproto` +
  per-host `ip=` tag). *Not* `dns_test_server()` (that's the `dns=` test, P3g).
- **P3c — URL `[v6-literal]`.** `lib/url.c`/`httptest.c` don't parse
  `http://[2001:db8::1]:port/`. Additive.
- **P3d — `conn`/ping over v6.** In practice fping is the pinger (`configure`
  auto-detects it and recommends it over the "not fully stable" `xymonping`).
  xymonnet feeds fping **pre-resolved IPs** (not names), so fping's own AAAA is
  bypassed — a v6 IP must already be in the list (literal via P3-pre, or P3b).
  Work = a v6-capable fping + handling the mixed v4+v6 list (fping 4.x or split
  into v4/`fping6`; `-Ae` lacks `-6`). Porting `xymonping` to ICMPv6 is the
  low-value minority route — likely skip.
- **P3e — multiple addresses + ordered v4↔v6 fallback.** Resolver keeps only
  `h_addr_list[0]` today; storing the full list + happy-eyeballs delivers both
  multi-address robustness and the Q4 comma forms.
- **P3f — DNS resolution cache/TTL knob.** Cache is per-process, no TTL; a
  `--dns-cache-ttl=N` would allow non-default caching. Tuning only.
- **P3g — `dns=` service test over v6.** `dns_test_server()` `inet_aton`s the
  server IP (v4 only); accept a v6 server. (`dns2.c` already parses AAAA records.)
- **P3h — reverse DNS / PTR (investigate-only).** No IP→name resolver exists; the
  `!` "reverse" *test* flag is unrelated. PTR-as-a-`dns=`-test already works.
- **P4 — Tests + CI.** Extend the BSD/LibreSSL CI; add a v6 lane to runtime-prove
  the prober (P3a/P3-pre) and the full v6 pipeline.

---

## Open question

1. **Scope.** Stop at "v6 transport + TLS + ACL + v6-by-literal prober" (current
   state), or continue P3b/P3c (by-name + URL v6) for full v6 service-checking?
