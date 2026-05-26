# PLAN

## CI — profil de dépendances macOS dédié (`macos_default`)

Fait : macOS ne réutilise plus le profil `linux_default`. Nouveau profil
`macos_default` (deps-base.yaml + deps-overlays.yaml) mappé dans
deps-targets.yaml. Il **n'inclut plus `TIRPC`** (pas de port `libtirpc` dans
MacPorts ; RPC/XDR fournis par le SDK macOS).

Contexte : la boucle d'install (`ci/deps/lib/install-common.sh`) est fail-fast.
`TIRPC→port:[libtirpc]` échouait et arrêtait l'install avant `pcre2`, faisant
échouer `configure` (PCRE requis) sur les lanes macOS **server** et
**localclient** ; seul **client** (CLIENTONLY, sans PCRE) passait.

Reste à vérifier (au prochain run macOS server) :
- le build serveur macOS compile sans paquet RPC/XDR (XDR attendu depuis
  `/usr/include/rpc` du SDK). Si non : trouver l'équivalent macOS plutôt que de
  réintroduire `libtirpc`.


## Multi-server ack/notes propagation — STUDY (branch `fix/multiserver-ack-sync`)

Study only; **no code yet**. Goal: decide whether/how to make operator state
(acknowledgements, notes) consistent across a multi-server Xymon deployment.
All findings below are from reading the tree on `cmake/bootstrap`.

### Problem
With `XYMSERVERS="srvA srvB"` a client feeds several Xymon servers. Monitoring
**data** replicates to all of them, but **operator actions don't**:
- An `ack` reaches only **one** server. If both servers run `xymond_alert`,
  acking on srvA does not silence srvB → continued paging.
- Even where only one server alerts, the other's web UI shows the alert as
  still un-acked (cosmetic, but confusing).
- `notes` (host notes) behave the same — they land on one server only.

### Current behavior (grounded)
1. **Client routing — `sendtomany()`** (`lib/sendmsg.c:619-720`). Only consulted
   when `XYMSRV=0.0.0.0` (else the single `XYMSRV` is used, `sendmsg.c:638,666,855`).
   The list is split by command:
   - **Broadcast to ALL** for commands in `multircptcmds[]` (`sendmsg.c:49`):
     `status, combo, extcombo, meta, data, notify, enable, disable, drop,
     rename, client`.
   - **Failover (first server that answers, then stop)** for everything else —
     including **`ack`** and **`notes`** and all query/response commands.
   Rationale: a report is fire-and-forget (can fan out); a response-bearing
   command can only consume one reply. So ack/notes hit exactly one server.
2. **`ack` on the server** — `handle_ack()` (`xymond/xymond.c:2212-2233`):
   updates in-memory ack state and posts `@@ack` to the **page** channel
   (`:2231`). The command is keyed by a **per-server cookie** number (`:2224`);
   the cookie is meaningless on a peer.
3. **`ackinfo`** — `handle_ackinfo()` (`xymond/xymond.c:2237+`): richer ack,
   keyed by **host/test + level + ackedby** (attached to the status log), not a
   bare cookie → inherently more portable across servers.
4. **`notes`** — dedicated **notes** channel (`C_NOTES`, `xymond.c:226`); the
   command is **host-keyed** (`xymond.c:3793`). `handle_notes()` (`:2019`) is
   currently almost a stub. Host-keyed + own channel → easiest to replicate.
5. **`xymond_alert`** reads `@@ack` from the **page** channel
   (`xymond/xymond_alert.c:754`) to suppress paging — purely **intra-server**.
6. **`xymond_distribute`** (the only built-in peer forwarder,
   `xymond/xymond_distribute.c`): reads the **enadis** channel
   (`tasks.cfg.DIST [distribute]`), and re-issues to peers only
   `@@drophost/@@droptest/@@renamehost/@@renametest/@@enadis`
   → `drop/rename/enable/disable` (`:112-150`, `sendmessage(..., peers[i])`
   `:149`). It has **no ack/notes handler**, and the shipped config warns it has
   **no loop detection** and is meant **master→slave** (one-directional).

### Root causes (why ack/notes don't propagate)
- **RC1 — client routing**: ack/notes use failover, not broadcast (by design).
- **RC2 — channel mismatch**: acks live on the **page** channel; notes on the
  **notes** channel; `xymond_distribute` listens on **enadis** → it never even
  sees them.
