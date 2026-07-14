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

### Feature 1 - the writer honours a metric-declared filename convention

Problem: `do_disk` writes `disk,root.rrd` (via `setupfn2("%s%s.rrd","disk",",root")`),
while the marker/devmon writer hardcodes `setupfn2("%s.%s.rrd", base, inst)` ->
`disk.root.rrd`. Different separator, so a naive block would create a parallel,
differently-named RRD set and orphan 20 years of history.

Fix: give the METRICS block control of its instance->filename mapping so it can
reproduce the existing names exactly.

- Wire format: an optional attribute on the block banner declaring the file
  template, e.g.
  `<!--XYMON METRICS: disk fnfmt=%s,%s`
  (default stays `%s.%s` for existing marker columns - fully backward
  compatible). Or a per-instance escape: emit the instance already in the
  ",root" form and a template that concatenates.
- Writer (`xymond/rrd/do_devmon.c`): where it currently builds
  `setupfn2("%s.%s.rrd", rrdbasename, ifname)`, honour the declared template.
  Validate the template (exactly two `%s`, no path separators beyond the
  sanitisation already added) so a hostile status cannot craft a filename.
- Result: `disk,root.rrd` produced identically -> existing files continue,
  the `[disk]` gdef's FNPATTERN still matches, no migration.

Scope: this is self-contained on the writer; it does not need test.cfg. It could
even land on `feat/self-describing-metrics` independently. Kept here so the disk
block has a home to use it.

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

None required if feature 1 reproduces `disk,root.rrd` exactly. Verify by
diffing the filenames the block path produces against a pre-change `do_disk`
run for the same df input - they must be byte-identical. That equality is the
acceptance test for feature 1.

## What this buys beyond paging

- Exact paging (already had it via the hint) - now derived, not counted.
- Alerting on the stored RRD values via DS/AGGDS rules (from self-describing) -
  disk % used becomes a first-class metric, not just a status colour.
- disk stops being a special-cased built-in handler and becomes an ordinary
  declared metric - one less bespoke code path, the general model absorbing a
  legacy one.

## Phasing (commits on this branch)

1. Merge test-cfg; resolve the four additive conflicts; both suites green.
2. Feature 1: writer honours `fnfmt`; test: block path reproduces do_disk's
   filenames byte-for-byte.
3. Feature 2: HANDLER routes a column to the marker writer, retiring the
   built-in; test: a disk status with a block writes once (no do_disk double).
4. `unix_disk_report` emits the METRICS block (DS matching the gdef); drop the
   linecount hint for block-bearing disk; end-to-end test: files, DS, graph,
   and an AGGDS/DS alert on disk% all work; old-client df-only path unchanged.
5. Docs: test.cfg disk example; note disk is now a declared metric.

## Risks / watch-items

- Filename equality is load-bearing: any deviation orphans history. Byte-diff
  test is mandatory, not optional.
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
