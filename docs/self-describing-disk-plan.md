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
