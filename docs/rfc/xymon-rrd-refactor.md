# RFC: Xymon ↔ RRDtool — Architecture Study and Refactor Roadmap

**Status:** Draft — study branch, not implementation
**Branch:** `study/xymon-rrd-refactor`
**Scope:** Exploratory analysis of how Xymon currently uses RRDtool, the
limitations this creates, and what a modernization would cover. This
document is an RFC, not a PR; it captures findings, design choices and
trade-offs for future implementation work.

---

## 1. Executive summary

Xymon's relationship to RRDtool follows a clear split:

- **Xymon = orchestrator**. It routes status messages, picks an RRD
  handler per test, parses messages, decides which graph to render
  for which column, and constructs `rrd_*()` arguments.
- **librrd = engine**. It creates RRD files, runs the round-robin
  consolidation, evaluates RPN expressions (CDEF/VDEF), and renders
  the PNG.

This split works but Xymon exploits roughly **30% of librrd's
capabilities**. The remaining 70% is reachable in theory but blocked by
hardcoded RRA layouts, fixed output format (PNG only), no
cross-host CDEF, no caching, and no advanced analytics surface.

This document maps the current architecture, lists the limitations
encountered while integrating devmon and exploring smokeping-style
rendering, and proposes a phased roadmap.

---

## 2. Current state — how Xymon uses RRD

### 2.1 The two pipelines

```
COLLECT pipeline                 RENDER pipeline
================                 ===============

client status                    user clicks column
      │                                │
      ▼                                ▼
xymond receives                  svcstatus.cgi
      │                                │
      ▼                                ▼
xymond/do_rrd.c                  lib/htmllog.c
  dispatcher                       picks gdef(s)
      │                                │
      ▼                                ▼
xymond/rrd/do_*.c                showgraph.cgi
  ~40 handlers                     load_gdefs()
      │                            expand_tokens()
      ▼                            build rrdargs[]
create_and_update_rrd()                │
      │                                ▼
      ▼                            rrd_graph()
rrd_create() / rrd_update()        ── librrd ──
   ── librrd ──                        │
      │                                ▼
      ▼                            PNG output
$XYMONVAR/rrd/<host>/*.rrd
```

### 2.2 Files involved

| File | Role |
|---|---|
| `xymond/do_rrd.c` | Dispatcher: `strcmp(id, "...")` routes to handler |
| `xymond/rrd/do_*.c` | ~40 handlers (one per test/data type) |
| `lib/xymonrrd.c` | `find_xymon_rrd`, `find_xymon_graph`, `xymon_graph_text` (URL prefix logic) |
| `lib/htmllog.c` | `generate_html_log` — picks which graphs to include on a column page |
| `web/showgraph.c` | `load_gdefs`, `expand_tokens`, the actual `rrd_graph()` call |
| `web/svcstatus-trends.c` | Trends column aggregation (uses `XMH_TRENDS` from hosts.cfg) |
| `xymond/etcfiles/xymonserver.cfg.DIST` | `TEST2RRD`, `GRAPHS`, `GRAPHS_<service>` env vars |
| `xymond/etcfiles/graphs.cfg` | gdef sections (~110 by default) |

### 2.3 Configuration variables

- **`TEST2RRD`** (string list): column → mapped rrd name. e.g. `cpu=la`
  means the "cpu" column displays "la" graphs.
- **`GRAPHS`** (string list): rrd entries with optional partname and
  maxgraphs. Format: `name[:partname[:maxgraphs]]`.
- **`GRAPHS_<column>`** (env var per column): override list of graphs
  to display on a specific column's page. Documented in
  `xymonserver.cfg.DIST` but not enabled by default.
- **`TRENDS:`** (hosts.cfg per-host): override gdef list for the
  trends column. **Only affects the trends column, not individual
  column pages.**

### 2.4 The `@VAR@` placeholders (Xymon-specific)

