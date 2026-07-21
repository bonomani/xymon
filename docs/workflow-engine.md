# xymond_workflow: native workflow engine design

Design doctrine for a durable runbook engine inside Xymon: detect a state
change, execute a sequence of actions with retries, timeouts and human
approval, and report progress back as a first-class Xymon status. This
document records the decided architecture and the reasoning behind each
decision, so none of them is relitigated by accident.

Status: design phase. Implementation is a post-absorption chantier; nothing
in this document is on a release path yet.

## Scope and non-goals

- The engine automates *reactions* to monitoring state: restart-verify-
  escalate-ticket class runbooks. It is not a general-purpose orchestrator;
  if a runbook needs DAGs, fan-out or cross-host sagas, use a dedicated
  engine (Temporal, StackStorm) behind a bridge worker instead - that
  alternative stays valid and is deliberately not foreclosed by this design.
- alerts.cfg is untouched. xymond_alert answers "who do I tell, how often";
  the workflow engine answers "what do I *do*, in what order, with what
  state". Paging is not duplicated: a runbook that wants to page does it by
  publishing status (which alerts.cfg rules then see), never by notifying
  directly.
- Nothing in this design adds a wire command, a channel, or a client-side
  change. The engine consumes existing surfaces (stachg, xymondboard,
  hostinfo, ack state) and produces existing surfaces (status messages).

## Architecture doctrine (settled)

- **A channel worker, never xymond core.** xymond_workflow is a standalone C
  worker fed stachg messages on stdin, declared in tasks.cfg like any other
  task. xymond does not know the engine exists. Rationale: the board's
  in-RAM mutation path is the hottest loop in the product and stays free of
  serialization; the engine's blast radius on failure is one worker.
- **stachg, not status, is the trigger feed.** stachg only fires on color
  transitions, so event rate is decoupled from host count x test count.
  This is what makes per-event durable commits affordable.
- **Workflow state is the exception that earns durability.** Xymon's design
  contract is that worker state is disposable because the next client cycle
  regenerates it. An execution state ("step 3 of runbook X on host Y,
  awaiting approval") is the one in-flight state that is NOT reconstructible
  from any future message. It therefore lives in a real transactional store,
  owned by the worker, committed on every transition.
- **JSON at the boundary, never on the wire.** The Xymon wire stays
  line-oriented. The engine emits JSON in exactly one place: the full
  instance context on an action script's stdin (env vars carry the
  xymond_alert-compatible basics). The engine never parses JSON from the
  wire; callbacks from scripts are exit codes, not documents.
- **Human-in-the-loop via existing primitives.** GATE steps observe the ack
  state of the related status through existing queries. Approving a gate ==
  acking the status. No new UI, no new command.
- **Progress is published as status.** Each active instance maintains a
  column (default: workflow) on its host - visible, historized, alertable
  like everything else. The engine's own health is a status too.

## Definition language

workflow.cfg uses the brace-config grammar (lib/braceparse, arriving via the
self-describing-metrics branch decomposition - this is a declared dependency,
not yet on main). One section per runbook:

    runbook disk-full {
        MATCH host=web% test=disk color=red
        STEP restart  { RUN cleanup.sh          TIMEOUT 2m RETRY 2 }
        STEP verify   { WAIT color!=red         TIMEOUT 10m }
        STEP approve  { GATE ack                TIMEOUT 1h }
        STEP escalate { RUN open-ticket.sh }
    }

- MATCH selects trigger transitions: host/test patterns (same matching
  family as alerts.cfg rules) plus the color predicate on the transition.
- Steps execute strictly in order. Verbs: RUN (fork/exec a script), WAIT
  (block until a board predicate holds), GATE (block until human ack),
  each with TIMEOUT; RUN carries RETRY. A step timeout advances to the
  next step by default; ABORT as an explicit alternative.
- One active instance per (host, test, runbook). A new matching transition
  while an instance is active is recorded on the instance, not spawned.

## Execution model

Single-threaded event loop over three wakeup sources: a stachg message on
stdin, a timer expiry, a child (action script) exit. Every transition of an
instance is one store commit. There are no other blocking points.

Action semantics are **at-least-once**: the transition to "running step N,
attempt K" is committed *before* the exec. A crash between commit and child
exit replays the action on restart. Consequence, stated as a hard contract
in xymond_workflow(8): action scripts MUST be idempotent or guard
themselves. Exactly-once is not promised because it is not achievable with
side-effecting scripts; pretending otherwise is how dedicated workflow
engines earn their living.

Restart/reconcile: on start the engine reloads all instances, re-arms
timers from stored deadlines, and reconciles against the current board
(xymondboard) - WAIT predicates are re-evaluated against present colors, so
transitions missed while the worker was down are absorbed by observing
state instead of replaying a stream. This bounds the non-reconstructibility
to exactly the execution state itself.

## The store: LMDB

Decision record - LMDB over the two alternatives:

- Hand-rolled checkpoint files (the xymond_alert pattern): rejected because
  workflow state is mutation-heavy and non-reconstructible; periodic
  full-file rewrite reintroduces the un-checkpointed-window bug class that
  issue #201 documented for the board.
- SQLite: fine engineering, rejected on fit. The access patterns are fixed
  key/value lookups (instance by id, instances by (host,test), deadline
  scan); no ad-hoc query capability is needed, and embedding SQL strings in
  a C worker buys schema machinery the data does not have. LMDB's C API
  matches the shape directly.
- LMDB costs accepted: map-resize handling, and records are C structs that
  need explicit versioning for schema evolution (a version byte per record
  from day one). Dependency cost is near zero: liblmdb is packaged
  everywhere as an OpenLDAP dependency.

Layout: one environment, three DBs - instances (id -> record), bykey
((host,test,runbook) -> id, enforces the one-active-instance rule),
deadlines (time -> id, the timer wheel's persistent image). Writes are one
transaction per transition; group commit is available if a site ever
produces enough transitions to want it (none should - see cost).

## Steady-state cost

writes = color transitions/s x 1 LMDB txn. stachg rate on a large site is
orders of magnitude below status rate; the board's hot path is untouched;
reads are mmap. Memory is the mapped file, managed by the OS. If a
deployment's stachg rate is in doubt, measure it (count stachg
messages/minute on the real instance) before tuning anything.

## Phasing

- P0: parser (braceparse dependency), instance store, MATCH + RUN/WAIT/GATE
  /TIMEOUT/RETRY, at-least-once replay, board reconcile on start, progress
  column. This is the whole credible core; nothing smaller demonstrates the
  durability contract.
- P1: ABORT semantics, per-runbook concurrency overrides, instance history
  retention and a listing CGI.
- Explicit non-P0: cross-host runbooks, parallel steps, script-to-engine
  callbacks richer than exit codes.

## Open questions

- WAIT predicate grammar: color comparisons only, or the full analysis.cfg
  expression family? Start color-only; widening later is additive.
- GATE and multi-ack policies (any ack vs specific user) - needs a look at
  what ack metadata the board actually exposes before promising user-level
  gating.
- Whether the progress column is per-host singular (workflow) or per-runbook
  (workflow.<name>) - decide when the listing CGI is designed, they trade
  page noise against drill-down.
