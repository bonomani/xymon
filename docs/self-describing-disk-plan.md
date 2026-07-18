# Implementation plan: self-describing disk (metric block replaces do_disk)

Goal: let the stock `disk` (and `inode`) column be produced as a self-describing
METRICS block instead of the built-in `do_disk` handler, without breaking
filenames, history, graphs, or old clients. This is the endpoint the
linecount-hint fix (feat/disk-linecount-hint) was the pragmatic first step of.

## Base: self-describing-metrics only

This branch (`feat/self-describing-disk`) is based on `feat/self-describing-metrics`
and needs nothing else. That branch supplies both genuinely-required pieces:

1. the marker **writer** (`do_devmon_rrd`) that creates the block's RRDs, and
2. **content routing** (`xymon_markers_have_store`) that detects a block and
   dispatches to that writer.

`feat/test-cfg` is NOT required (an earlier draft of this plan wrongly said it
was). The one thing it was invoked for - rerouting disk off the built-in
handler - has a smaller solution that lives entirely on this branch (see
Feature 2). test-cfg's `HANDLER markers` is an optional, cleaner, config-driven
way to express that reroute, and can be adopted later if the two branches merge;
it is not a prerequisite for self-describing disk.

(For reference, if the branches ever do merge, the conflict is four files, all
additive - `include/libxymon.h`, `lib/Makefile`, `lib/xymonrrd.c`,
`lib/htmllog.c` - both sides add to the same regions with no logic clash.)

## The two missing capabilities

### Feature 1 - a collision-free instance encoding, with a one-time rename

Why an encoding at all: a mount point cannot be a filename verbatim - `/` is the
directory separator (`disk,/var/log.rrd` would be read as nested directories).
So `/` must be substituted. `do_disk` uses `/`->`,` (`/`->`,root` for the root),
the marker/devmon writer applies its own `/`->`,` and joins with `.`. Two
issues:

1. The two conventions differ slightly (`disk,root.rrd` vs `disk.,root.rrd`), so
   a naive block would orphan history - the original reason this feature existed.
2. More important, `/`->`,` is **ambiguous and always has been**: `,` is a legal
   filename character, so `/a/b` and `/a,b` both encode to `disk,a,b.rrd` and
   collide into one RRD. Only `/` and NUL are illegal in filenames, so **no
   single-character substitution is safe** - a collision-free scheme must be
   reversible.

Decision (option 2): do NOT add a per-column filename template (`fnfmt`) to the
writer - that bakes a legacy quirk in permanently and keeps the collision.
Instead adopt one reversible, collision-free instance encoding for the whole
writer, and migrate existing files into it once. This fixes the 20-year latent
collision as a side effect and keeps the writer uniform (disk is not special).

Three coordinated pieces (this is writer AND showgraph, not writer alone):

- **Encode** (`xymond/rrd/do_devmon.c` / the shared filename builder): `/` (and
  the escape char) percent-encoded, e.g. `/var` -> `%2Fvar`, `%` -> `%25`.
  Reversible, collision-free.
- **Capture** (graphs.cfg gdef `FNPATTERN`): unchanged mechanism, matches the
  encoded name.
- **Decode** (`web/showgraph.c` `@RRDPARAM@`): decode the captured instance back
  to the mount point for the legend, so graphs read `/var`, not `%2Fvar`.
- **Migrate** (one-time script): rename existing `disk,*.rrd` into the new
  encoding, idempotent and safe (skip already-migrated, never lose a file).
  Run once at cutover; not in the hot write path.

Separability: fixing the ancient collision is independent of self-describing
disk. If the encode/decode/migrate chain proves fiddly, self-describing disk can
ship first on the existing `,` encoding (inheriting the old collision - no worse
than today), and the collision fix lands as its own follow-up. So option 2 is
the target, but it does not block the disk block.

Acceptance: `/a/b` and `/a,b` produce distinct RRD files; the graph legend shows
the real mount point; a migrated tree's graphs are continuous with pre-cutover
history.

