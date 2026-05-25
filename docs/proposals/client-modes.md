# Study: Xymon client modes — 1, 2, or 4 variants?

Status: **Draft / design study** — analysis and a recommendation, no code.

## The question

The Xymon client today effectively ships in ~**2** build flavours:

- a lean **collector** (server does the analysis), and
- a **local-analysis** client (on-host analysis, needs PCRE).

Should it instead be **4** variants (the full matrix), or **1** unified client
that accepts **both axes at runtime** — local *or* remote **config**, and local
*or* remote **analysis**?

## The two axes

The client's behaviour is the cross-product of two independent choices:

| Axis | "remote" | "local" | Decided at |
|------|----------|---------|------------|
| **Config / rules source** | pulled from the server (`client-local.cfg` is pushed back to the client) | a file on the host (`localclient.cfg`) | **runtime** |
| **Analysis (the calculus)** | the **server** computes status from raw data | the **host** computes status itself (PCRE rules) | build (PCRE) **+** runtime flag |

Cross-product = **4 modes**:

| # | Config source | Analysis | Character |
|---|---------------|----------|-----------|
| 1 | remote (server) | remote (server) | classic centrally-managed collector |
| 2 | local | remote (server) | collector, host controls *what* is collected |
| 3 | remote (server) | local (host) | host self-judges, collection governed centrally |
| 4 | local | local (host) | fully autonomous node |

## Why **4 build variants** is the wrong answer

These are two **orthogonal runtime axes**, not four products:

- The **config-source** axis is already **pure runtime** — the *same* binary
  uses a pushed `client-local.cfg` if present, else a local file. No build
  difference, and it applies to every mode.
- Shipping 4 builds models runtime configuration as compile-time products. It
  explodes combinatorially (add a third option to either axis → 6, then 8 …) and
  forces a reinstall to change behaviour that is really just config.

So 4 should be rejected on principle.

## Why it *looks* like **2** today

There is exactly **one** thing that is compile-time: **PCRE**. On-host analysis
needs PCRE linked in, and `configure.client` only links it when you choose
client-side config (`CONFTYPE=client`). That single build dependency is the
*entire* reason "local analysis" feels like a separate client. Drop that gate
and the analysis axis becomes runtime too.

## The **1-client** answer (recommended)

**Always compile the client with PCRE.** Then *both* axes are runtime:

- analysis location → a runtime flag (`--local` / not),
- config source → already runtime (pushed vs local file).

⇒ **one binary** that accepts any combination — local **or** remote config,
local **or** remote analysis — i.e. all four modes selectable at runtime, with
**zero build variants** and no reinstall to switch.

```
# all four modes from one client, chosen by flags/config:
xymonlaunch ... xymonclient            # remote analysis (collector)
xymonlaunch ... xymonclient --local    # local analysis
#   + config from local file  OR  pushed client-local.cfg  (runtime, either mode)
```

### Trade-off

| | 1 unified (always-PCRE) | 2 variants (status quo) | 4 variants |
|---|---|---|---|
| Build artifacts | **1** | 2 | 4 |
| Switch mode | runtime / config | reinstall to add local | reinstall |
| Models runtime as build? | no | partly (PCRE) | yes (wrong) |
| Cost | every client links `libpcre2` (~a few 100 KB) | lean collector default | combinatorial sprawl |
| Mental model | simplest | "which client did I install?" | worst |

The **only** cost of the 1-client design is that a pure collector also links
`libpcre2`. That is a small price for one artifact and runtime-selectable modes.

## Recommendation

1. **Software / upstream:** converge on **one client**, always PCRE-capable, with
   both axes as runtime choices. Optionally keep a `configure` switch
   (`--without-pcre`) for genuinely minimal builds, but **default to included** so
   the shipped client can do everything.
2. **Packaging (MacPorts, distros):** *may* still offer a lean no-PCRE collector
   as the default plus an opt-in PCRE build — but treat that as a **downstream
   size optimization**, not the software's design. The program itself should be
   the single flexible client.

This answers the question directly: not 4 (runtime axes ≠ products), and not
really 2 (an artifact of PCRE gating) — aim for **1 client that accepts local or
remote for both config and analysis**, with the 2-way packaging split kept only
as an optional optimization.

## Downstream note (separate idea)

Because mode 3/4 put the verdict on the host, the local-analysis client is also
the natural home for an *optional, guarded* **corrective action** ("self-heal on
red"). Worth noting that this reuses the same trigger primitive Xymon already has
(a scripted alert recipient is "status → run code"), and a host-local trigger is
actually **less** remotely spoofable than a server-side alert script. That is a
distinct feature proposal, out of scope for this modes study; recorded here only
as something the unified local-capable client unlocks.

## Open questions

- Is the `libpcre2` size cost ever large enough to justify keeping a separate
  lean collector build at all?
- Can local analysis degrade gracefully (no pattern rules) if PCRE is absent, so
  even a no-PCRE build still runs `--local` for non-regex checks?
- Migration: how to converge today's split into one client without breaking
  existing `CONFTYPE=server` installs.
