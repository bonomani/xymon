# RFC stub — Unify the network prober onto the `tcplib` transport engine

> **Status:** stub / RFC. No functional change — this branch adds only this
> document and `TODO(prober-on-tcplib)` markers in `xymonnet/contest.c`.
> **Branch:** `split/08-prober-on-tcplib` (overlays `split/02-xymonnet-ipv6`).
> **Depends on:** `split/04-server-ipv6-plaintext` (tcplib) + `split/05-tls` (xymon_tls).
> **Relates to:** the IPv6/TLS split series, and issue #123 (declarative service catalog).

## Problem — Xymon has two parallel network stacks

The IPv6/TLS work gave the **internal message bus** (client→server, server→server)
a modern transport: `lib/tcplib.c` — dual-stack IPv4/IPv6, TLS 1.2/1.3 with
STARTTLS, and both `SOCK_STREAM` and `SOCK_DGRAM`, behind a clean callback API
(`conn_prepare_connection`, `conn_listen`, `conn_*` callbacks).

The **outbound prober** (`xymonnet/contest.c`, which tests remote TCP services)
never adopted it. It still carries its **own, self-contained engine**:

| Concern | Bus (modern) | Prober (`contest.c`) |
|---|---|---|
| Socket | `tcplib` `conn_*` | hand-rolled `socket(…, SOCK_STREAM, 0)` + `select()` loop |
| TLS | `tcplib` / `lib/xymon_tls` | hand-rolled `SSL_new` / `SSL_connect` / `setup_ssl` |
| IPv6 | native in `tcplib` | **re-implemented by hand** (`sockaddr_storage`) in this series |
| UDP | `CONN_SOCKTYPE_DGRAM` available | none — `SOCK_STREAM` hardcoded |
| DNS/NTP/LDAP | — | yet **more** engines (`c-ares`, `ntptest.c`, `ldaptest.c`) |

Consequence: the IPv6 (and, for `https`, the TLS) effort had to be done **twice**,
and every future transport capability (UDP, QUIC, STARTTLS, happy-eyeballs,
source-address selection) must be built once per engine.

## Proposal — migrate the prober's *transport* onto `tcplib`

Replace `contest.c`'s bespoke socket/SSL code with `tcplib`'s `conn_*` API:

- outbound connect → `conn_prepare_connection()` (STREAM **or** DGRAM)
- readiness/IO → `conn_*` callbacks instead of the local `select()` loop
- TLS → tcplib's handshake (shared with the bus), instead of `SSL_new`/`SSL_connect`

### What it unlocks

- **IPv6 for every probe**, inherited — not re-coded per test.
- **TLS once**: `https`, plus STARTTLS variants (SMTP/IMAP/POP/LDAP) on one path.
- **UDP/DGRAM probing** (NTP, DNS, SNMP, QUIC) on the same engine — today these
  bypass `protocols.cfg` via dedicated code.
- Deletes hundreds of lines of duplicated socket/SSL handling.

## Scope — transport only. Framing is a *separate* concern.

This RFC is strictly about the **transport layer**. It does **not** touch how a
probe decides a response is good. That framing/semantics layer is per-protocol
and belongs in a declarative catalog:

- **Bus framing** = `size:N` length prefix. Internal to Xymon; **must never leak
  into probes** (a remote SMTP/HTTP server speaks its own protocol).
- **Probe framing** = banner-first vs send-then-read, line- vs length-delimited,
  one-read vs multi-read, expect strings. Today hardcoded as `TCP_GET_BANNER` /
  `TCP_SSL` flags and compiled-in `svcinfo_t` (`http`/`https`). This should move
  into `services.cfg` — **that is issue #123**, not this branch.

So the clean separation is:

```
TRANSPORT  (sockets, v6, TLS, STREAM/DGRAM)
   └─ ONE engine: tcplib, shared by bus + prober      ← this RFC
FRAMING / SEMANTICS  (where a message ends; banner-first; expect)
   ├─ bus    → size:N                                  (internal, done)
   └─ probe  → declarative in services.cfg             ← issue #123
```

## Migration sketch (incremental, behaviour-preserving)

1. **Wrap, don't rewrite.** Introduce a thin `probe_conn` shim over `conn_*`,
   route one simple service (e.g. plain `tcp`) through it, keep the old path for
   the rest. Prove byte-for-byte identical banners.
2. **Move TLS** (`https`) onto tcplib's handshake; delete `setup_ssl`.
3. **Add DGRAM** and port one UDP test (e.g. `ntp`) off its bespoke engine.
4. **Retire** the `select()` loop and `contest.c`'s OpenSSL state machine once all
   services are migrated.

## Hard points

- **Concurrency model.** `contest.c` fans out many sockets in one `select()` pass
  with strict per-run timeouts; `tcplib`'s callback loop must preserve the same
  parallelism and timeout accounting (child counts, slow-limit).
- **Banner timing.** The SMTP `554` bug (#123) is exactly a *framing* decision
  (read banner before sending). The transport move must keep framing pluggable so
  #123 can fix it — not re-bake send-then-read into the new path.
- **Non-TCP engines.** `c-ares` (DNS) and NTP/LDAP probes are separate; folding
  them in is a later phase, not a prerequisite.
- **Source-address / happy-eyeballs.** Preserve the existing source-address
  selection; decide whether v4/v6 race (RFC 8305) is in scope.

## Markers in the tree

`xymonnet/contest.c` carries `TODO(prober-on-tcplib)` at the three anchor sites:
the engine overview (above the hardcoded `svcinfo_http`/`svcinfo_https`), the
`socket()` allocation, and the `SSL_new()` handshake.
