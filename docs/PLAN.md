# xymon — plan

## xymonping: single event queue for probing — **DONE**

The refactor described below is complete. Smoke mode landed in
`c8827d10`; legacy mode joined the same heap in `58f7aff7`. Kept as
historical design context for the unified `legacy_main_loop` /
`smoke_main_loop` shape.

### Motivation

`xymonping` currently uses a synchronous send-loop with a `pending` host
counter (`xymonnet/xymonping.c`). Smoke mode (`--samples=N`) was bolted on by
wrapping `sendidx` back to 0 and adding a sample-aware loop predicate. Two
consequences:

1. `pending -= count` and "every probe is a separate event" don't fit on the
   same loop. We patched the predicate (commit `60ed69ce`) but the underlying
   model mismatch remains.
2. All N probes for one host fire as fast as the socket accepts, so smoke
   distributions get compressed into a small window instead of spreading
   across the cycle. fping spaces probes with `opt_perhost_interval` (`-p`),
   which is the smokeping convention.

A single shared event timeline removes both issues structurally and gives us
the same model the reference fping has had since the count-mode rewrite.

### Architecture

- One min-heap keyed by `when_ns`. Each entry is `{when, kind, host_idx,
  probe_idx}`. Two `kind`s: `EV_SEND` and `EV_EXPIRE`.
- `main_loop()`:
  1. `now = clock_gettime()`.
  2. Pop all events with `when <= now`. Dispatch.
  3. Sleep in `select(socket, …, heap.top().when - now)`. Process any reply
     that wakes us. Repeat.
  4. Exit when the heap is empty.
- No `pending`, no `tries` outer loop, no wrap-around.

### Per-host state

Extend `hostdata_t`:

```c
typedef struct hostdata_t {
    /* existing fields */
    uint8_t        *probe_state;     /* SCHED | SENT | REPLIED | EXPIRED | ERROR */
    struct timespec *probe_sent_at;  /* one per probe, for RTT */
    /* samples_usec stays — populated on REPLIED */
} hostdata_t;
```

`probe_state` size is `max(1, samples_count)` (or `tries` in legacy mode — see
below). Allocated once in `load_ips()`.

### Reply matching

Today `pingdata_t` (the ICMP payload) carries `{ id, timesent }` where `id`
is the host index. Add `probe_idx`:

```c
typedef struct pingdata_t {
    int id;          /* host_idx */
    int probe_idx;   /* 0..N-1 */
    struct timespec timesent;
} pingdata_t;
```

`get_response()` extracts both, marks `probe_state[probe_idx] = REPLIED`,
computes RTT, stores into `samples_usec[probe_idx]`. This keeps `icmp_seq`
free for kernel-level diagnostics and avoids the 256-host or 256-probe limit
a bit-packed `icmp_seq` would impose.

### Send-error handling (matches fping)

- `EWOULDBLOCK`: re-enqueue the same `EV_SEND` `1ms` later. Bounded retries
  (e.g. 5) to avoid livelock on a permanently full socket.
- Any other error: `probe_state = ERROR`, increment `sent`, do NOT enqueue
  `EV_EXPIRE` (no reply will ever arrive). The reported `loss=K/N` then
  reflects the attempt accurately, which is what fping does:
  `h->num_sent++; resp_times[index] = RESP_ERROR; ret = 0;`

This also closes the theoretical loop-forever case I flagged earlier in the
current wrap-around code.

### Pacing

Default `per_host_interval = send_window / samples_count` where
`send_window` is bounded by xymonnet's own timeout (typically a few seconds
of the 5-minute cycle). Probes for a single host are spread; probes across
hosts interleave naturally because they all share the heap. Configurable via
a new `--per-host-interval=ms` option; default keeps current behaviour for
non-smoke runs.

### Termination

Heap empty ⇒ exit. `EV_EXPIRE` events are pruned as soon as a matching
`REPLIED` is observed (or left in the heap and ignored on dispatch — simpler,
costs one heap pop per missing reply, negligible at smoke cardinalities).

### Legacy mode (`samples_count == 0`)

Each host gets one `EV_SEND` at `t=0` and one `EV_EXPIRE` at `t=timeout`. On
`EV_EXPIRE` without `REPLIED` and `tries > 0`, schedule another `EV_SEND`
immediately and another `EV_EXPIRE` at the new send time + timeout. Retry
budget is the existing `tries` count, just expressed through the heap. The
host's `received` field still drives `minresponses`-style exit (zero retries
once a host has answered).

### Migration

Done. Stage 1 (shadow accounting) was skipped -- went directly to the
heap-driven Stage 2 once the design held up to review. Stage 2 (smoke
mode on the heap) landed in `c8827d10`. Stage 3 (legacy mode on the
same heap; deleted `pending`, `count_pending`, `send_ping`, the
`tries`-loop, the wrap-around block) landed in `58f7aff7`. The legacy
function `legacy_main_loop` is ~100 lines, the smoke function
`smoke_main_loop` ~150 lines, both driven by the same `pingevent_t`
heap defined in `evheap.h`.

### Tests

- Unit-test the heap (`lib/test-evheap` or inline in `xymonping`):
  insert/pop ordering, stable ordering for equal `when`, cancel-by-flag.
- Build a fake-socket harness for `xymonping`: deterministic replies/drops
  fed through `get_response`'s decoding path. Drive end-to-end scenarios
  without root or raw sockets:
  - all-responsive 1 host × 20 samples → 20 samples written
  - 1 host × 20 samples × 25 % loss → `loss=5/20`, 15 samples in RRD
  - 1 host hard send error → `loss=N/N`, no infinite loop
  - 10 hosts × 5 samples each → interleaving spreads probes
- Re-run `lib/test-smokeping` (unchanged) to confirm parser/format are
  untouched.

### Out of scope

- Wire-format changes consumed by `do_net.c`: still
  `samples=v1,…,vN loss=K/N`.
- A second smoke probe (DNS smoke, HTTP smoke) — the lib helpers already
  support this; the probe loop refactor is independent.
- Switching the cycle scheduler. xymonping is still launched once per
  xymonnet cycle.

### Open questions

1. Pacing default: derived from `--max-pps`, or a new `--per-host-interval`
   knob with sensible default? Lean toward the latter — `--max-pps` is a
   global throttle, not a per-host spacing.
2. Heap implementation: hand-rolled tiny binary heap (~80 lines) or pull in
   something existing? Project has no STL/equivalent; rolling our own keeps
   dependencies flat.
3. Cancel-on-reply vs ignore-on-dispatch for `EV_EXPIRE`. Ignore-on-dispatch
   wins on simplicity if heap turnover stays small.
4. ~~Should Stage 3 happen at all, or is keeping legacy mode untouched cheaper
   long term?~~ Stage 3 done; the legacy code being deleted (~145 lines
   of `pending`/`count_pending`/`tries`-loop/wrap-around) justified the
   surgery on its own. End-to-end smoke + legacy behaviour matches the
   previous implementation (localhost responsive: ~1ms; unreachable
   target: drops out after the retry budget elapses, no infinite loop).

## Decisions

- **Merging `feat/smokeping-probe` + `feat/trends-graph-aggregation` into
  `main`: refused.** Branches stay independent on origin; rebase target
  for these features remains `main` (smoke currently sits on top of
  trends via rebase). Future merges -- if any -- are not part of this
  plan.
