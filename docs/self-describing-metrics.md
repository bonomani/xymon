# Self-describing metrics: dialect design

Design doctrine and decided/candidate surface for the XYMON METRICS/GRAPH
marker dialect (lib/xymonmarkers.h) and everything derived from it. Nothing
here is specific to one column: disk, temperature, response time or any
custom collector all speak this dialect. The disk migration itself lives in
self-describing-disk-plan.md and references this document.

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
    "THRESHOLD:<base-ds>:<relop><threshold-ds>[:<severity>]" - severity
    warn|crit, default crit. The line speaks the BLOCK's dialect, not
    analysis.cfg's: colon fields with a keyword prefix and an optional
    trailing field, the same shape as a DS line (one separator for the
    whole line - the unit decision's principle). Severity is the generic
    warn|crit, NOT a xymon color: the wire is backend-neutral (the COMPUTE
    exclusion's reason), and yellow/red is one consumer's vocabulary - the
    xymon consumer maps warn->yellow, crit->red, exactly as it derives
    YAXIS from the unit; analysis.cfg keeps speaking colors on its own
    layer. The comparison operator IS kept, glued to its operand as one
    token (">resp_ms_warn") - comparison is universal, not xymon-specific,
    and #218 ingests it directly. One severity may appear in multiple
    relations per base metric - a temperature with low+high warn and
    low+high crit is four lines ("<temp_lo_crit", "<temp_lo_warn:warn",
    ">temp_hi_warn:warn", ">temp_hi_crit"), rendering as an operating band.
    The literal form is INCLUDED (promoted from held-back): the operand
    slot holds either a declared DS name or a number - one grammar, not a
    second mechanism. Resolution: a token naming a DS declared in the same
    block is a threshold curve; else a number is a literal; else the line
    is ignored (the parser's silent-ignore convention). The two forms
    differ semantically, and that difference IS the producer guidance:
    a literal is BLOCK-WIDE (one value for every instance - per-instance
    levels must be DSes) and has NO history (a changed literal moves the
    flat line for all time; a constant DS shows the step); in exchange it
    costs nothing - no DS in every file, no value on every instance line,
    no U case. Per-instance or evolving -> threshold DS; universal and
    static -> literal. Mixing forms on one base metric is normal (dynamic
    warn curve + fixed crit literal). A literal renders as a flat HRULE;
    persistence is uniform - the fileset index carries the full relation
    (relop, operand, severity) either way, a literal is just a relation
    with no DS behind it.
    Example: "THRESHOLD:read_ms:>read_ms_warn:warn". The line declares ONLY the
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
    severity IS a rule, so the declared form is the producer's DEFAULT, never
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
  - Severities: warn|crit only, nothing else - a crossing that means
    "fine" is not a threshold. The color mapping (warn->yellow, crit->red)
    lives in the xymon consumer, never on the wire.
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
  level needs no separate mechanism either: a per-instance or evolving
  fixed level is a constant-valued threshold DS (the step stays visible
  when it changes); a universal static one is a literal operand
  ("THRESHOLD:read_ms:>200:warn") in the same grammar slot. So the entire
  wire surface for thresholds is ONE line in ONE marker: THRESHOLD in the
  METRICS block.
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