Pre-substituted before `rrd_graph()` is called:

- `@RRDFN@` — actual filename in the iteration
- `@RRDIDX@` — index (1, 2, 3...)
- `@COLOR@` — color from palette
- `@RRDPARAM@` — captured group from `FNPATTERN`
- `@STACKIT@` — stack modifier for some templates

These are **not** RRDtool syntax. They are expanded in
`web/showgraph.c:expand_tokens()` before the strings are passed to
librrd.

### 2.5 File naming on disk

```
$XYMONVAR/rrd/<hostname>/<basename>[.<entity>].rrd
```

Examples:

- `la.rrd` (one file for load average)
- `disk,root.rrd`, `disk,var.rrd` (one per filesystem; comma replaces /)
- `temperature.cpu1.rrd` (one per sensor, when handled by do_temperature_rrd)
- `dm_temp.cpu1.rrd` (when handled by do_devmon_rrd with marker name `dm_temp`)

### 2.6 The DEVMON marker mechanism (relevant to current work)

Status payloads from devmon-style collectors carry blocks like:

```
<!--DEVMON RRD: dm_temp 0 0
DS:val:GAUGE:600:U:U DS:lt:GAUGE:600:U:U DS:ht:GAUGE:600:U:U
cpu1 45:0:80
ambient 25:0:50
-->
```

The marker drives **two distinct consumers**:

| Consumer | Uses |
|---|---|
| `xymond/rrd/do_devmon.c` | Full block: name → file basename; DS schema; data → samples |
| `lib/htmllog.c` (after the in-progress PR) | Only the first token (`dm_temp`) → graph definition lookup |

The associated PR (branch `fix/devmon-auto-graphs-main`) extends
`lib/htmllog.c` to parse these markers and render one graph per
unique marker name, plus a `<!--DEVMON GRAPH:-->` variant for
non-data alias markers (graph-only, no RRD file written).

---

## 3. Identified limitations

For each limitation: what RRDtool offers, what Xymon currently does, and
how this constrains real use cases.

### 3.1 Hardcoded RRA layouts (no custom retention)

- **RRDtool offers** custom RRA configuration: arbitrary combinations
  of resolution × duration × consolidation function per file.
- **Xymon does** each handler in `xymond/rrd/do_*.c` hardcodes its
  RRA list. Most files have identical RRA layouts (e.g., 5-min step,
  ~2 year retention).
- **Constraint** users cannot keep high-resolution data for short
  windows or extend long-term archives without patching handlers.
  Capacity planning at year+ scale is awkward.

### 3.2 Holt-Winters forecasting and anomaly detection unused

- **RRDtool offers** `HWPREDICT`, `SEASONAL`, `DEVPREDICT`,
  `DEVSEASONAL`, `FAILURES` RRA types. These build a predicted
  series and flag values that fall outside the predicted band.
- **Xymon does** no handler enables these RRA types.
- **Constraint** anomaly detection is delegated to client-side
  thresholds (`analysis.cfg`). Time-of-day / time-of-week
  seasonality must be encoded manually rather than learned from
  the data.

### 3.3 CDEF/VDEF underused in stock graph definitions

- **RRDtool offers** ~40 RPN operators (arithmetic, comparison, math,
  statistical, trending, time-based). VDEF reductions (PERCENTNAN,
  LSLSLOPE, etc.) for scalar values in GPRINT.
- **Xymon does** the stock `graphs.cfg` uses near-trivial CDEFs
  (mostly unit conversions). No trending lines, no predicted bands,
  no percentile shading, no smoke rendering, no comparative
  (time-shifted) views.
- **Constraint** modern visual practices require admins to write
  custom gdefs from scratch. No discovery path from the stock
  configuration.

### 3.4 FNPATTERN scope is per-host

- **RRDtool offers** `rrd_graph` can read from any number of files at
  arbitrary paths, including different hosts.
