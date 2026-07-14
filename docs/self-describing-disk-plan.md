# Implementation plan: self-describing disk (metric block replaces do_disk)

Goal: let the stock `disk` (and `inode`) column be produced as a self-describing
METRICS block instead of the built-in `do_disk` handler, without breaking
filenames, history, graphs, or old clients. This is the endpoint the
linecount-hint fix (feat/disk-linecount-hint) was the pragmatic first step of.

It requires two capabilities that neither existing branch has alone, so this
branch is the integration point of both.

## Base: merge of two branches

This branch (`feat/self-describing-disk`) is based on `feat/self-describing-metrics`
(the engine: marker writer + content routing) and must merge in `feat/test-cfg`
(the config surface: `TEST`/`METRIC`/`HANDLER`).

Merge status (measured): four conflicts, all additive - both sides add to the
same regions, none are logic clashes:

- `include/libxymon.h` - both append includes; keep both.
- `lib/Makefile` - both add objects to XYMONLIBOBJS; keep both.
- `lib/xymonrrd.c` - self-describing adds the gdef metadata + MAXINSTANCESPERIMAGE/TRENDS
  overlay in `rrd_setup`; test-cfg adds the `testcfg` column->RRD overlay in the
  same function. Both edits are sequential additions; interleave them.
- `lib/htmllog.c` - self-describing adds marker rendering + fileset-unknown
  paging; test-cfg adds the GRAPHS override + COUNTLINES membership. Different
  spots in the same function; keep both.

Step 0 is to perform this merge and resolve the four files additively, then
re-run both branches' full suites (they must stay green - the two feature sets
are orthogonal at runtime).

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

### Feature 2 - HANDLER reroutes RRD creation off the built-in handler

Problem: the dispatcher in `xymond/do_rrd.c` (`update_rrd`) checks built-in
handler ids first (`if (strcmp(id,"disk")==0) do_disk_rrd(...)`), and content
routing is only the fallback. So a `disk` status carrying a METRICS block still
goes to `do_disk_rrd` -> double write. To make the block the sole writer, the
`disk` column's routing id must be overridden away from `disk`.

Fix: the test.cfg `HANDLER` override already sets a column's routing id
(`testcfg_rrdname` returns `t->handler` first). Needs:

- `test.cfg`: `TEST disk { HANDLER markers; METRIC disk { ... } }` makes
  `find_xymon_rrd("disk")` resolve to a marker route rather than the `disk`
  handler.
- `xymond/do_rrd.c`: today content routing is a fallback *after* the handler
  chain. Add: when the resolved id is the marker route (or `HANDLER markers` is
  in force for the column), dispatch to the marker writer and do NOT fall into
  the built-in `disk` branch. Equivalent: let an explicit id of `markers` route
  to `do_devmon_rrd` in the id chain.
- Precedence (already in the test-cfg model): HANDLER > TEST2RRD > built-in name
  match > marker auto-detect. This commit makes the HANDLER win actually retire
  the built-in for that column.

Scope: needs both branches (routing engine from self-describing, HANDLER config
from test-cfg) - hence this integration branch.

## The disk metric block itself

With features 1 and 2 present, express disk as a metric:

1. `test.cfg`:
   ```
   TEST disk {
           SOURCE client
           HANDLER markers
           METRIC disk { }          # files disk,<mount>.rrd via feature 1
   }
   ```
2. The status body carries a METRICS block whose instance lines are the
   filesystems, with the DS the `[disk]` gdef already expects (percent-used,
   etc. - collision 3, mechanical: match do_disk's dataset names/values).
3. Who emits the block: the server-side `unix_disk_report` in
   `xymond/xymond_client.c` (same place the linecount hint lives) is the natural
   producer - it already iterates the filesystems, knows the post-IGNORE set,
   and computes the values. It appends the METRICS block to the status it builds.
   The shell client is unchanged (still ships raw df); the block is synthesised
   server-side from the parsed df. This keeps old clients working and avoids a
   wire-format change on the client.
   - Consequence: the `<!-- linecount -->` hint becomes redundant for disk (the
     block's instance count is exact and derived) and can be dropped for the
     columns that carry a block, kept for those that do not.
4. do_disk retired for the column via feature 2; `do_disk_rrd` still exists for
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

## Phasing (commits on this branch)

1. Merge test-cfg; resolve the four additive conflicts; both suites green.
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
  two feature branches that are themselves not yet merged upstream. Sequence
  after those land, or keep as a proving branch.
