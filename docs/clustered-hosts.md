# RFC — Clustered hosts & multiple DNS records (everything on `conn`)

> **Status:** design RFC (no code yet). Proposes how to monitor a host that has
> **several addresses** — a static cluster, a round-robin DNS name, or a
> dual-stack machine — by making the **`conn` test the single declarative anchor**
> for a host's addressing, with an evolved argument grammar.
> **Relates to:** issue #123 (candidate "better support for clustered hosts /
> multiple DNS records"), plan phase **P3e** (multi-address), and
> `docs/architecture-network-contexts.md` (the two-context / discovery-vs-identity
> framing this builds on).

## 1. Problem

Today Xymon tests **one** address per host: the resolver keeps only
`h_addr_list[0]` (`xymonnet/dns.c:120`), `ares_gethostbyname(..., AF_INET, ...)`
is v4-only, and `ip_to_test()` (`xymonnet/xymonnet.c:864`) returns a single IP.
A host behind round-robin DNS, a load-balanced cluster, or a dual-stack machine
cannot be fully monitored — the other addresses are invisible.

## 2. Design principles (inherited)

1. **Name and IP are decoupled.** The hosts.cfg hostname is a *label*, not
   necessarily a DNS name. `0.0.0.0` in the IP column opts into DNS resolution;
   a static IP (with `testip`) means the name need not exist in DNS at all
   (`ip_to_test()` logic). This split must be preserved.
2. **DNS is discovery, not identity.** Forward/reverse DNS may *name* members
   (forward-confirmed, FCrDNS) but never *decides* anything. See the architecture
   note, section 6.
3. **`conn` is already the reachability anchor.** It is the special, default-on
   `pingtest` that `route:` and `IPTEST_2_CLEAR_ON_FAILED_CONN` already key off.
   Making it the carrier of the addressing model is idiomatic, not novel.
4. **Backward compatible.** A bare `conn` and a single-address host behave
   exactly as today; every new behaviour is opt-in via arguments.

## 3. Phasing — phase 1 is evolved `conn` args only

To keep the first implementation contained, **phase 1 uses only the evolved
`conn` arguments**. Addresses come from **DNS** (`resolve=all`); the column-1
grammar is **not** touched. This delivers the most common real cluster —
round-robin DNS and dual-stack hosts — while changing the smallest surface (the
`conn`-spec parser plus keeping the full `h_addr_list`).