### Feature 2 - a block-bearing status wins over the built-in handler

Problem: the dispatcher in `xymond/do_rrd.c` (`update_rrd`) checks built-in
handler ids first (`if (strcmp(id,"disk")==0) do_disk_rrd(...)`), and content
routing is only the fallback. So a `disk` status carrying a METRICS block still
goes to `do_disk_rrd` -> double write.

Fix (on this branch, no test-cfg): move the content-routing check ahead of the
built-in chain - when a status carries a store block
(`xymon_markers_have_store(msg)`), dispatch to `do_devmon_rrd` and do NOT fall
into the built-in `disk` branch. This is the "self-describing beats built-in"
rule, and it is safe because emitting a block is deliberate: a column only
reroutes if its producer chose to add one, so default columns hit exactly the
same built-in branch as today.

Optional refinement (needs test-cfg, later): `HANDLER markers` on a `TEST`
block expresses the same reroute per-column and config-driven, rather than
automatically-on-block-present. Cleaner control, but not required - the
dispatch-precedence rule above is enough to retire `do_disk` for a
block-bearing disk status.

Scope: self-contained on `feat/self-describing-metrics`.

## The disk metric block itself

With feature 2 present (and optionally feature 1), express disk as a block. No
test.cfg is needed - the block itself drives everything:

