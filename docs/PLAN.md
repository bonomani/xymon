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
- **plain A** (tcplib as-is) — its 2015 TLS (`SSLv23_*_method`,
  `SSL_library_init`, no peer verification) won't even build clean on OpenSSL-3 /
  current LibreSSL; modernization is mandatory, so A′ strictly dominates it.
- **B** (hand-roll IPv6 on the existing select loop) — reinvents tcplib's
  abstraction, keeps the blocking model, no async/TLS upside.
- **C** (transport-only) — smallest, but leaves the connection model and service
  checks where they are; not "most powerful".

---

## What A′ is, concretely

`tcplib` (async engine, from devel) + the prototype's TLS internals
(`lib/xymon_tls.c` logic) wired into tcplib's `SSL_CTX`/`SSL` slots. We keep
tcplib's structure (STARTTLS states, cert-based ACL replacing IP ACLs, the
callback event loop); we swap only the crypto:

| tcplib (2015) | → grafted (A′) |
|---|---|
| `SSLv23_server/client_method` | `TLS_*_method`, TLS 1.3 |
| no peer verification | `X509_VERIFY_PARAM_set1_host` / `set1_ip_asc` |
| `SSL_library_init` / `OpenSSL_add_all_algorithms` | auto-init; LibreSSL `sslerr.h` guard |
| no close_notify / EOF handling | correct `close_notify`, EOF-tolerant read |
| — | trust modes: pinning / encrypt-only |

---

## Phases

**P0 — Feasibility spike (do first).** Drop `lib/tcplib.c`/`.h` + a minimal build
hook onto the branch; try to compile on this box. Expectation: the 2015 TLS APIs
fail → confirms the P2 modernization surface. Output: a short note of exactly
what breaks.

**P1 — tcplib + IPv6 transport, plaintext only (`CONN_SSL_NO`).**
Port from devel (source applies cleanly — `main` files are identical to devel's
base): `tcplib.c/h`, `sendmsg.c` connect, `xymond.c` listener/event-loop (45
call-sites), `ipaccess.c/h`, `loadhosts_net.c` (hosts.cfg v6 parsing),
`xymond_ipc.c/h`, `build/test-ipv6.c` + build hooks (`Makefile.rules`,
`configure.*`, `genconfig.sh`). **Disentangle from the 4.3 trunk** — take only
these files, *not* compression/packaging. Goal: v6 client→xymond report
end-to-end; **IPv4 must stay unbroken**.

**P2 — Graft modern TLS (the A′ core).** Replace tcplib's crypto with the
prototype's stack (reuse `lib/xymon_tls.c`): TLS 1.3, host/IP verification,
OpenSSL-3 + LibreSSL portability, close_notify, trust modes. Keep tcplib's
STARTTLS + cert-ACL wiring. Goal: mTLS handshake over tcplib, verifying.

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

## Next step

Run **P0**: bring `tcplib.c/h` onto the branch and attempt a build → report what
the 2015 TLS APIs break, sizing P2.
