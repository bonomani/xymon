Xymon monitoring — domain model
===============================

A small core: a 5-noun pipeline, one law, two planes — and one atom (the
**State**) whose identity is a *label-set* in which every dimension answers
exactly one question. This is the model the API rests on.


1. The pipeline and the one law
-------------------------------
```
Host  ──run──▶  Test  ──produces──▶  State  ──raises──▶  Alarm  ──triggers──▶  Action
```

Every arrow obeys one law:

    advance if a RULE matches  —  unless a SUPPRESSION holds.

- **Rule**        — "when «condition», advance."  (state ≥ threshold → raise Alarm;
                     alarm critical → notify on-call)
- **Suppression** — "for «scope» during «window», hold."  (disable, maintenance,
                     dependency, ack-stops-notifying)
- **Selector**    — a label/query that scopes a Rule or Suppression. A "service",
                     "group", or "page" is a Selector, not a container.

Two planes:

    Defined  (you write; config)     Host · Test · Rule · Suppression · View
    Observed (system writes; timed)  State · Alarm · Action

(`View` is presentation only — a curated page tree — and gates nothing in the
pipeline; see §6.)

The Defined/Observed split gives config-vs-runtime and time/history for free:
observed entities are series (State) and events (Alarm, Action).

Operator commands are just Actions whose effect is a Suppression — so there are
no bespoke verbs:

    acknowledge = Action{type:ack}     → Suppression on  Alarm → Action
    disable     = Action{type:disable} → Suppression on  Test  → State/Alarm
    enable      = let that Suppression expire / delete it


2. The atom: a State is a label-set; every dimension answers one question
-------------------------------------------------------------------------
Orthogonality test: each dimension answers **exactly one** of where/what/how/
when; together they are complete; none is redundant. value + verdict are the
*answer* the dimensions key to. WHY and WHO are not identity — they are the
pipeline.

  | Question | Answers…              | Dimension(s)                                      | Role       |
  |----------|-----------------------|---------------------------------------------------|------------|
  | WHERE    | which thing is judged | `host` + `item` (filesystem/url/core) + labels    | identity   |
  | HOW      | by what probe         | `test` (`disk`, `http`) + `sender`                | provenance |
  | WHAT     | its measurements      | `metrics{}` — each may carry its own verdict      | content    |
  | WHEN     | at what instant       | `time`                                            | content    |
  | —        | the result            | `verdict` — a semantic **status** (colour is render) | the answer |
  | WHY      | why it matters        | the **Rule**                                      | → Alarm    |
  | WHO      | who is responsible    | `owner`                                           | → Action   |

The atom is the **item** — the smallest thing that earns **one verdict** (a
filesystem, a URL, a core), keyed `(host, test, item)`. That is Xymon's *one
line*.

Consequences:
- `test` is **HOW**; `host` + `item` + free labels (`mount`, `label`, `core`)
  are **WHERE**; the numbers are **WHAT** — but they live in `metrics{}` on the
  *one* State, because they are **correlated facets** of a single measurement
  (`avail = total − used`, `cap = used/total`). They are **not** separate States.
- **One State per item, not per metric.** Correlated measurements of one judged
  thing live in `metrics{}` on a single State (one line) — not split apart.
- **Verdicts are per-metric and semantic.** A Rule assigns a *status* —
  `ok` / `warning` / `critical` / `disabled` / `nodata` / `unknown`, **never a
  colour** — to a metric; metrics with no rule are data (graph via `/series`).
  The item's status = **worst** of its metrics; column / host / page = worst
  over the level below — one operator at every level. **Colour is a pure render
  mapping** (ok→green, warning→yellow, critical→red, disabled→blue,
  nodata→clear, unknown→purple), so themes / colour-blindness / relabelling stay
  a render concern.
- The classic **"column colour" is a group-by rollup** — `group by {host,test} →
  worst` over the host's item-States. Computed on demand, never stored; many
  overlapping rollups (by service, datacenter) coexist.
- Anchors `host`/`test`/`item` are always present; free labels are test-emitted.
  A dotted name like `disk.fs_tx_full` is a flattened `(host,test,item,metric)`
  identity, not extra States.