- **Xymon does** `web/showgraph.c` only looks for files in
  `$XYMONVAR/rrd/<requested-host>/`. The `FNPATTERN` matches against
  basenames in that single directory.
- **Constraint** cross-host aggregated views ("total bandwidth for
  all routers") require external scripting. Multi-host CDEFs cannot
  be expressed in `graphs.cfg`.

### 3.5 PNG-only output

- **RRDtool offers** PNG, SVG, EPS, PDF via `rrd_graph`. Separately,
  `rrd_xport` for XML/JSON data extraction.
- **Xymon does** hardcodes `-a PNG` in the `rrd_graph` argv build.
  No SVG output, no JSON/CSV data export endpoint.
- **Constraint** no integration path for modern web dashboards
  (D3.js, Vue, React). Browsers must re-fetch a new PNG on every
  pan/zoom action. Vector graphics for accessibility / scaling are
  unavailable.

### 3.6 No PNG / data caching

- **RRDtool runtime** `rrd_graph` re-parses RRA bands and renders the
  PNG on every call. For high-traffic Xymon servers this is
  significant CPU.
- **Xymon does** no caching layer between showgraph.cgi and the
  filesystem. Each browser request triggers a full render.
- **Constraint** at scale (10k+ hosts) the server becomes
  graph-rendering-bound during status page browsing.

### 3.7 rrdcached not default

- **RRDtool offers** `rrdcached` batches writes for high-write workloads.
- **Xymon does** supports `rrdcached` via the `XYMONRRDREADY` env var
  but it is not enabled out of the box, and the integration is
  optional.
- **Constraint** large installations must configure this themselves
  with no in-tree documentation, and miss the IO savings.

### 3.8 Time zone is process-wide

- **RRDtool offers** `--timezone` per graph for rendering in a
  different TZ from the server.
- **Xymon does** all graphs render in the server's TZ.
- **Constraint** globally distributed teams see times in a TZ that
  may not be their own.

### 3.9 SHIFT (temporal comparison) absent from stock gdefs

- **RRDtool offers** `SHIFT` operator to time-shift a series for
  comparison ("this week vs same period last week").
- **Xymon does** no stock gdef uses SHIFT. No UI controls to
  activate temporal comparisons.
- **Constraint** "is today worse than usual" is a manual exercise.

### 3.10 Multi-axis / log axes not in stock

- **RRDtool offers** Y-axis log scale, right-side secondary axis,
  unit suffixes.
- **Xymon does** linear single-axis only in stock gdefs.
- **Constraint** mixing wildly different magnitudes (e.g., Mbps +
  errors/s) requires writing custom gdefs.

### 3.11 Test data discovery is single-handler

- **RRDtool offers** files can be referenced by any name from
  anywhere.
- **Xymon does** each test name strictly maps to one handler via the
  `do_rrd.c` dispatcher. Adding a new test type means adding a new
  handler (C code).
- **Constraint** novel data formats either ride on `do_devmon_rrd`
  (the only generic handler accepting arbitrary DS schemas via
  markers) or require kernel code changes.

---

## 4. Case study — devmon integration

Devmon is an SNMP collector that produces Xymon status messages
containing `<!--DEVMON RRD:-->` markers. It's the most flexible
existing "generic data" path into Xymon RRD storage. Several findings
from working through its integration:

### 4.1 The marker format is a dual-purpose payload

A single marker carries data for two consumers:

- **`do_devmon_rrd`** parses the entire block: marker name → file
  basename; DS schema line → file creation; data lines → samples to
  insert with `rrd_update`.
- **`lib/htmllog.c`** (with the in-progress PR) parses only the
  marker name → graph definition lookup.

The split is clean: the data line layout is irrelevant for
rendering; the marker name is irrelevant for data storage (it's just
the file basename). Each consumer ignores what doesn't concern it.

### 4.2 The legacy TEST2RRD `=devmon` indirection

Upstream defaults configure `temp=devmon` and `if_load=devmon` in
TEST2RRD. This routes the "temp" column through the URL prefix
mechanism `devmon:temp` in `xymon_graph_text`, relying on showgraph's
fallback chain to find a `[devmon]` catch-all gdef in graphs.cfg.

Problems with this approach:
- It requires a `[devmon]` gdef in graphs.cfg which is not in the
  upstream default (only present in devmon's own
  `extras/devmon-graphs.cfg`).
- It loses the per-marker granularity: every devmon-produced metric
  goes through the same gdef.
- For non-devmon installations using the bundled "temp" plugin
  (hobbit-plugins), the indirection hijacks the column.

The current PR replaces this with **marker-driven gdef selection**:
each marker name maps to a same-named gdef in graphs.cfg (with a
fallback to the column's mapped gdef when the per-marker entry is
absent).

### 4.3 Template-driven graph naming

Devmon templates use `name:<NAME>` inside the `rrd=` directive of
`TABLE:` blocks. The convention naturally supports per-device-type
graph variants:

```
# In var/templates/cisco-router/temp/message
TABLE: rrd=name:dm_temp_cisco;DS:val:cpuTemp;...

# In var/templates/dell-server/temp/message
TABLE: rrd=name:dm_temp_dell;DS:val:idracTemp;...
```

Each device emits a different marker name → different gdef applied
→ different visual rendering, all on the same `temp` column UI-side.

The current PR (`lib/htmllog.c` extension) is the upstream piece that
makes this work.

### 4.4 The DEVMON GRAPH alias marker

Without an alias mechanism, getting "two views of the same RRD
fileset" requires either:
- Emitting two markers with two different `rrd=` lines (two filesets,
  duplicated data on disk), or
- Using `GRAPHS_<service>` env var (global override, no per-host
  variance).

The current PR adds support for a graph-only marker:

```
<!--DEVMON GRAPH: dm_temp_summary dm_temp 0 0-->
```

This declares: render the `[dm_temp_summary]` gdef using files from
`dm_temp.*.rrd`. No new RRD file is created (do_devmon_rrd ignores
the marker because the prefix doesn't match `<!--DEVMON RRD:`).

The corresponding `[dm_temp_summary]` gdef in graphs.cfg has a
`FNPATTERN` pointing to `dm_temp\.(.+)\.rrd` files, with different
DEF/CDEF/LINE/AREA expressions for the alternative view.

This is the **one-fileset, multiple-gdef** approach (option II), made
explicit in the marker stream.

---

## 5. Case study — smokeping-style integration

Smokeping is a separate tool by the same author as RRDtool that
specializes in latency monitoring with "smoke" rendering. Studying
its `Smokeping::probes::FPing` Perl probe and the related RRD layout
reveals what would be needed for an equivalent in Xymon.

### 5.1 Smokeping's data model

The probe runs `fping -C N` (N pings per cycle, e.g. 20), parses the
output, **sorts the RTTs**, but does **not** compute percentiles.
Each cycle stores all N values plus loss:

```
RRD schema: ping1, ping2, ..., pingN, loss, uptime
```

Percentile selection is done at graph time by picking specific
sorted-index DSes:

- `DEF:median=file.rrd:ping10:AVERAGE`     (10th of 20 sorted ≈ median)
- `DEF:p10=file.rrd:ping3:AVERAGE`         (3rd ≈ 10th percentile)
- `DEF:p90=file.rrd:ping17:AVERAGE`        (17th ≈ 90th percentile)

### 5.2 Why this is interesting

The approach trades **storage efficiency** for **analytical
flexibility**: any percentile can be queried at any time without
re-collecting data.

The smoke rendering uses CDEFs to compute differential bands between
percentiles, then stacks semi-transparent AREAs:

```
CDEF:band_p10_p25=p25,p10,-
CDEF:band_p25_p75=p75,p25,-
CDEF:band_p75_p90=p90,p75,-
AREA:p10#00000000               # transparent baseline
AREA:band_p10_p25#A0A0A040:STACK
AREA:band_p25_p75#A0A0A060:STACK
AREA:band_p75_p90#A0A0A040:STACK
LINE2:median#0000FF:Median
```

### 5.3 What would be needed in Xymon

To replicate Smokeping faithfully in Xymon (FPing probe only):

| Component | Implementation |
|---|---|
| Multi-ping collector | Shell script wrapping fping `-C N`, parsing output |
| Capability detection | Probe fping for `-S`, `-O`, `-k`, IPv4/IPv6 support |
| Blaze mode | Send N+1 pings, discard the first as outlier |
| Compatibility shim (pingfactor) | Auto-detect unit (ms vs s) |
| RRD storage | Reuse `do_devmon_rrd` with `<!--DEVMON RRD: smoke ...-->` markers and N+2 DS schema |
| Graph rendering | Add a `[smoke]` gdef in graphs.cfg with CDEF bands |

The collection side is ~500 lines of shell or Perl. The storage side
needs **zero Xymon C changes** if we reuse the existing devmon path.
The rendering side is purely a `graphs.cfg` addition.

### 5.4 What would NOT be covered by lifting RRD limits alone

Smokeping has additional features that aren't RRD-related:

| Feature | Belongs to |
|---|---|
| Multi-probe protocols (TCPPing, EchoPingHttp, DNS, etc.) | Probe framework |
| Distributed master/slave probing | Architecture |
| Configurable hierarchy (DC/site/host) | Configuration & UI |
| Interactive zoom (no PNG re-render) | Frontend & output format |
| Real-time push | Backend protocol |
| Sub-second probe intervals | Scheduler |

So even with all of RRD's potential exposed, Xymon would land at
**~60% of a state-of-the-art Smokeping replacement** for any
"distributed multi-probe" use case. The other 40% is Xymon
architecture work (collectors, frontend, distributed coordination),
not RRD work.

---

## 6. Refactor roadmap

Proposed phases, ordered by ratio of impact to risk.

### Phase 1 — Marker-driven gdef rendering (in progress)

Branch: `fix/devmon-auto-graphs-main`

- Parse `<!--DEVMON RRD:-->` markers in `lib/htmllog.c` and render
  one graph per unique marker name.
- Add fallback chain (marker → mapped gdef).
- Clean up legacy `temp=devmon`/`if_load=devmon` from upstream defaults.
- Ship a default `[temp]` graph definition in `graphs.cfg`.
- Support `<!--DEVMON GRAPH:-->` alias markers for one-fileset,
  multiple-gdef workflows.

**Status:** PR pending, 4 commits, ~190 lines net additions.

### Phase 2 — Configurable RRA per handler

- Introduce a `xymonrra.cfg` (or analogous) that lets handlers query
  for the RRA layout to use per test type.
- Default to the current hardcoded layout for backward compatibility.
- Admins can extend high-resolution windows or year-scale archives.

**Effort:** medium — touches ~40 `do_*_rrd.c` files and the create
path in `do_rrd.c`.

**Risk:** medium — existing RRD files keep their original RRA; only
new files get the new layout. Migration of existing files is a
separate concern (`rrdtool tune` / `rrdtool resize`).

### Phase 3 — SVG/JSON output options

- Add `&format=svg` / `&format=json` query parameters to `showgraph.cgi`.
- Pass `-a SVG` to `rrd_graph` for SVG; use `rrd_xport` for JSON.
- Maintain PNG as the default.

**Effort:** low — `~10 lines` in showgraph.c plus a content-type switch.

**Risk:** low — strict opt-in via URL parameter.

### Phase 4 — Server-side caching

- Memoize `(host, service, range, time_window)` → PNG/SVG output
  with a TTL aligned to the source RRD's step.
- Either in-process LRU or via `rrdcached`'s `--journal` and on-disk
  cache.

**Effort:** medium — wrap the `rrd_graph` call site.

**Risk:** medium — cache invalidation must handle ad-hoc updates and
new RRA flushes.

### Phase 5 — Holt-Winters / anomaly RRA opt-in

- Per-test config to enable HWPREDICT/SEASONAL RRAs.
- Add a generic anomaly indicator visible in the trends column.

**Effort:** medium — new RRA in the create path, new analysis hooks
to consume the FAILURES counter.

**Risk:** medium — HWPREDICT requires long warmup; first weeks of
data are noisy.

### Phase 6 — Cross-host FNPATTERN

- Extend FNPATTERN scope: allow gdef sections to reference files
  across multiple hosts (e.g., `FNPATTERN_HOSTS: $XYMONNET/router-*`).
- Permits aggregated views ("total bandwidth across all edge routers").

**Effort:** medium-high — touches showgraph.c's file enumeration and
the locator semantics.

**Risk:** medium — security implications if not scoped to declared
host groups.

### Phase 7 — Stock gdef refresh

- Update `graphs.cfg` with examples using TREND, PREDICT, percentile
  bands, SHIFT comparisons.
- Add a `[temp_summary]`, `[smoke]`, `[trends_compare]` set of
  reference templates.

**Effort:** low (config-only).

**Risk:** low.

### Phase 8 — Probe framework (smokeping-equivalent)

- New `xymon-probe` client mechanism: configurable probes for ICMP,
  TCP, DNS, HTTP.
- Each probe handles its own collection logic, emits standardized
  multi-sample status messages.
- Reuse `do_devmon_rrd` or introduce `do_probe_rrd`.

**Effort:** high — significant new code.

**Risk:** medium — overlaps with existing `xymonnet`. Need a clear
deprecation/coexistence story.

---

## 7. Non-goals

For clarity, the following are **explicitly out of scope** of this
RFC:

- Distributed Xymon server architecture (master/slave probing).
- Real-time push protocols (WebSocket replacing the status poll).
- Frontend overhaul (D3.js / SPA replacement of the existing CGI
  HTML pages).
- Alerting / analysis.cfg rework — anomaly detection RRAs only
  expose data, not new alarm policy.

These are larger architectural questions that would justify separate
RFCs.

---

## 8. References

### Xymon source

- `xymond/do_rrd.c` — RRD handler dispatcher
- `xymond/rrd/do_*.c` — per-type RRD handlers (~40 files)
- `lib/xymonrrd.c` — `find_xymon_rrd`, `find_xymon_graph`, URL helpers
- `lib/htmllog.c` — column page graph selection (`generate_html_log`)
- `web/showgraph.c` — `load_gdefs`, `expand_tokens`, `rrd_graph` invocation
- `web/svcstatus-trends.c` — trends column aggregation

### Configuration

- `xymond/etcfiles/xymonserver.cfg.DIST` — TEST2RRD, GRAPHS, GRAPHS_*
- `xymond/etcfiles/graphs.cfg` — gdef sections (~110 default)

### External

- [RRDtool documentation](https://oss.oetiker.ch/rrdtool/doc/)
  - `rrdgraph_rpn`(1) — full CDEF/VDEF reference
  - `rrdgraph_data`(1) — DEF/CDEF/VDEF syntax
  - `rrdgraph_graph`(1) — LINE/AREA/GPRINT
  - `rrdcreate`(1) — RRA configuration
- [Smokeping](https://oss.oetiker.ch/smokeping/) — reference implementation
  for latency monitoring with smoke rendering
- [bonomani/devmon](https://github.com/bonomani/devmon) — actively
  maintained fork of the SNMP collector that produces DEVMON RRD
  markers

### Companion in-progress PRs (this fork)

- `fix/devmon-auto-graphs-main` — Phase 1 implementation
