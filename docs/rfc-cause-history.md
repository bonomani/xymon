# RFC: Cause history — record cause changes within a sustained color

**Status:** Draft
**Author:** Bonomani
**Related:** status history (`xymond_history`), `histsync` (TBT 228 / devel `0e18ae21`), histlogs (`SAVESTATUSLOG`)

## Summary

Xymon's status history records only **color transitions**. When a test stays
the same color but its **cause changes** — red for `/var` full, then red for
`/tmp` full, then red for inode exhaustion — history shows a single unbroken red
entry, and the sequence of causes is lost. This RFC proposes recording
significant **same-color cause changes** without disturbing the color-transition
history that availability/SLA reporting depends on.

## Motivation

The status-events log (`HISTDIR/HOSTNAME.testname`) is an **availability**
record: `timestamp color changetime duration`. That is deliberate and must stay
color-only — SLA math ("how long was it red?") depends on it.

But operators frequently want the **forensic** view: *while it was red, what were
the reasons, and when did each start?* Today that is unavailable between color
transitions. Example — a `disk` test red for 3 hours:

```
current color log:   Mon 10:00 red 1097... 10800     (one row, 3h)
what actually happened:
  10:00 red  "/var 98% full"
  10:40 red  "/tmp 95% full"      <- not recorded anywhere
  11:30 red  "/var 91%, /tmp 99%" <- not recorded anywhere
```

## Non-goals

- **Not** changing the color-transition log format or semantics (availability
  history stays exactly as-is).
- **Not** a full per-message audit trail (every poll). See "Significance" —
  recording every content byte-diff is an explicit non-goal.
- **Not** an alerting change. Alerting keys off color; this is history only.

## Background — why xymond_history never sees it today

Same-color changes are filtered **at the source**, in `xymond.c`:

```c
/* xymond.c:1802 — only color changes (or forced resync) go to stachg */
if (!issummary && (!log->histsynced || (log->oldcolor != newcolor))) {
    posttochannel(stachgchn, channelnames[C_STACHG], msg, sender, hostname, log, NULL);
}
```

`xymond_history` is the `stachg` worker, so it is only ever handed **color
changes** (or resyncs). Its own read-back-and-compare in `save_statusevents()`
is a *re*-check plus drift detection, not the primary filter. Any cause-history
feature must therefore solve two problems: **(1) get the events to a consumer**,
and **(2) store them without bloating the availability log.**

The full message content is already snapshotted to **histlogs**
(`save_histlogs` / `SAVESTATUSLOG`) — but, like the color log, **only at color
transitions**, because the whole processing path is gated on receiving a
`stachg`. So histlogs are the natural home for cause snapshots; they just are not
currently triggered on same-color cause changes.

## The three decisions this feature hinges on

### 1. Significance — what is a "cause change"? (the crux)

Status text churns every poll (`disk 91%` -> `disk 92%` -> `disk 91%`). Recording
every diff reproduces the noise the color-dedup exists to avoid. A trigger must
be defined. Candidates, roughly increasing fidelity/cost:

- **A. First status line / summary changed** — cheap, catches most real
  cause shifts, ignores trailing detail churn.
- **B. Sub-status set changed** — the set of `&red`/`&yellow` component lines
  (which specific checks are failing), compared as a set. Catches "which thing
  is wrong" precisely; ignores numeric jitter within a line.
- **C. Normalized full-text diff** — strip numbers/timestamps, compare the rest.
  Highest fidelity, most fragile, most expensive.

**Recommendation: B (sub-status set), with A as a fallback** for tests without
structured sub-status. The unit of "cause" in Xymon is the failing component,
not the exact percentage.

### 2. Throttling — causes flap too

Even with a significance filter, a cause can oscillate (A->B->A->B). Needs:

- **dedup against the last recorded cause** (don't record A->A), and
- a **minimum interval** and/or **per-test cap** (e.g. at most one cause snapshot
  per N seconds, or per M per hour) with a `log()`'d drop count so silent
  truncation is visible.

### 3. Storage — where it lives

**Keep it out of the color-transition log.** Two viable homes:

- **B1 (recommended): extra histlog snapshots.** On a significant same-color
  cause change, write a histlog snapshot exactly as done at a color transition.
  Availability history untouched; "what did it say over time" lives where full
  content already belongs. The web history view already lists histlog snapshots.
- **B2: a separate cause-event log** — a new lightweight per-test file
  `timestamp color cause-summary`. More structured/queryable, but a new format,
  new file, new retention/trim path (`trimhistory`), new web rendering.

## Proposed design (phased)

**Plumbing — get same-color cause changes to a consumer.** Two options; this is
the real engineering cost:

- **P1: new throttled signal.** Keep `stachg` color-only. Add a distinct,
  significance-filtered + throttled "cause changed" notification (new channel or
  a flagged message) consumed only by history. Isolated blast radius; xymond
  does the significance/throttle so workers stay simple.
- **P2: widen the `stachg` gate.** Also post to `stachg` on a significant cause
  change. Simpler to wire, but **every** `stachg` consumer (alerting escalation,
  history, third-party workers) now sees more traffic — a behavioural change with
  wide blast radius. Discouraged.

**Recommendation: P1 + B1 + significance B + throttle.** xymond computes
"significant cause changed?" (decision #1) under a throttle (decision #2), emits
a throttled signal (P1), and `xymond_history` (or a small dedicated worker)
writes a histlog snapshot (B1). Color history and alerting are untouched.

### Phasing

- **P0 — decide the significance model (#1).** Everything hangs on this. Prototype
  B (sub-status set) offline against real status streams; measure event volume
  per test before writing any persistence code. *Build nothing until this is
  settled — otherwise the result is a noise-cannon.*
- **P1 — plumbing.** Implement the throttled cause-changed signal (P1) with the
  significance filter + throttle in xymond. No persistence yet; just `log()` the
  rate to validate volume assumptions on a live server.
- **P2 — persistence.** Snapshot to histlogs (B1) on the signal. Wire retention
  (`trimhistory`) and the web history view to show cause snapshots distinctly
  from color transitions.
- **P3 — controls.** Per-column enable/disable + throttle tuning via config
  (mirroring `SAVESTATUSLOG` granularity).

## Interaction with existing mechanisms

- **`histsync` (TBT 228 / `0e18ae21`):** the drift-reconcile path. Complementary
  — histsync repairs the color log against disk; this adds cause snapshots.
  Neither changes the other.
- **Availability/SLA reports:** unaffected — they read the color log, which this
  RFC does not touch.
- **`trimhistory`:** must learn to age cause snapshots (B1: they are just more
  histlogs, so largely for free; B2: needs new handling).

## Alternatives considered

- **Record every content change (no significance filter).** Rejected — history
  bloat + noise; defeats the point of a readable history.
- **Extend the color-transition log with cause rows.** Rejected — pollutes the
  availability record SLA math depends on, and changes a long-stable format.
- **Client-side cause logging.** Rejected — causes are server-side status
  concepts; the client does not know Xymon's color/sub-status model.

## Open questions

1. Significance model B vs A vs a hybrid — decide against **measured** event
   volume on real data (P0).
2. P1 signal shape — new channel vs flagged message on an existing one?
3. Default throttle (interval / per-hour cap) and whether it is per-test or global.
4. Web presentation — inline in the existing history view, or a separate
   "cause timeline"?
5. Retention policy for cause snapshots vs color-transition history.

## Decision requested

Agreement on **P1 + B1 + significance model B** as the direction, and sign-off to
start with **P0** (offline significance prototype + volume measurement) before any
code lands.