3. Worked examples
------------------
A `disk` status on `web1` — **one State per filesystem** (Xymon's one line);
each metric carries its own semantic status, and the item status is the worst:

```
host=web1  test=disk
 item    metrics (value · status)                     item status
 /var    pct_used 96 critical · inodes 41 ok           critical
 /       pct_used 38 ok                                 ok
 /home   pct_used 72 warning                            warning
```
Classic "disk column" for web1 = `group by {host,test} → worst` = **critical**
(rendered red).

A real Windows disk line decomposes the same way — one item; only capacity is
ruled, the rest are data:
```
host=ifmspc-usr2.ad1.i01.gtbcr.org  test=disk     labels {mount:/FIXED/C:\, label:Windows}
 item  metrics (value · status)                                       item status
 C:    cap 17 ok · total 951.65G · used 163.26G · avail 788.39G        ok
```

The pipeline acting on the critical filesystem (WHY, then WHO):
```
State{host=web1, test=disk, item=/var}   metric pct_used = 96
   │  WHY → Rule:  "pct_used ≥ 90 ⇒ critical"
   ▼
Alarm  (firing, major)
   │  WHO → owner=team:storage → route=pager
   ▼
Action  notify team:storage via pager
```
Suppressions gate an arrow:
```
maintenance   Suppression{ where: host=web1, window: 22:00–23:00 }   holds  State→Alarm
acknowledge   Action{type:ack} ⇒ Suppression{ alarm:this }           holds  Alarm→Action
```

Other test types — same shape, one State per item, per-metric status:
```
http  item=/api    status_code 503 critical · latency_ms 1200 warning   → critical
      item=/login  status_code 200 ok        · latency_ms 142 ok        → ok
conn  item=-       reachable 1 ok                                        → ok
cpu   item=cpu     util_pct 88 warning · load_5m 3.2 ok                  → warning
```
(`cpu` shows two independently-ruled metrics on one item; the item = worst.)

Same data answers any question by picking the dimension to filter/group on:
```
"what's wrong on web1?"      states host=web1 & verdict=critical     → /var (disk), /api (http)
"web1's disk column?"        host=web1 & test=disk → rollup worst    → critical (→red)
"the /var capacity trend"    /series host=web1&test=disk&item=/var&metric=pct_used
"who gets paged for this?"   owner of those States                   → team:storage
"silence web1 tonight"       Suppression host=web1, window            → no alarms 22:00–23:00
```


4. Ingest
---------
A probe sends many readings at once; Xymon's `combo`/`extcombo` is exactly that
batch frame. It is transport, not a model entity:
```
client ──combo[ disk@web1, http@web1, cpu@web1 ]──▶ server ──unpack──▶ atomic States
```
A combo is never queried and has no meaning of its own; it unpacks into States
on arrival. (Batching matters more over native TLS, where a handshake per report
is costly — one combo per connection is the efficient ingest path.)


5. How the API falls out (uniform)
----------------------------------
Each noun is a resource collection with the same shape; the plane decides which
methods are real:

    Defined   /hosts /tests /rules /suppressions /graph-defs /views
              GET (list, filter by selector) · GET/PUT/PATCH/DELETE (item)
              /views = the curated page tree (presentation only).

    Observed  /states /alarms /actions /series /graphs
              GET (list, filter by any dimension; group-by for rollups) · GET (item)
              writes only via real commands: POST /actions (ack/disable) and
              batch ingest of States (combo/POST)
              /series = a State value's history (time-series); /graphs = its
              rendered RRD image. Same selectors as /states, plus a time range.

Filtering, projection (`fields`), and Selector are identical on every
collection; a State is queried by any of its dimensions. Differences between
collections live in their record schema — data, not API structure.


6. Properties and deferrals
---------------------------
- Orthogonal : one job per noun; one Rule/Suppression law per arrow; one scoping
               mechanism (Selector); one atom (State = label-set → value+verdict)
               with every dimension answering exactly one question.
- Complete   : where/what/how/when/why/who are all answered; Rule owns
               State→Alarm (+severity); Suppression is the single home for
               disable/maintenance/dependency/ack.
- Symmetric  : every transition = Rule − Suppression. No special cases, no
               backward arrows (suppression is a declarative gate).

Promoted:
- **Time-series (the value's history)** — a State carries the *current* value;
  its history is the RRD series. Exposed read-only as `/series` (JSON data) and
  `/graphs` (rendered image), reusing the same WHERE/WHAT/HOW selectors plus a
  time range (`from`/`to`/`step`). Named graphs (the `graphs.cfg` analogue) are
  a Defined resource `/graph-defs` = a Selector + render hints. Not a new
  pipeline node — it is the WHEN axis of a State's value. Numeric metrics only.
- **Views (the curated page tree)** — the hosts.cfg "pages" analogue: a Defined
  resource `/views`, a tree of `{title, parent, selector, order}`. Two kinds of
  grouping, kept separate: *derived* grouping is a **label** (`os=windows`,
  `site=paris`) via group-by/selector; *curated* grouping (editorial order +
  nesting + titles) is a **View**, built on selectors so membership stays
  derived/auto-updating. A View is **presentation only** — it gates nothing in
  the pipeline, and many overlapping Views (by OS, site, service) can coexist.

Deferred (promote only on demand):
- **Service** — a named Selector for now; promote to an entity only if it needs
  its own objects (ownership, SLOs).
- **owner (WHO)** — confirm hosts/tests carry it; it is the one dimension most at
  risk of being a gap today.