1. The status body carries a METRICS block whose instance lines are the
   filesystems, with the DS the `[disk]` gdef already expects (percent-used,
   etc. - collision 3, mechanical: match do_disk's dataset names/values). The
   block's presence is what reroutes disk off `do_disk` (feature 2), so no
   `HANDLER`/`TEST2RRD` config is required to make it the sole writer.
   (test.cfg `TEST disk { HANDLER markers ... }` is the optional config-driven
   way to force the same reroute explicitly - not needed here.)
2. Who emits the block: the server-side `unix_disk_report` in
   `xymond/xymond_client.c` (same place the linecount hint lives) is the natural
   producer - it already iterates the filesystems, knows the post-IGNORE set,
   and computes the values. It appends the METRICS block to the status it builds.
   The shell client is unchanged (still ships raw df); the block is synthesised
   server-side from the parsed df. This keeps old clients working and avoids a
   wire-format change on the client.
   - Consequence: the `<!-- linecount -->` hint becomes redundant for disk (the
     block's instance count is exact and derived) and can be dropped for the
     columns that carry a block, kept for those that do not.
3. do_disk retired for the column via feature 2; `do_disk_rrd` still exists for
   any column/client not carrying a block (fallback forever).

## History / migration

Option 2 (chosen) does not reproduce the old names - it replaces the ambiguous
`,` encoding with a reversible one and renames existing files once. History is
preserved by the migration, not by matching names. Acceptance: after the
one-time rename, a column's graphs are continuous across the cutover, and the
previously-colliding `/a/b` vs `/a,b` now have separate RRDs.

If the collision fix is deferred (see Feature 1 "separability"), self-describing
disk ships on the existing `,` encoding with no rename and no display change,
inheriting the old collision unchanged.

## What this buys beyond paging

- Exact paging (already had it via the hint) - now derived, not counted.
- Alerting on the stored RRD values via DS/AGGDS rules (from self-describing) -
  disk % used becomes a first-class metric, not just a status colour.
- disk stops being a special-cased built-in handler and becomes an ordinary
  declared metric - one less bespoke code path, the general model absorbing a
  legacy one.

## Vocabulary (binding for all new surface)

Four nouns, used with one meaning everywhere: **metric** (a DS - the curves
of an image), **instance** (a measured object - one RRD file; the unit of
filters, counts and paging), **graph** (a graphs.cfg definition), **image**
(one rendered slice). Rules: every new name states its unit (instances=,
MAXINSTANCESPERIMAGE as instances-per-image, STALEAFTER seconds); legacy names
(maxgraphs, linecount, GRAPHS ::N, FNPATTERN) are frozen aliases documented
against the glossary, never removed and never duplicated with a second new
spelling; new code speaks the glossary (instancespec, instancecount - not
countspec, itemcount). The marker attribute is instances=N / instances=all
(renamed from the earlier count= while unshipped, history rewritten).

## Marker design doctrine (settled)

Two markers, and the axes on which that decision was made - so it is not
relitigated:

- XYMON METRICS declares a FACT (schema + instance values); XYMON GRAPH is a
  display INSTRUCTION (gdef name + instances=). Decomposition is by fact
  declared, never by consumer: METRICS already serves three readers (writer
  stores, AGGDS aggregates, paging counts) as projections of one block - one
  source of truth, and a fourth consumer costs zero wire change. One marker
  per consumer would triple the data and allow the copies to disagree.
- No verbs in names (STORE/SHOW): METRICS is multi-verb by design; the verbs
  live in the contract documentation (xymonmarkers.h). No backend in names
  (RRD): the block is a neutral contract - naming the backend is the
  DEVMON RRD mistake this vocabulary supersedes.
- Schema and values always travel together: a SCHEMA/VALUES split would make
  the server remember state between messages - statelessness outranks the
  few DS: lines saved.
- Markers declare facts, never policy: no thresholds in the wire; policy
  belongs to the server rule engine (RFC #218, one rule engine).
- Extension is a new XYMON <WORD>: marker, granted only for a distinct fact
  with a distinct lifecycle; unknown markers are ignored comments, so the
  namespace is forward- and backward-compatible for free. The DS: line
  dialect is documented as a generic schema mini-language (type, heartbeat
  as validity window, min/max), not an RRDtool allegiance.
- The only standalone projection of a block is the count, and only where no
  block exists: the legacy linecount hint, and instances= when display
  diverges from the block.

## Counting / display doctrine (amended)

The branch currently answers "how many graphs?" with the fileset-unknown
predicate: when a store filter (STOREPATTERN/EXSTOREPATTERN) makes the file
set diverge from the message, the count is set to 0 and the graph renders
UNSLICED. That is a stopgap, not a design: a host with 150 filesystems and
one filter gets a single page of 150 graph images - the exact problem paging
exists to solve. Replace it with a hierarchy where every level knows what it
counts:

1. An explicit instances= on a XYMON GRAPH marker wins - the producer of the
   MESSAGE knows its own graphs.
2. Otherwise, a per-host fileset index maintained by the WRITER: xymond_rrd
   is the single creator of RRD files, so it keeps "instance -> last write"
   up to date as it writes (bookkeeping at event time, not recounting at
   render time). The renderer reads that one small file and applies the
   staleness rule to its entries - no readdir, no per-file stat. Two
   obligations: freshness is time-based, so the index stores last-write
   timestamps (not a bare counter); external deletions (trimhistory, manual
   rm) bypass the writer, so a missing/inconsistent index triggers a one-off
   rebuild scan and drift is tolerated between rebuilds.
3. Unsliced rendering remains ONLY as the last resort when neither message
   nor files are reachable (locator-based remote RRD storage).

This reinstates the sound half of PR #246 (count what will actually render)
while keeping its env-var config surface retired.

## Archive consolidations derived from graph DEFs (candidate design)

An RRA line bundles two decisions that belong to different owners:
WHICH consolidations exist (AVERAGE/MAX/...) is the consumer's need -
the graph knows it reads DEF:...:MAX; the retention ladder (resolutions,
depth, disk budget) is the admin's policy. Split them accordingly:

- rrddefinitions.cfg keeps ONLY the ladder (steps x rows per resolution).
- The needed consolidations are DERIVED, no new keyword: at file creation
  the writer collects the gdefs whose FNPATTERN match the file (the gdef
  meta scanner already parses graphs.cfg) and unions the consolidation
  functions their DEF lines read. Ladder x union = the RRA set. Adding
  DEF:...:MAX to a graph is what causes MAX archives for future files -
  one source of truth per decision, in its owner's file.
- Motivation: AVERAGE-only archives flatten peaks on long ranges (a
  20-minute 98% disk spike averages invisible on the yearly view), and
  legend GPRINT:...:MAX only shows the max of the averaged points. A MAX
  archive read by DEF:...:MAX preserves true peaks - today unused and
  unreachable without hand-syncing two config files.

DECIDED: no back-migration - new archives start today. Old files keep
AVERAGE only, forever (no rrdtool create --source pass). Consequence the
renderer must absorb: DEF:...:MAX against a file lacking the archive
fails the whole rrdtool graph, so showgraph must probe each file's
available consolidations (rrd_info) and omit DEFs referencing an archive
that file does not have. Same family as the heartbeat watch-item:
declarations changed after creation only affect new files, and the
reader tolerates the mix.

## Units and gdef scaffolding (decided)

- Unit as a declared fact (DS dialect extension, DECIDED): the unit is
  metric semantics - producer knowledge, like type and bounds - and the one
  fact whose absence caps auto-generated graphs at YAXIS "Value". Declare it
  PER DS, as an optional 7th colon-separated field
  ("DS:read_ms:GAUGE:600:0:U:ms"); the parser consumes field 7, the writer
  reconstructs the 6-field spec for rrdtool, an unsuffixed line stays
  legal. DECIDED: colon, one separator for the whole line - simplicity and
  coherence outrank the alternative (a space suffix would have kept the
  left part a verbatim rrdtool spec for third-party parsers/copy-paste).
  Positionally unambiguous because the arity is fixed (see COMPUTE below).
  Accepted cost: a suffixed line is no longer a paste-able rrdtool DS
  spec, and strict 6-field parsers must tolerate a 7th field - the writer
  is unaffected since it revalidates and rebuilds the spec anyway.
  Persistence: an RRD file cannot carry a unit (the format has no metadata
  slot) and showgraph renders from files without the message in hand, so a
  declared unit must survive server-side: it rides the writer-kept fileset
  index (same writer, same cadence - entries extend to instance ->
  last-write + per-DS units), where the renderer already looks to count.
  The synthetic gdef reads it for its YAXIS (grouping by unit); a
  hand-written gdef still wins. Unit absent = exactly today's behaviour:
  hand-written YAXIS or the generic "Value".
  COMPUTE is excluded from the wire dialect on three grounds, none of them
  taste: it is structurally redundant (the producer computes its instance
  values, so any derived DS is expressible as a plain DS with computed
  values, at identical storage cost); it would bake RRD-specific RPN
  semantics into the backend-neutral contract (a non-RRD writer would need
  an RPN evaluator); and it is measured-unused in twenty years of xymon
  code and config. Its exclusion is what makes the DS arity fixed. Never a per-block
  unit declaration: a block may legitimately mix units (bytes/s + packets/s
  + errors), and a second declaration surface invites contradiction. The
  graph axis is DERIVED, not declared: all DSes of an image share a unit ->
  that is the YAXIS; mixed units -> the synthetic gdef groups DSes by unit
  (one image per unit); hand-written gdefs decide for themselves. New wire
  surface -> high bar; goes with the markers slice review, not before.
- Unit namespace (DECIDED): free text on the wire, never rejected -
  syntactic constraints only (no colon: it is the separator; no whitespace;
  printable ASCII; short cap). The reason to know a unit is to RENDER it,
  not to police it: scaling is knowledge only the renderer can use. So the
  knowledge lives in a compact built-in table next to the synthesizer
  (a dozen entries, not a config file - exotic wants a hand-written gdef,
  which already wins), mapping well-known units to rendering hints:
  base ("B", "B/s" -> --base 1024, everything else 1000), SI autoscale
  on/off (on for scalable quantities, off for "%"/counts/ratios where
  rrdtool would print "0.9 k"), and spelling aliases ("msec"->"ms",
  "bytes"->"B") applied at render time for grouping and axes - the wire
  keeps what the producer said. An unknown unit is fully legal: verbatim
  axis label, byte-exact grouping, default rendering. So nobody has to fix
  a "bad" unit: a known unit renders smartly, an unknown one renders
  plainly, and both work. Grouping is byte-exact AFTER alias
  normalization. Our own emitters and docs use the canonical spellings
  (SHOULD, not MUST). Table entries are addable without ever touching the
  wire contract.
- Gdef scaffold mode (DECIDED, ~20 lines): the runtime synthesizer
  (synthetic_gdef/synthetic_defs) IS the generator - add a print mode
  (showgraph --emit-gdef <name>) that writes the synthesized block for the
  admin to capture into graphs.d/ and customize. One-shot scaffold, never a
  sync: once edited the file is the admin's (hand-written already wins).

## Threshold rendering (candidate)

- A metric's thresholds have two origins with two owners, and each gets its
  own mechanism - never mixed:
  - Producer-emitted threshold metrics (the usual case: the producer emits
    read_ms AND read_ms_warn): the VALUE is the producer's policy, but the
    RELATION - "this DS is the warn level of that DS" - is a fact only the
    producer knows, so it is declared in the METRICS block on its own line:
    "THRESHOLD <base-ds> <relop><threshold-ds> [COLOR=<color>]" (default
    red). The grammar is the EXISTING DS/AGGDS rule language with a DS name
    in the operand position - not a new vocabulary: severity is a xymon
    color (never "warn"/"crit" words; DS rules default COL_RED, override
    COLOR=), direction is the comparison operator glued to its operand as
    one token (">resp_ms_warn", as ">90" in DS rules - AGGDS documents the
    one-token form). One severity may appear in multiple relations per base
    metric - a temperature with low+high yellow and low+high red is four
    lines ("<temp_lo_crit", "<temp_lo_warn COLOR=yellow", ">temp_hi_warn
    COLOR=yellow", ">temp_hi_crit"), rendering as an operating band. The
    operator exists for the ALERT consumer (#218 already speaks this shape);
    the renderer ignores it and styles the line by its color - one
    vocabulary for severity, style and alert state. The held-back literal
    form unifies for free: ">200" is exactly a DS-rule operand, a number
    where a DS name may stand - not a second mechanism.
    Example: "THRESHOLD read_ms >read_ms_warn COLOR=yellow". The line declares ONLY the
    relation - never a display instruction (display belongs to the graph
    side, same reasoning that put MAXINSTANCESPERIMAGE/TRENDS/STALE in
    graphs.cfg, not in the block). Rendering is DERIVED from the fact,
    exactly as YAXIS is derived from the unit: the synthetic gdef's default
    is to plot the threshold DS on its base metric's image, threshold-styled
    (LINE from its DEF - a curve with history, better than any flat rule),
    excluded from instance counting/aggregation; a hand-written gdef wins
    and may show it separately, differently, or not at all. A renderer that
    ignores the line entirely still stores and shows the threshold DS as an
    ordinary curve - storage is unconditional, co-plotting is derivation.
    New wire surface -> high bar; same review gate as the rest of the
    dialect.
    NOT a naming convention ("*_warn" suffix magic): names cannot carry the
    relation reliably - false positives (log_warn = a count of warning
    lines, silently demoted to a threshold line with no producer opt-out),
    false negatives (rrdtool caps DS names at 19 chars, so exactly the
    longer names truncate and the pairing breaks silently), it grows into a
    name-encoded mini-language (crit, multiple levels, direction, ambiguous
    base-name stripping), and it retroactively reinterprets every existing
    file that happens to match. A fact is stated, not inferred. The
    convention survives as a SPELLING habit: our emitters name the DS
    read_ms_warn AND declare it - the name for humans, the line for
    machines.
  - analysis.cfg thresholds: policy, stays server-side, never on the wire.
    The renderer asks the rule engine what applies to (host, metric) and
    draws HRULEs (flat lines; a TIME-conditional rule renders its currently
    effective level). Gated on RFC #218's unified rule engine - re-parsing
    analysis.cfg inside showgraph would be a second, drift-prone matcher.
  Deep-pass amendments (candidate, with the rest):
  - Precedence - the honest answer to "is this policy on the wire?": relop +
    color IS a rule, so the declared form is the producer's DEFAULT, never
    the last word. In the #218 engine, analysis.cfg matches first (first-match,
    as always); the declared rule fires only when server policy says nothing
    about that metric. The exact alerting mirror of "hand-written gdef wins".
    Without this, two rule sources fire independently - the contradiction
    trap this doc warns about elsewhere.
  - Multi-instance images: co-plot thresholds ONLY when the image shows a
    single instance. With MAXINSTANCESPERIMAGE > 1, per-instance threshold
    curves belong to different instances and drown the image - such images
    behave as THRESHOLDS OFF; a hand-written gdef can still do anything.
  - Unknown values: a threshold DS at U makes its rule SILENT (no alert,
    gap in the curve). No path may compare U as 0 - that would fire every
    "<" rule the moment a producer misses a baseline cycle.
  - Colors: yellow|red only (the two alert severities); parse_color also
    knows green/clear/purple/blue, all rejected here - a crossing that
    means green is not a threshold.
  - Scope: both operands name DSes declared in the SAME block. Cross-file
    references stay out (that is analysis.cfg/#218 territory). In-block
    scope buys timestamp coherence: metric and thresholds land in the same
    RRD write, so evaluation always compares same-cycle values - a DS rule
    across two files can race a collection cycle, the declared form
    structurally cannot.
  - Precision: threshold DSes are not "excluded from instance counting"
    (instances are lines; counting never saw DSes) - the real exclusions
    are: the synthetic gdef must not plot them as peer metrics, and
    aggregates over "all DSes of a fileset" must skip them.
  The GRAPH marker is not involved: it answers "which images belong to this
  status, how many instances" - graph CONTENT is always derived server-side
  from facts + gdefs, so thresholds never touch it. A producer with a FIXED
  level needs no separate mechanism either: it emits the level as a
  constant-valued threshold DS and declares the same relation - one uniform
  mechanism, and better than a flat rule, because when the producer changes
  the level the graph shows the step instead of rewriting history. (The
  grammar leaves room for a later literal form - "THRESHOLD read_ms warn
  200", persisted in the fileset index like units - but that is a second
  mechanism for the same fact; held back unless the extra-DS cost proves to
  matter.) So the entire wire surface for thresholds is ONE line in ONE
  marker: THRESHOLD in the METRICS block.
  Whether the threshold is PLOTTED is the admin's say, not the producer's -
  the declaration never forces a pixel. Control points, coarse to fine:
  the synthetic gdef co-plots by default (most people want to see what
  would alert); a per-graph display keyword in graphs.cfg - THRESHOLDS
  ON|OFF, default ON, next to LAZY/MAXINSTANCESPERIMAGE/TRENDS/STALE -
  suppresses the threshold curves without writing a full gdef; a
  hand-written gdef has the last word (pick, style, or split them onto
  their own image). Possible later: a &nothresholds URL toggle in
  showgraph (per-view, same family as &nostale) - not needed for the
  model to be complete.
  Both compose on one image. Bonus: the declared THRESHOLD relation is
  exactly what #218 wants too - "alert when a metric crosses its declared
  threshold metric" becomes a generic DS-vs-DS rule instead of per-handler
  hardcoding. One declaration, two consumers (graph and alert), neither
  owns it - the marker doctrine working as intended.

## Display-window keywords (candidate)

- STALE <seconds>, per graphs.cfg block (next to LAZY/MAXINSTANCESPERIMAGE/TRENDS/
  STOREPATTERN): the freshness window showgraph uses instead of the
  hard-coded 86400 at showgraph.c (mtime cutoff behind &nostale). Needed for
  legitimately periodic instances (weekly job, backup mount) whose graphs
  must stay visible between appearances; per-graph granularity is enough -
  freshness is a display property of the graph, not of each DS.

## Phasing (commits on this branch)

1. Feature 2 first (smallest): a block-bearing status routes to the marker
   writer ahead of the built-in handler; test: a disk status with a block
   writes once, no do_disk double-write; a block-less disk status is unchanged.
2. Feature 1: reversible instance encoding (writer encode + showgraph decode)
   + one-time rename migration; test: `/a/b` and `/a,b` get distinct RRDs and
   legends show the real mount point. (Deferrable - see Feature 1.)
3. Feature 2: HANDLER routes a column to the marker writer, retiring the
   built-in; test: a disk status with a block writes once (no do_disk double).
4. `unix_disk_report` emits the METRICS block (DS matching the gdef); drop the
   linecount hint for block-bearing disk; end-to-end test: files, DS, graph,
   and an AGGDS/DS alert on disk% all work; old-client df-only path unchanged.
5. Docs: test.cfg disk example; note disk is now a declared metric.

## Risks / watch-items

- The rename migration is load-bearing and destructive: it must be idempotent,
  skip already-migrated files, and never lose one. Test on a copy first.
- The encode/decode must round-trip: any instance the writer encodes,
  showgraph must decode to the identical mount point, or legends break.
- The dispatcher change (feature 2) touches the hot RRD path for every column;
  guard it so only an explicit HANDLER/marker route diverts - default columns
  must hit the exact same built-in branch as today.
- `unix_disk_report` emitting a block enlarges the status message; check the
  status buffer bounds (it uses `msgline[4096]` per line and strbuffer for the
  body - the block is many short lines, fine, but confirm).
- Content routing already lets any sender create RRDs; server-synthesising the
  block (not trusting a client block) keeps disk's trust model unchanged.
- Project phase: this is rethink-tier (retiring a built-in handler). It rides on
  ONE feature branch (self-describing-metrics), not yet merged upstream.
  Sequence after that lands, or keep as a proving branch. test-cfg is optional
  and only for the config-driven HANDLER refinement.
- Declared heartbeats only act at file creation: the DS heartbeat lives in
  the RRD file once created, so a producer changing its DS:<hb> declaration
  affects new files only - existing files need an rrdtool tune pass. Either
  the writer detects the mismatch and tunes, or the limitation is documented;
  silently ignoring the new declaration is the one wrong option.
- Instance sort order: showgraph's rrd_name_compare knows only two regimes -
  pure-integer keys (numeric sort) and everything else (case-sensitive strcmp).
  Multi-component numeric keys sort wrongly: strcmp puts "1.10.1" before
  "1.2.1", the reverse of OID/version order. Harmless today (stock instances
  are names or plain integers), but once instances are arbitrary keys announced
  by a METRICS block (SNMP collectors -> OIDs, composed indexes), display order
  and first/count paging stability depend on this comparator. Before that
  lands, replace it with ONE version-aware compare (split on separators,
  compare digit runs numerically, strcmp fallback per component - strverscmp
  semantics): it subsumes all three cases (plain integers unchanged, OIDs
  fixed, names unchanged), so it is a drop-in replacement, not a new special
  case. Two hard requirements, both violated by the current comparator: it
  must be a TOTAL ORDER - (a) a digit run always compares numerically
  regardless of the partner key; the current per-pair numeric-or-strcmp
  choice is intransitive (9 < 10 < "1a" but 9 > "1a" directly), so qsort's
  result depends on readdir order - measured: the three permutations of
  {9, 10, 1a} produce three different "sorted" outputs; (b) distinct keys
  must never compare equal ("007" vs "7" returns 0 today) - numerically
  equal components need a strcmp tie-break, otherwise their order, and the
  first/count slice containing them, is unspecified.
