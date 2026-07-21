# xymond_workflow: native workflow engine design

Design doctrine for a durable runbook engine inside Xymon: detect a state
change or an application event, execute a sequence of actions with retries,
timeouts and human approval, and report progress back as a first-class Xymon
status. This document records the decided architecture and the reasoning
behind each decision, so none of them is relitigated by accident.

Status: design phase. Implementation is a post-absorption chantier; nothing
in this document is on a release path yet.

## Scope and non-goals

- The engine automates *reactions* to monitoring state and *commanded*
  sequences: restart-verify-escalate-ticket runbooks, gateway file
  transfers, deploy-on-request. It is not a general-purpose orchestrator;
  if a runbook needs DAGs, fan-out or cross-host sagas, use a dedicated
  engine (Temporal, StackStorm) behind a bridge worker instead - that
  alternative stays valid and is deliberately not foreclosed by this design.
- alerts.cfg is untouched. xymond_alert answers "who do I tell, how often";
  the workflow engine answers "what do I *do*, in what order, with what
  state". Paging is not duplicated: a runbook that wants to page does it by
  publishing status (which alerts.cfg rules then see), never by notifying
  directly.
- Nothing in this design adds a wire command, a channel, or a client-side
  change. The engine consumes existing surfaces (stachg, user, xymondboard,
  hostinfo, ack state) and produces existing surfaces (status messages).

## Architecture doctrine (settled)

- **A channel worker, never xymond core.** xymond_workflow is a standalone C
  worker fed channel messages on stdin, declared in tasks.cfg like any other
  task. xymond does not know the engine exists. Rationale: the board's
  in-RAM mutation path is the hottest loop in the product and stays free of
  serialization; the engine's blast radius on failure is one worker.
- **stachg, not status, is the color trigger feed.** stachg only fires on
  color transitions, so event rate is decoupled from host count x test
  count. This is what makes per-event durable commits affordable.
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
- **Roles, not servers.** Monitoring (xymond), workflow (the engine) and
  the transfer gateway are three roles with narrow, already-transportable
  interfaces. Colocation on one server is a deployment choice, never a code
  assumption. See "Deployment topologies".

## Definition language

workflow.cfg uses the brace-config grammar (lib/braceparse, arriving via the
self-describing-metrics branch decomposition - this is a declared dependency,
not yet on main). One section per runbook:

    runbook disk-full {
        MATCH color host=web% test=disk color=red FOR 10m
        STEP restart { RUN cleanup.sh  TIMEOUT 2m RETRY 2 }
        STEP verify  { WAIT color!=red TIMEOUT 10m ON_OK done ON_TIMEOUT continue }
        STEP approve { GATE ack        TIMEOUT 1h  ON_TIMEOUT continue }
        STEP ticket  { RUN open-ticket.sh }
    }

Reading: cleanup, then wait for green - fixed means the instance completes
(ON_OK done); still red after 10 minutes means fall through to human
approval, then a ticket. A cleanup failure fails the instance (the
default), it does not silently escalate.