| Phase | What | Address source | Parser surface |
|---|---|---|---|
| **Phase 1 (this RFC's MVP)** | evolved `conn:` args — policy/thresholds, family, resolve, report | **DNS** (`0.0.0.0`, `resolve=all`) | `conn`-spec parser + `dns.c` keep-all |
| **Phase 2 (deferred)** | static enumerated members in column 1 | **column-1 comma list** (`a,b,c`) | also `lib/loadhosts*.c` |

### Phase 1 — `0.0.0.0` (DNS): round-robin / multiple records

```
0.0.0.0   web   # conn:crit=ALL,resolve=all
```
Addresses come from DNS; one name → N A/AAAA records. `resolve=all` keeps the
whole `h_addr_list` instead of `[0]`. `testip` is **never** combined with
`0.0.0.0` (contradictory). Everything else (policy, thresholds, family, report)
is an evolved `conn` argument — see section 4. **This is the whole of phase 1.**

### Phase 2 (deferred) — static list in column 1: enumerated members

```
198.51.100.1,198.51.100.2,2001:db8::1   web   # testip conn:crit=ALL
```
A comma list in the IP column lets an admin enumerate members whose name is **not**
in DNS. It reuses the *same* `conn` argument grammar — only the address *source*
differs — so it is purely additive once phase 1 exists. **Out of scope for the
first cut**; documented here so the grammar is designed to accommodate it.

## 4. The evolved `conn` argument grammar (behaviour lives here)

**Phase 1 is the evolved, parametric `key=value` form only.** A bare keyword like
`all` is a *shorthand*, not an evolved arg — shorthands are a separate sugar layer
(below) and are **out of phase 1**. The engine parses only `key=value` items:

```
conn[:KV[,KV ...]]

KV :=
    crit '=' (J | ALL)               # red    if up-count < J          (default: 1)
  | warn '=' (K | ALL)               # yellow if up-count < K (>= J)    (default: = crit)
  | resolve '=' (first | all | N)    # how many DNS records to keep     (default: first)
  | family '=' (4 | 6 | auto | dual) # address family(ies) to test      (default: 4)
  | select '=' (parallel | rr)       # test all members, or round-robin (default: parallel)
  | report '=' (rollup | each)       # one column vs per-member detail  (default: rollup)
  | order '=' (v6,v4 | v4,v6)        # family preference (happy-eyeballs)
  | probe '=' (ping | TEST | none | off) # ping (default); TEST = an existing service test (http/ssh/..); none == "noping"; off == "noconn"
  | ondown '=' (red | yellow | clear)# colour when down; clear ~= the conn part of "dialup"  (default: red)
  | delay '=' N                      # conn-scoped slice of delayred=conn:N -- hold red until down for N
  | flap '=' (yes | no)              # conn-scoped slice of noflap -- flap detection on conn (default: yes)
```

`probe=none` is the old **`noping`**: no ICMP, but the conn column **and the
shared address model** survive (so `http`/`ssh` still inherit the members).
`probe=off` is the old **`noconn`**: no conn column at all — which also drops the
address model, so it is *not* for clusters. `ondown=clear` is only the **conn
part** of `dialup` (report a down host as clear, not counted as down); `dialup`'s
host-wide effects — all network tests clear, stale client statuses not going
purple — stay a host-level concern, not a conn arg. `delay` and `flap` are the
**conn-scoped slices** of the general per-column tags `delayred=`/`noflap`: they
configure only conn's own status quality and desugar to the general form (which
still works for every other column). Every behaviour is an explicit `key=value`;
there are **no bare policy words in phase 1**: "any" is `crit=1`, "all" is
`crit=ALL`, a quorum is `crit=2`, round-robin is `select=rr`.

### Service-based reachability (`probe=TEST`) and the dependency inversion

