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

    Defined  (you write; config)     Host · Test · Rule · Suppression
    Observed (system writes; timed)  State · Alarm · Action

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
  | WHAT     | its measurements      | `metrics{}` (correlated); `by` = the deciding one | content    |
  | WHEN     | at what instant       | `time`                                            | content    |
  | —        | the result            | `verdict` (one color)                             | the answer |
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
- **Split by independent verdict, not by metric.** Correlated measurements of
  one judged thing → one compact State (one line). Genuinely independent
  thresholds → separate States. An item thresholded on two aspects (capacity
  *and* inodes) still has **one** color = the worst — one State.
- `by` names the metric that drives the verdict (assigned by a **Rule** over it);
  the rest are data, read and graphed via `/series`.
- The classic **"column color" is a group-by rollup** — `group by {host,test} →
  worst` over the host's item-States. Computed on demand, never stored; many
  overlapping rollups (by service, datacenter) coexist.
- Anchors `host`/`test`/`item` are always present; free labels are test-emitted.
  A dotted name like `disk.fs_tx_full` is a flattened `(host,test,item,metric)`
  identity, not extra States.


3. Worked examples
------------------
A `disk` status on `web1` — **one State per filesystem** (Xymon's one line);
`by`=`pct_used` drives the color, the other numbers are correlated data:

```
host=web1  test=disk
 item    metrics{}                        by         verdict
 /var    { pct_used:96, inodes:41 }       pct_used   red
 /       { pct_used:38 }                  pct_used   green
 /home   { pct_used:72 }                  pct_used   yellow
```
Classic "disk column color" for web1 = `group by {host,test} → worst` = **red**.

A real Windows disk line decomposes the same compact way — one item, several
correlated metrics, one verdict:
```
host=ifmspc-usr2.ad1.i01.gtbcr.org  test=disk
 item  labels                            metrics{}                                               by   verdict
 C:    {mount:/FIXED/C:\, label:Windows} {cap:17, total_gb:951.65, used_gb:163.26, avail_gb:788.39}  cap  green
```

The pipeline acting on the red filesystem (WHY, then WHO):
```
State{host=web1, test=disk, item=/var}   by pct_used = 96
   │  WHY → Rule:  "pct_used ≥ 90 ⇒ red, severity=major"
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

Other test types — same shape, one State per item, `metrics{}` + `by`:
```
http  item=/api    {status_code:503, latency_ms:1200}   by=status_code  red
      item=/login  {status_code:200, latency_ms:142}    by=status_code  green
conn  item=-       {reachable:1}                          by=reachable    green   ← single-item test
cpu   item=core0   {util_pct:88}                          by=util_pct     yellow
      item=-       {load_5m:3.2}                           by=load_5m      green
```

Same data answers any question by picking the dimension to filter/group on:
```
"what's red on web1?"        states host=web1 & verdict=red          → /var (disk), /api (http)
"web1's disk column color?"  host=web1 & test=disk → rollup worst    → red
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

    Defined   /hosts /tests /rules /suppressions
              GET (list, filter by selector) · GET/PUT/PATCH/DELETE (item)

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

Deferred (promote only on demand):
- **Service** — a named Selector for now; promote to an entity only if it needs
  its own objects (ownership, SLOs).
- **owner (WHO)** — confirm hosts/tests carry it; it is the one dimension most at
  risk of being a gap today.