- MATCH selects the trigger. Its first word names the source (see "Trigger
  taxonomy"); the rest are source-specific predicates. Host/test patterns
  use the same matching family as alerts.cfg rules.
- Steps execute strictly in order. Verbs: RUN (fork/exec a script), WAIT
  (block until a board predicate holds), GATE (block until human ack),
  each with TIMEOUT; RUN carries RETRY.
- **A step timeout FAILS the instance by default.** The earlier draft had
  timeouts fall through to the next step; review round 1 killed that - a
  timed-out cleanup silently falling into an escalate step is a surprise
  no operator should meet. Advancing past a timeout or a failure is
  explicit routing: ON_FAIL / ON_TIMEOUT / ON_OK clauses whose target is
  `continue`, `done` (complete the instance), `fail`, or a step name.
  Minimal branching, in P0 - real runbooks need failure routing before
  they need anything else. Falling past the last step completes the
  instance.

## Trigger taxonomy

Three sources, two in P0:

    MATCH color  host=web% test=http color=red FOR 10m    # state transition
    MATCH event  type=deploy-request                      # user channel
    MATCH cron   03:00                                    # timer (P1)

- **color** (stachg): reactive runbooks. One active instance per
  (host, test, runbook); a matching transition while an instance is active
  is recorded on the instance, not spawned - this is the engine's built-in
  flap dedup.
- **event** (the user channel): commanded runbooks. The existing usermsg
  wire command routes arbitrary application messages to the user channel -
  a designed extension point, zero new surface, near-zero latency (no
  client cycle involved). Any script or CI emits
  `xymon $XYMSRV "usermsg workflow deploy-request app=billing v=2.4.1"`.
  Instance policy is inverted: each event spawns an instance by default,
  with an optional DEDUP key to absorb duplicate emissions. The event body
  travels verbatim into the instance context and the action scripts' JSON
  stdin; the by-reference payload rule applies (identifiers, not data).
- **cron** (P1): the timer wheel already exists, a scheduled trigger is
  nearly free - but it is not needed to prove the durability contract.

Two channels mean two tasks.cfg entries (one xymond_channel feed each)
sharing one LMDB environment. LMDB's multi-process locking makes that safe
natively - a second place the store choice pays off (hand-rolled checkpoint
files would have made shared writers a project of their own).

### Damping: the color is already a policy output

Xymon damps *before* the color changes: badconn=/bad<test>= (N consecutive
failures before red), delayred=/delayyellow= (time before showing),
analysis.cfg rules, xymond flap detection. Doctrine: **the engine consumes
colors, it never re-judges them.** A red transition on stachg is a
site-policy-confirmed condition.

FOR is therefore not a default debouncer but a deliberate *action threshold
stricter than the display threshold*: show red at 2 failures (humans should
see it fast), remediate only after 10 persistent minutes (actions cost more
than a glance). Semantics: on the matching transition the engine arms a
timer; at expiry it re-reads the board and starts the instance only if the
condition still holds. Stacked delays add up - cadence x badconn count +
FOR is the reaction budget, computed per runbook, not suffered.

The full chain, each layer answering its own question:

| Layer     | Question              | Tool                          |
|-----------|-----------------------|-------------------------------|
| test      | is it really broken?  | cadence, badconn, analysis.cfg|
| display   | when to show it?      | delayred/delayyellow          |
| alerting  | when to page a human? | alerts.cfg DURATION           |
| workflow  | when to act alone?    | MATCH + optional FOR          |

State-observation tests (files present in a drop directory) are binary
facts, not error probes: they need no damping, first cycle wins, and the
depositing process can push the status immediately for near-zero latency.
File-arrival detection is monitoring - no inotify daemon, no ingest API.

### Trigger trust

The engine turns messages into command execution, and the Xymon wire is
weakly authenticated by default (sender-IP checks). Stated plainly: a
forged status that drives a test red, or an injected usermsg, is a remote
runbook trigger. Deploying the engine RAISES the attack value of the Xymon
server; the design must say so and layer the defenses:

- xymond's sender restrictions (the --status-senders/--admin-senders
  family) are the first gate: constrain which addresses may post status
  and usermsg at all. A site that runs the engine without sender
  restrictions is accepting message-forgery as a trigger path.
- FOR forces an attacker to *sustain* a forged condition across re-checks,
  not fire once.
- The gateway's forced-command and the egress firewall bound what a
  triggered runbook can reach regardless of why it triggered; TARGETS
  (P1) narrows it per runbook.
- Event runbooks that perform sensitive actions should require a GATE step
  - the human approval is then part of the trigger path, not a courtesy.

### Storm control (P0)

Mass failure is the canonical auto-remediation disaster: a network outage
flips 500 hosts red, 500 instances spawn, 500 concurrent scripts hammer
the infrastructure that is already down. Two mechanisms, both P0 because
an engine without them is dangerous on its worst day, which is the day it
runs:

- A global concurrency cap on running instances (with per-runbook
  overrides in P1); excess triggers queue in arrival order.
- A circuit breaker: more than N trigger matches per minute freezes new
  instance creation and turns the engine's own status column red. A storm
  is a signal for humans, not a work queue - the engine deliberately sits
  down and says so.

## Execution model

Single-threaded event loop over three wakeup sources: a channel message on
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
  matches the shape directly, and its multi-process locking covers the
  two-feed layout for free.
- LMDB costs accepted: map-resize handling, and records are C structs that
  need explicit versioning for schema evolution (a version byte per record
  from day one). Dependency cost is near zero: liblmdb is packaged
  everywhere as an OpenLDAP dependency.

Layout: one environment, three DBs - instances (id -> record), bykey
((host,test,runbook) -> id, enforces the one-active-instance rule for
color triggers), deadlines (time -> id, the timer wheel's persistent
image). Writes are one transaction per transition; group commit is
available if a site ever produces enough transitions to want it (none
should - see cost).

## Payloads: bounded context, heavy data by reference

The instance context is bounded (single-digit KB: runbook, host, test,
step, attempts, short k/v). It is rewritten on every transition, so its
size multiplies by runbook length - that is why it stays dense. Heavy data
NEVER enters the store or the trigger path:

- Action scripts fetch what they need at execution time - current status
  via xymondlog, history via histlogs, metrics via the RRDs. Fresh state at
  step time usually beats a copy frozen at trigger time.
- Artifacts produced by steps (dumps, reports) land out of band (file,
  ticket); only the reference (path, checksum) enters the context.