`probe` can also name an **existing service test** instead of ICMP:
`conn:probe=http` means *conn is green iff the `http` test succeeds*. This is the
long-standing need (issue #123, candidate 4 — "service-based reachability, ssh/http
instead of only ICMP") for hosts that firewall ping but answer a service. It is
**better than `noping`**, which only marks the column disabled: this gives a real
reachability signal.

It **inverts the usual dependency**, which must be handled:

```
normal:       http  --depends on-->  conn      (conn down  => http clear)
probe=http:   conn  --depends on-->  http      (the arrow flips)
```

So when `conn:probe=http`:
- the probe test (`http`) becomes the **reachability root** and is **exempt** from
  the implicit "every test depends on conn" rule — otherwise `http -> conn -> http`
  is a cycle;
- evaluation order is **`http` -> `conn` -> the other tests**;
- the other tests still depend on conn (now http-derived): if http is down, the
  host reads unreachable and they go clear.

This is a `conn` arg (it configures how conn is *measured*) that **generates a
dependency edge** `conn -> http`; resolving the exemption, the ordering and the
acyclicity is the **#195** concern (its "evaluation order & cycles" hard point).

**One probe test only in phase 1.** Deriving conn from several (`probe=ssh,http`)
is possible by reusing `crit` over the probe set, but it conflates that set with
the address-member set (also governed by `crit`) and multiplies dependency edges —
**deferred as advanced/questionable**.

### Graded thresholds — the key gain

Up-count is the number of members that responded. Colour is a *graded* function
of it, mapped onto Xymon's green/yellow/red:

```
conn:crit=2,warn=3      # GREEN if >=3 up, YELLOW if exactly 2, RED if <2
```

A cluster can be **degraded (yellow)** before it is **down (red)** — something a
plain up/down policy cannot express. This is *the* reason phase 1 is the
`key=value` form and not the shorthands.

### Shorthands — sugar, NOT phase 1 (deferred)

A later convenience front-end may desugar bare keywords to the `key=value` core.
These are **not** evolved args and are **not** implemented in phase 1:

| Shorthand | Desugars to (the actual phase-1 form) |
|---|---|
| `conn:any` | `conn:crit=1` |
| `conn:all` | `conn:crit=ALL` |
| `conn:2` | `conn:crit=2` |
| `conn:2/3` | `conn:crit=2` (expected=3) |
| `conn:rr` | `conn:select=rr` |
| `noping` | `conn:probe=none` (no ping, column kept) |
| `noconn` | `conn:probe=off` (no conn column; drops the address model) |
| `dialup` | `conn:ondown=clear` (conn part only — see section 8) |
| `delayred=conn:N` | `conn:delay=N` |
| `noflap` (on conn) | `conn:flap=no` |

## 5. Worked examples

Phase 1 (DNS source only):

```
# Round-robin DNS, dual-stack, quorum with graded warning
0.0.0.0   web   # conn:crit=2,warn=3,resolve=all,family=dual,report=each

# Round-robin DNS, all records must be up, per-member detail
0.0.0.0   web   # conn:crit=ALL,resolve=all,report=each http

# Happy-eyeballs single host (not a cluster -- just dual-stack)
0.0.0.0   app   # conn:crit=1,family=auto,order=v6,v4

# Service-based reachability: host firewalls ping, so judge conn from http
0.0.0.0   web   # conn:probe=http http
```

Phase 2 (static column-1 list — deferred):

```
# Failover pair, members not in DNS: green as long as one is reachable
198.51.100.1,198.51.100.2   lb   # testip conn:crit=1

# Static cluster, all members must be up, per-member detail
198.51.100.1,198.51.100.2,198.51.100.3   web   # testip conn:crit=ALL,report=each http
```

## 6. Status column behaviour

Default is **B1 — `conn` becomes cluster-aware**: one `conn` column, colour =
the graded threshold result, members listed in the status body:

```
yellow  web  conn   2 of 3 members up (warn<3)
        • 198.51.100.1 (web01)  OK    0.4 ms
        • 198.51.100.2 (web02)  OK    0.5 ms
        • 2001:db8::1  (web03)  FAIL  no route
```

`report=each` emits the per-member lines explicitly. Member names come from
forward-confirmed reverse DNS where available, else the address.

Later evolutions (out of scope here): **B2** a dedicated `cluster` status column;
**B3** per-member sub-statuses with their own history/RRD/alerting.

## 7. Inheritance & per-test override

- **Address set + family** are host-level: every test (`http`, `ssh`, …) sees the
  same members.
- **Policy** defaults to **`crit=1`** ("any") for non-`conn` tests (a service
  usually works via any one member behind a LB), overridable per test where the
  grammar is clean (`http:crit=1`, `ssh:8022:crit=ALL`). `conn` carries the
  authoritative cluster policy.

```
0.0.0.0   web   # conn:crit=ALL,resolve=all  http   # conn: all members ping; http: any member serves
```

## 8. Related legacy tags: `noping` / `noconn` / `dialup` (and `multihomed`)

Several existing reachability tags fold into the same `conn` spec — but with the
**exact** legacy semantics, which differ in ways worth pinning down:

- **`noping`** → **`conn:probe=none`**. The man page: *"disables the ping-test,
  but keeps the conn column"*. The column **and the shared address model** stay,
  so `http`/`ssh` still inherit the members. **This is the right form for "define
  the cluster, don't ping."**
- **`noconn`** → **`conn:probe=off`**. *"disables the conn column entirely."*
  This also drops the conn-borne address model, so it is **not** for clusters —
  it is the genuine "no reachability column" case.
- **`dialup`** → **`conn:ondown=clear`** *for the conn part only*. The real
  `dialup` is host-wide: *all* network tests go clear on failure **and** stale
  client statuses (cpu/disk) do not go purple. `ondown=clear` expresses the conn
  colour demotion; the host-wide and purple-suppression effects remain a
  host-level concern (out of scope here).

```
# noping in the new args: no ping, but the cluster is still defined for http
0.0.0.0   web   # conn:probe=none,resolve=all,family=auto,report=each http

# dialup (conn part) combinable with a cluster policy
0.0.0.0   laptop   # conn:crit=ALL,ondown=clear
```

**`multihomed`** is the **bus-side** reading of the *same* fact this RFC makes
explicit: a host has several addresses. Today it is a manual flag that suppresses
the "same host, different source IP" warning when client data arrives from any of
them. It should not be a separate flag *and* a separate cluster concept: once the
host's address set is declared (column-1 list, or `conn:resolve=all`), Xymon
**should derive `multihomed` from it** — declaring the members is exactly the
statement that inbound data may come from any of them. Same "one host, many
addresses" model, read by Context 1 (the bus) and Context 2 (the probes) alike —
see `docs/architecture-network-contexts.md`. It is not a `conn` arg (it is
bus-side), but it is not independent data either.

### What is a `conn` arg, and what is the dependency layer (→ #195)

A `conn` arg configures **conn's own** behaviour: how to probe (`probe`), how to
colour *conn itself* when down (`ondown`), `delay`, `flap`, and the addressing.
Everything else here is the **dependency layer** and belongs to #195 — not to
`conn` args:

- **Implicit: every test depends on the local conn.** When a host is down its
  other statuses are demoted, so you see *one* red on `conn` instead of a sea of
  red/purple: network tests → clear (`IPTEST_2_CLEAR_ON_FAILED_CONN`), stale
  client statuses → clear instead of purple. **`noclear` and `dialup` are just two
  settings of this one built-in dependency** — `noclear` forces the client
  statuses *purple*, `dialup` forces *everything* clear; same dimension, not
  separate tags. (`ondown` is the only slice that is a `conn` arg, because it
  colours conn *itself*.)
- **Explicit: conn can depend on a remote conn.** conn does not depend on itself,
  but it can depend on *another host's* conn: `route:` (my ping failure attributed
  to a *named* router that is also down) and `depends=` (any test's colour
  conditioned on another *named* host/test).
