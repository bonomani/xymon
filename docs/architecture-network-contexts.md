# Xymon networking architecture — two contexts, one shared transport

> **Status:** architecture note (no code change). A map for reasoning about the
> in-flight IPv6/TLS, service-catalog, and dependency work, and for deciding
> *which layer* a given feature belongs to.
> **Relates to:** the `split/*` branch series (IPv6/TLS), issue #123 (declarative
> service catalog), issue #195 (unified dependency primitive), plan phase P3e
> (multi-address).

## 1. The organizing principle — who controls both ends?

Almost every recurring question ("should IPv6 / TLS / multi-address / framing
apply here?") resolves the moment you ask **how many ends of the connection
Xymon owns**:

- **Context 1 — the bus** (client→server, server→server, CGI→server). Xymon owns
  **both ends**. It can therefore **impose** its own transport (TLS), its own
  message framing (`size:N`), and its own identity model (mTLS client certs).
- **Context 2 — the probes** (server→monitored target). Xymon owns **only its
  end**. The peer is a **foreign service** (HTTP, SMTP, SSH, DNS, NTP…). Xymon
  must **adapt** to the target's protocol and framing, and can only **validate**
  (never impose) the target's identity.

This asymmetry is the reason `size:N` is bus-only, why probe framing must be
*declarative*, why the sender ACL is bus-only while certificate *validation* is
probe-side, and so on. Keep it in mind whenever a feature feels like it "should
obviously apply everywhere" — usually it applies to **one** context only.

## 2. The layered map — one shared layer, everything above diverges

```
                CONTEXT 1 : BUS                  CONTEXT 2 : PROBES
            (Xymon <-> Xymon, both ends ours)  (Xymon -> foreign service)
-----------------------------------------------------------------------------
IDENTITY    sender ACL + mTLS (impose)         validate target cert (expiry/chain)
FRAMING     size:N  (we define it)             per-protocol -> declarative (#123)
SEMANTICS   the Xymon protocol                 HTTP/SMTP/DNS/... (services.cfg, #123)
DEPENDENCIES       ----- status conditioning (#195) -----   (mostly probe tests)
-----------------------------------------------------------------------------
TRANSPORT   +------------- SHARED : tcplib -------------+
(v6 / TLS /  | Bus: USES it          Probe: SHOULD (08) |   <- the only unify target
 STREAM/DGRAM,+-------------------------------------------+
 multi-addr)
```

**Exactly one layer is genuinely shareable: the transport** (sockets, IPv6, the
TLS handshake, STREAM/DGRAM, address iteration). Everything above it is
**context-specific by design** — and trying to share it (e.g. pushing `size:N`
or the sender ACL onto probes) would be a layering error.

## 3. Status matrix — concern x context

| Concern | Bus (ctx 1) | Probe (ctx 2) |
|---|---|---|
| **IPv6 / transport** | done — `lib/tcplib.c` | v6 hand-coded in `contest.c`; **separate engine** (→ stub `08`) |
| **TLS** | done — 1.2/1.3 + mTLS | own OpenSSL state machine (`https`); **no STARTTLS**; validation only |
| **Identity / authz** | done — capability ACL + cert (`xymonacl.cfg`) | n/a for authz; only target-cert validation |
| **Multi-address / clustered** | partial — client→server fallback across addresses | **not done** — resolver keeps `h_addr_list[0]` only (deferred **P3e**) |
| **Framing (message boundaries)** | done — `size:N` length prefix | per-protocol, hardcoded flags (`TCP_GET_BANNER`/`TCP_SSL`) → declarative (#123) |
| **Service / protocol catalog** | n/a | `protocols.cfg` + compiled-in `http`/`https` → `services.cfg` (#123) |
| **Inter-test dependencies** | minor | 6 disjoint mechanisms → one primitive (#195) |

## 4. Where the open questions land

- **Transport / IPv6 / UDP / STARTTLS** → the shared layer → **unify on tcplib**
  (branch `split/08-prober-on-tcplib`). One mechanism, both contexts.
- **Multi-address / clustered hosts** → the one topic that **straddles** the
  layers: the *mechanism* is transport (resolve → keep the full list → iterate),
  but the *policy* differs by context —
  - bus = "any address that works" (failover),
  - probe = "test **all** / round-robin / aggregate the cluster" (P3e + cluster
    semantics in `services.cfg`).
  This is why it keeps resurfacing across questions: it sits on the seam.
- **Framing / response semantics / service catalog** → probe-specific → **#123**.
- **Status dependencies** → **#195** (mostly network tests, but cross-cutting).
- **Identity / sender authorization** → bus-specific → already done (ACL + mTLS).

## 5. The size:N case study (why the principle matters)

`size:N\n` is a **length-prefixed framing** added because TLS makes the classic
read-to-EOF delimiting unreliable (records sit buffered inside OpenSSL). It lives
in `xymond.c` on the bus read path and is **not gated by encryption** — the
server accepts it on plaintext too, but the client only emits it under TLS.

It must **never** leak into probes: a remote SMTP/HTTP server speaks its own
protocol and would not understand a `size:` header. The probe-side equivalent of
"where does a message end" is per-protocol (SMTP banner + CRLF, HTTP
Content-Length/chunked, DNS-over-TCP 2-byte prefix, one datagram = one message)
— declarative config (#123), not a universal `size:N`.

## 6. Naming — discovery vs identity (DNS is not identity)

A remote machine has a **real name** (the identity you/it asserts). DNS — and
especially **reverse DNS (PTR)** on cloud/DHCP networks — hands out **arbitrary,
auto-generated** names that need not match it
(`ec2-203-0-113-7.compute.amazonaws.com`, `host-..-dyn.isp.net`). So DNS names
are a *discovery* signal, never an *identity*. Split the two layers cleanly:

```
DISCOVERY / CORRELATION   <- forward DNS  +  reverse DNS (aliases) , forward-confirmed (FCrDNS)
        |  (suggests, proposes, correlates -- does NOT prove)
        v
IDENTITY / AUTHORIZATION  <- address (where)  +  cert CN (who, cryptographically proven)
                             never decide trust on a discovered name
```

**Reverse DNS is genuinely useful — at the discovery layer.** From an address it
surfaces the name(s)/aliases an operator published, which is more than cosmetic:

| Use case | How reverse DNS helps |
|---|---|
| **Dedup** | monitoring `web.corp` and `www.corp` → PTR shows both are `web01` → same machine → avoid double-counting; candidate for a dependency (#195) |
| **Cluster member naming** (mode B, round-robin) | `web.example` → `10.0.0.1, 10.0.0.2` → PTR → `web01`, `web02` → name members instead of "address #1/#2" |
| **Ghost / auto-discovery** | an unknown IP reports in → PTR suggests a name to add to `hosts.cfg` |
| **Alias discovery** | an IP with several PTRs → discover the machine's alternate names |

**But validate before trusting — forward-confirm (FCrDNS):**
`IP → PTR → name → forward → does it resolve back to the IP?` If yes, the alias is
coherent; if not, it is an arbitrary name usable for **display only**.

**The boundary:**
- The **bus / ACL** authenticates by **IP/CIDR** (where the packet comes from) or
  **`cert:<id>`** (the verified cert CN — the *proven* real name), **never** by a
  PTR lookup (`acl.c` does `inet_pton`/`prefix_match`, not `gethostbyaddr`).
- The **hosts.cfg hostname** is *your label*, deliberately decoupled from DNS
  (`testip`/static IP → the name need not exist in DNS at all; `0.0.0.0` → you
  opt into DNS resolution). Xymon's identity for a host is not dictated by DNS.
- Reverse DNS may **inform** config (propose names, group aliases, name cluster
  members) but must not **decide** authorization.

**Rule of thumb:** *DNS (forward + reverse) = discovery; address + cert =
identity.* Discovery proposes; identity decides.

## 7. Recommendations

1. **Unify exactly one thing: the transport.** tcplib is dual-stack, TLS-capable
   and DGRAM-capable; `contest.c` duplicates all of it. Migrating the prober's
   transport onto tcplib's `conn_*` API (the `08` stub) delivers IPv6 + TLS +
   STARTTLS + UDP + multi-address **once**, to both contexts.
2. **Keep everything above the transport context-specific.** Do not generalize
   `size:N` or the sender ACL to probes.
3. **Solve multi-address at the transport, branch the policy above it.** Store
   the full address list once; let the bus pick failover and the probe pick
   test-all/round-robin (P3e).
4. **Sequence the big remaining work above a unified transport.** #123
   (catalog/framing/cluster) and #195 (dependencies) both become materially
   simpler once the prober rides tcplib — do `08` first.

## 8. Artifact index

| Artifact | Layer / context | What it covers |
|---|---|---|
| `split/01-acl` | bus / identity | capability-based v4/v6 sender ACL |
| `split/02-xymonnet-ipv6` | probe / transport | v6 prober (own engine) + hosts.cfg v6 literals |
| `split/03-client-ipv6` | bus / transport | client getaddrinfo connect |
| `split/04-server-ipv6-plaintext` | bus / transport | tcplib engine (TLS dormant) |
| `split/05-tls` | bus / TLS | xymon_tls + mTLS |
| `split/06,07-integration-*` | bus / wiring | build glue + daemon wiring (listener, ACL-check, `size:N`, TLS) |
| `split/08-prober-on-tcplib` | **shared transport** | RFC stub: migrate prober onto tcplib (`docs/prober-on-tcplib.md`) |
| issue #123 | probe / framing+semantics | declarative service catalog; clustered hosts; framing |
| issue #195 | dependencies | unify the 6 "depends" mechanisms |
| plan **P3e** | shared transport / probe policy | multi-address + ordered v4↔v6 fallback |