- Same choice as the dedicated engines (Temporal caps payloads at ~2 MB and
  pushes references) and for the same reason: durable execution state must
  stay cheap to commit.

### File transfer: orchestrate, never transport

When a runbook moves a file, the file travels over a real transport
(rsync/scp/https), executed by action scripts; the workflow state carries
path + sha256 + per-leg status - grams, whatever the file weighs. File
transfer is the ideally at-least-once-compatible action: a replayed rsync
is naturally idempotent once a verify step seals checksums.

Hard red line: **the Xymon wire is never a file transport.** Two distinct
reasons: (doctrine) the monitoring channel carries state, not data;
(security) a monitoring wire that moves arbitrary files between hosts turns
the Xymon server into a lateral-movement hub - compromising xymond would
grant file read/write across the estate. That line is what separates a
monitoring agent from an administration agent. The existing `download`
command (client pulls config/clientupdate files from the server's download
directory) is a bounded, client-initiated pull and must not grow into a
generic transport.

## The transfer gateway

Sites that require all external transfers to pass through one LAN
gateway/storage host get it in the action layer; the engine is untouched.

Two shapes:

- **Transit (ProxyJump):** ssh_config on the workflow host forces every
  external target through the gateway (`Host *.external / ProxyJump gw`).
  The gateway only relays TCP - it holds no target keys, sees no
  credentials, stores no file. Its authorized_keys entry pins policy:
  `restrict,port-forwarding,permitopen="b-server:22"` - even a compromised
  workflow host can only reach the declared destinations.
- **Store-and-forward (gateway/storage):** the gateway executes the
  transfers itself; runbook legs are `ssh gw transfer ...`. This buys leg
  decoupling (target down -> the file waits in staging, RETRY replays only
  the failed leg), an inspection point (AV/signing step on the gateway
  before anything leaves the LAN), and fine resume (rsync per leg). The
  workflow host then holds exactly one key (to the gateway, forced-command
  restricted); keys to the LAN and internet targets live only on the
  gateway; the firewall gives only the gateway internet egress. Auditing
  external access = auditing one machine.

Staging hygiene: /staging/<instance-id>/ per instance (no concurrent
collisions), purged by the runbook's final step after verify, with a
retention cron on the gateway as the safety net for abandoned instances -
and the staging disk is itself Xymon-monitored, closing the loop.

### The transfer wrapper: URI dispatch, native tools, YAGNI per scheme

One wrapper on the gateway, `transfer copy <src-uri> <dst-uri>` /
`transfer verify <uri> <sha256>` / `transfer purge <instance-id>`,
dispatching on the URI scheme. A reference implementation (the wrapper and
its forced-command shell) lives in docs/examples/. Decisions:

- **Exactly one side is local.** The wrapper never does remote-to-remote;
  two-leg journeys are two STEPs (that is what store-and-forward means).
  This collapses the dispatch matrix and keeps every case trivial.