- **RC3 — cookie keying**: plain `ack` is keyed by a per-server cookie; it
  cannot be replayed verbatim on a peer. (`ackinfo`/`notes` are host/test-keyed,
  so this only blocks the plain `ack` path.)
- **RC4 — one-directional, no loop guard**: `xymond_distribute` assumes a single
  forwarding direction; bidirectional sync would echo forever.

### Design options
**Option A — Topology only (no code).** Active alerting + silent mirror: one
server runs `xymond_alert` (alerts), the other is a display mirror (no alert
task). All clients/web use `XYMSERVERS="alerter mirror"` (alerter first) so
status broadcasts to both while ack/notes failover to the alerter. Zero code,
zero risk. Limits: mirror's UI shows un-acked; failover is manual; not two
equal servers.

**Option B — One-directional forward (primary→standby).** Make
`xymond_distribute` forward ack/notes (and probably `ackinfo`) to peers.
Components:
  - B1. A **host/test-keyed ack path** in xymond so a peer can apply an ack
    without the originating server's cookie (extend `handle_ack`/the `ack`
    parser, or forward as `ackinfo`, which is already host/test/level-keyed —
    likely the cleaner vehicle).
  - B2. `xymond_distribute` reads the **page** (and **notes**) channel(s) — a
    second instance, or multi-channel support — with new `@@ack`/`@@ackinfo`/
    `@@notes` handlers that re-emit a host/test-keyed command to peers.
  - B3. Run distribute **only on the primary** (no loop, matches current model).
  Result: faithful warm standby; **not** two equal alerting servers. Moderate,
  self-contained, in the spirit of the existing module.

**Option C — Bidirectional sync (two equal servers).** Everything in B plus
loop prevention: tag forwarded operator-state with an **origin id** (or a
seen-set) so a peer doesn't echo it back, and de-dupe so both servers don't
double-page. Touches the channel/message envelope. Highest scope/risk; against
Xymon's one-directional grain. Closest to true HA.

### Cross-cutting concerns to study
- **`ackinfo` vs plain `ack`**: replicating `ackinfo` (host/test/level-keyed)
  likely sidesteps RC3 entirely — confirm the web/CLI ack path also emits
  `ackinfo`, and whether suppressing paging keys off `ack` or `ackinfo`.
- **Idempotency / double-apply**: `disable` already both broadcasts (in
  `multircptcmds`) *and* can be forwarded by distribute — confirm applying it
  twice is harmless, and that ack/notes forwarding is likewise idempotent.
- **Authorization on the receiving peer**: a forwarded ack/notes is an inbound
  command subject to the peer's sender access control. On `cmake/bootstrap`
  that's `--maint-senders`/`--admin-senders`; on `feat/ipv6-tls` it's the
  unified `--acl` (the peer must grant the forwarding server the right
  capability/transport). Cross-reference when the branches eventually meet.
- **Multi-channel reading**: confirm whether `xymond_channel`/`xymond_distribute`
  can subscribe to >1 channel or whether multiple worker instances are needed.
- **`notes` is nearly a stub** (`handle_notes`); check what actually persists
  and whether replication is even meaningful for it before investing.

### Open questions (resolve before any code)
1. Target topology: warm standby (Option B) vs two equal servers (Option C)?
2. Forward via `ackinfo` (host/test-keyed, no new parser) or add a host-keyed
   plain-`ack` form?
3. Second distribute instance on the page/notes channels, or extend distribute
   to read multiple channels?
4. For Option C only: origin-tagging vs sender-skip for loop prevention.

### Recommendation (for discussion, not yet chosen)
- If warm standby is acceptable: **Option B via `ackinfo`** is the smallest
  sound code change and matches the existing master→slave distribute design.
- **Option A** remains the zero-cost answer if a silent mirror is good enough.
- **Option C** only if two interchangeable alerting servers are a hard
  requirement — treat as a larger, separate effort.

### Verification plan (when code is eventually written)
- Build via the non-interactive path (`build/genconfig.sh` + env-seeded
  `./configure --server`, then `make xymond-build`).
- Extend `tests/ipv6-tls/smoke.sh` style harness: two xymond instances on
  distinct ports; ack on A; assert B reflects the ack (board `ackmsg`/`acktime`
  fields); confirm no forwarding loop (Option C) via log/message counts.
- `git diff --check`; `groff -man -ww -z` for any manpage edits.
