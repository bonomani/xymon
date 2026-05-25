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

  | Question | Answers…            | Dimension(s)                         | Role        |
  |----------|---------------------|--------------------------------------|-------------|
  | WHERE    | which locus         | `host` + component path (`mount`, `core`, `if`) | identity |
  | WHAT     | which quantity      | `metric` (`pct_used`, `latency`, `fs_tx_full`)  | identity |
  | HOW      | by what probe       | `test` (`disk`, `http`) + `sender`   | provenance  |
  | WHEN     | at what instant     | `time`                               | content     |
  | —        | the reading         | `value` + `verdict`                  | the answer  |
  | WHY      | why it matters      | the **Rule**                         | → Alarm     |
  | WHO      | who is responsible  | `owner`                              | → Action    |

Consequences:
- `test` is **HOW** (a probe), `mount`/`core` are **WHERE** (sub-locations),
  `metric` is **WHAT**. No new structure per test type — just different label
  *values*.
- **One value per fully-qualified State** ⇒ multiple metrics = multiple States.
  No State is ever a bag of values.
- **Hierarchies and the classic "column color" are group-by views** over labels
  (`group by {host,test} → max severity`), computed on demand, never stored.
  Multiple overlapping rollups (by service, by datacenter) all coexist.
- **Anchor labels** `host` and `test` are always present (they anchor the
  pipeline and the default rollup); all other dimensions are free and emitted by
  the test. A dotted name like `disk.fs_tx_full` is just a flattened label-set
  `{test=disk, metric=fs_tx_full}` — the path and the labels are the same thing.


3. Worked examples
------------------
A red `disk` status on `web1` decomposes into atomic States — each one fully
qualified, one value + verdict:

```
WHERE                     WHAT (metric)  HOW (test)  WHEN   VALUE  VERDICT
host=web1 mount=/var      pct_used       disk        18:00  96%    red
host=web1 mount=/var      inodes         disk        18:00  41%    green
host=web1 mount=/         pct_used       disk        18:00  38%    green
host=web1 mount=/home     pct_used       disk        18:00  72%    yellow
```
The classic "disk column color" for web1 = `group by {host, test=disk} → max` = **red**.

The pipeline acting on the red one (WHY, then WHO):
```
State{host=web1, mount=/var, metric=pct_used} = 96%
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

Other test types — same six questions, different label *values*:
```
http   host=web1 url=/api    status_code   http   503    red
       host=web1 url=/api    latency_ms    http   1200   red
       host=web1 url=/login  status_code   http   200    green
conn   host=web1             reachable     conn   1      green    ← no component, one metric
cpu    host=web1 core=0      util_pct      cpu    88     yellow
       host=web1             load_5m       cpu    3.2    green
```

Same data answers any question by picking the dimension to filter/group on:
```
"what's red on web1?"        WHERE host=web1 & verdict=red          → /var pct_used, /api code+latency
"is disk filling anywhere?"  HOW=disk & WHAT=pct_used & red          → group by WHERE
"web1's disk column color?"  WHERE host=web1 & HOW=disk → rollup     → red
"who gets paged for this?"   WHO = owner of those States             → team:storage
"silence web1 tonight"       Suppression WHERE host=web1, window      → no alarms 22:00–23:00
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

    Observed  /states /alarms /actions
              GET (list, filter by any dimension; group-by for rollups) · GET (item)
              writes only via real commands: POST /actions (ack/disable) and
              batch ingest of States (combo/POST)

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

Deferred (promote only on demand):
- **Metric as a first-class time-series** — today it's a `metric` dimension + a
  value on State; promote only if raw history/graphing needs its own entity.
- **Service** — a named Selector for now; promote to an entity only if it needs
  its own objects (ownership, SLOs).
- **owner (WHO)** — confirm hosts/tests carry it; it is the one dimension most at
  risk of being a gap today.