- **Native tools, not rclone.** rsync (resume, big volumes), OpenSSH
  scp/sftp, curl (https/ftp). Rationale: every case stays a tool any admin
  knows and audits; no extra binary to maintain; and one rclone.conf
  holding 70 backends of credentials is a single point of compromise,
  where per-tool credentials stay compartmented per target. rclone (or a
  cloud's official CLI - the sane answer for SigV4/OAuth territory) can
  become one *case* of the dispatch later; a plugin, never the foundation.
- **YAGNI per scheme.** Start with the 2-3 schemes real flows use; a new
  scheme is a new case written the day it exists, zero change to runbooks
  or engine.
- **Exit-code contract:** 0 done, 1 transient (RETRY replays), 2 permanent
  (never replayed). The engine's RETRY only sees frank success/failure;
  the 0/1/2 convention is the wrapper's forward-looking refinement.
- **Per-transport contract**, required to accept a scheme: idempotent
  re-run; a verify method (remote sha256, or honest documentation that the
  scheme cannot verify - S3 multipart ETags are not md5, scp cannot
  resume); frank exit codes. A scheme that cannot verify is accepted but
  flagged: the runbook skips verify knowingly, traced in instance history.

Deployment surface on the gateway is configuration, not software: two
shell scripts (transfer, transfer-shell), a dedicated user, keys +
ssh_config, the authorized_keys lock, the staging tree, the egress firewall
rule. Packages needed (openssh, rsync, curl, coreutils) are the base
toolkit of any Linux server.

## Access centralization

Three layers, each owning one thing:

1. **The engine centralizes audit, never secrets.** Every RUN is logged in
   instance history and published on the progress column. Hard rule:
   neither workflow.cfg nor the LMDB store ever contains a credential.
2. **OpenSSH centralizes credentials.** A dedicated user's key material in
   one place; per-target restrictions (from=, command=) on the targets; an
   SSH CA with short-lived certificates when the estate grows (rotation
   becomes a central act). Secrets managers (Vault) are a site
   integration via the action wrapper, not an engine feature.
3. **Policy says who may reach what.** The gateway's authorized_keys and
   the egress firewall make the policy *enforced*, not conventional. A
   per-runbook TARGETS allowlist in workflow.cfg (engine refuses
   out-of-perimeter RUNs) is defense-in-depth on top - P1.

## Deployment topologies: roles, not servers

Single server first: xymond + xymond_workflow in tasks.cfg + the gateway
role (wrapper, staging, keys, egress) on one box; `ssh gw` resolves to
localhost via ssh_config. The whole design works day one.

### Role footprints: only the engine is server-bound

| Role            | Needs                                            | Xymon footprint      |
|-----------------|--------------------------------------------------|----------------------|
| engine          | xymond channels (local IPC)                      | server - the only one|
| gateway         | transfer + transfer-shell, openssh, rsync, curl  | client suffices      |
| targets (A, B)  | sshd or an endpoint                              | none (client to monitor them) |
| event emitters  | the xymon CLI                                    | client suffices      |

The gateway wants the client anyway: it monitors /staging, sshd, and runs
the drop-directory test whose color change triggers runbooks - a plain
client-side custom test. And the client package ships the xymon CLI, so
any client machine can push an immediate status or emit a usermsg trigger:
event emission is a *client* capability by construction (a deploy job, a
CI pipeline, the depositing process itself). The server thinks - engine
and store; the clients observe and act. Corollary, tying back to "Trigger
trust": the more clients may emit triggers, the more the server-side
sender restrictions matter.

Splitting is configuration, because every interface is already
transportable:

- monitoring -> workflow: channels are local IPC (shared memory), so a
  detached workflow server is fed by a one-line relay on the monitoring
  server (`xymond_channel --channel=stachg ./forward.sh` re-emitting each
  event as usermsg to the workflow server - which is itself a Xymon server
  whose xymond exists to receive them on its local user channel). The
  transport between servers is the xymon protocol; no new listener. Board
  queries (WAIT, reconcile) already work remotely - it is what the CGIs do.
- workflow -> gateway: already ssh.
- gateway -> world: already its job.

Natural split order when the need arrives: the gateway first (egress
isolation at the firewall only fully means something on a distinct
machine), the workflow second (engine and store restart/upgrade without
touching monitoring). The LMDB store follows the engine wherever it goes.
Runbooks never change.

## Steady-state cost

writes = (color transitions + events)/s x 1 LMDB txn. stachg rate on a
large site is orders of magnitude below status rate; the board's hot path
is untouched; reads are mmap. Memory is the mapped file, managed by the OS.
If a deployment's trigger rate is in doubt, measure it (count stachg
messages/minute on the real instance) before tuning anything.

## Phasing

- P0: parser (braceparse dependency), instance store, MATCH sources color
  (with FOR) and event (with DEDUP), RUN/WAIT/GATE/TIMEOUT/RETRY with
  ON_FAIL/ON_TIMEOUT routing, the global concurrency cap and circuit
  breaker, at-least-once replay, board reconcile on start, progress
  column, and a `--list` CLI (dumping instances and their step/timer
  state) so P0 is not operated blind while the listing CGI waits in P1.
  FOR is P0 because a remediation engine without an action threshold is
  dangerous; event is P0 because it is what makes the engine a workflow
  engine rather than a remediation hook, at marginal cost; storm control
  is P0 because mass failure is the engine's worst - and defining - day.
- P1: cron triggers, TARGETS allowlists, per-runbook concurrency
  overrides, instance history retention and a listing CGI.
- Explicit non-P0: cross-host runbooks, parallel steps, script-to-engine
  callbacks richer than exit codes.

## Open questions

- WAIT predicate grammar: color comparisons only, or the full analysis.cfg
  expression family? Start color-only; widening later is additive.
- GATE semantics - MUST be settled before P0, not during. An ack means "I
  know", not "I approve"; overloading it makes approval indistinguishable
  from acknowledgment in the audit trail, and two runbooks active on the
  same (host,test) share one ack. Candidate resolutions: accept the
  ambiguity and document it; or gate on an ack whose message carries a
  runbook-addressed token; or publish per-instance gate columns and ack
  those. Needs a look at what ack metadata the board actually exposes.
- Whether the progress column is per-host singular (workflow) or per-runbook
  (workflow.<name>) - decide when the listing CGI is designed, they trade
  page noise against drill-down.
- Event predicate grammar (type= plus free k/v matching?) - decide against
  real usermsg payloads once a first commanded runbook exists.
