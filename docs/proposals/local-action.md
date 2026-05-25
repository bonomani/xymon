# Proposal: host-local corrective action for the local-analysis client

Status: **Draft / idea** — design notes only, no implementation yet.

## Summary

Let the **local-analysis client** optionally run a guarded, allowlisted
**corrective action** on the host when one of its locally-computed tests
changes state — turning Xymon from "detect + alert" into optional
"detect + alert + (self-)act", with the decision and the action both staying
on the monitored host.

This is strictly opt-in and layered on top of the existing client; the default
collector and the server-side analysis path are unchanged.

## Motivation / use cases

The local-analysis client (`--local`) already evaluates the rules on the host
and produces the green/yellow/red verdict locally. That makes the host the
natural place to *also* react, with no round-trip to the server:

- **Fast, autonomous response** — restart a wedged service the moment the local
  `procs` test goes red, without waiting for a server poll + alert + human +
  remote action.
- **Scale** — fleets where routing every remediation through the server (or a
  central automation tool) is a bottleneck.
- **Weak / intermittent links** — edge or field hosts that must self-heal even
  when the link to the server is down.
- **Local-only data** — hosts where the raw signal (process lists, file
  contents) should not leave the box; the action is decided and taken locally.

## Background: where this fits

Two orthogonal client axes:

| Axis | Choices | When decided |
|------|---------|--------------|
| Analysis location | server (default) / **on-host (`--local`)** | build (needs PCRE) + runtime flag |
| Collection-config source | local file / server-distributed (`client-local.cfg`) | runtime |

Corrective action belongs to the **on-host analysis** path: the verdict already
exists locally, so a "when test X goes red, run action Y" hook is a small,
coherent addition there. It does **not** apply to the dumb collector (which has
no local verdict).

## Security analysis (the important part)

A common objection is "a monitor that runs commands is a big new attack
surface." On closer look the trigger primitive is **the same one Xymon already
ships**: an `alerts.cfg` recipient can be a script, i.e. *monitoring state →
code execution* already exists.

For the **host-local** case the trigger surface is arguably **smaller** than
server-side scripted alerting:

- A server-side alert script is triggered by status messages **received over the
  network**, and the Xymon wire protocol is largely unauthenticated — so a
  forged status can trigger it remotely.
- A host-local action is triggered by a verdict the host **computed from its own
  local data** — an external attacker cannot inject a fake "disk red" to that
  actuator without already being on the host.

So the real differences are **not** attack surface; they are:

1. **Closed-loop autonomy** — no human in the loop, so a *bug* (wrong threshold)
   auto-amplifies. This is an operational/correctness risk, not a security one.
2. **Privilege & destructiveness** — remediation tends to mutate state, often as
   root, vs. read-only notifications. (A property of the action script, not of
   "alert vs act".)
3. **Fan-out** — one actuator per host means a bad rule executes everywhere.

These are manageable with controls (below), and are the same controls one should
already put on any privileged alert script.

## Design sketch

### Trigger
Hook into the local-analysis result: after the on-host evaluation produces a
status, if an action rule matches the (column, color, duration) it queues the
action. Reuse the existing `clientlaunch`/`xymonlaunch` run loop rather than add
a new daemon.

### Config: `client-action.cfg` (local, or distributed like `client-local.cfg`)
```
# column  color     after   action
disk      red       10m     run:/opt/xymon/actions/clean-tmp.sh
procs     red       0       run:restart-service %SVCNAME%
cpu       red       30m     notify-only        # explicit no-op / staging
```

### Guards (all on by default)
- **Allowlist** — actions must reference entries in an admin-owned allowlist
  directory; no arbitrary inline shell.
- **Least privilege** — actions run as a dedicated, non-root user unless a
  specific allowlist entry is marked privileged.
- **Cooldown / rate-limit** — per-rule minimum interval and a max-actions-per-
  window cap; never loop.
- **Dry-run mode** — global and per-rule; logs "would run X" without executing.
- **Sustained-state requirement** — only fire after the condition has held for
  `after` (e.g. 10m), not on a single flap.
- **Audit log** — every decision (fired / suppressed / dry-run) recorded with
  context, and reported back to the server as a status column (e.g. `action`).
- **Destructive-class gate** — actions tagged destructive require an explicit
  ack/enable, and are off by default.

### Reporting
The client reports what it did via a normal status message (new `action`
column), so the server/UI still has full visibility — autonomy without
invisibility.

## Non-goals

- Not a general orchestration/automation engine (that's Ansible/Salt/Rundeck);
  this is narrow, host-local, single-host self-healing.
- Not for the default collector (no local verdict there).
- No remote/cross-host action; a host only acts on itself.

## Open questions

- Bind to the existing analysis structures in `xymond_client`-shared code, or a
  thin post-processing pass over the local result?
- Config distribution: reuse the `client-local.cfg` server-push mechanism for
  `client-action.cfg`, or keep actions strictly local-only for safety?
- Interaction with `disable`/maintenance windows and acks (suppress actions when
  a test is disabled/acked).
- Packaging: expose as part of a `--local`-capable build only.