- **Explicit: conn can depend on a local service.** `conn:probe=TEST` (section 4)
  derives conn from a local service test and so **generates the edge `conn ->
  TEST`** — a `conn` arg that produces a dependency #195 must order and keep
  acyclic (the arrow inverts the usual "service depends on conn").

Both — the implicit local-conn dependency (with its `noclear`/`dialup` knobs) and
the explicit named dependencies (`route:`/`depends=`) — are the "how one status
conditions another" axis that **#195** unifies. This RFC does **not** treat them;
folding any into `conn` args would re-fragment that model. The bare legacy tags
all remain accepted as shorthands (section 4).

## 9. Mapping to services.cfg (#123)

Per-service-type **defaults** live in `services.cfg`; `hosts.cfg` overrides per
host. Same division as #123 (catalog = reusable defaults, hosts.cfg = inventory):

```
# services.cfg
[conn]
  ip { family auto; resolve all; policy any }
[www]
  ip { policy any }          # a web service is fine via any member
```

## 10. Code touch points

| Phase | Change | File |
|---|---|---|
| **1** | Parse the evolved `conn:` spec (policy/thresholds/family/resolve/report/order) | `xymonnet/xymonnet.c` (tag/option parser, near the `:port`/`:s` handling) |
| **1** | Keep the full `h_addr_list`, both families, per `resolve=`/`family=` | `xymonnet/dns.c:120,208` |
| **1** | `ip_to_test()` → return/iterate an address **list** instead of one IP | `xymonnet/xymonnet.c:864` |
| **1** | Iterate members, count up, apply graded threshold, build body | the test loop (cleanest once the prober rides tcplib — see `docs/prober-on-tcplib.md`) |
| **2** | Parse a comma list in the IP column → address array | `lib/loadhosts*.c` |

Phase 1 deliberately touches neither `lib/loadhosts*.c` nor the column-1 grammar.

## 11. Open questions

- `rr` (round-robin) + history: does each cycle's member rotate the column, or do
  we need B3 per-member history to make `rr` meaningful?
- `N/M` "expected" count: derived from the column-1 list length, or explicit?
- Per-test policy grammar for URL/content tests (`http://`, `cont;…`) where `:` is
  taken — likely host-level default only.
- Should `family=dual` count v4 and v6 of the *same* machine as two members for
  threshold purposes, or as one with a sub-detail?
