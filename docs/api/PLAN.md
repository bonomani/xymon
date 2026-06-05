# Xymon REST API — Plan

Single plan for the API subproject (`docs/api/` spec + `api/` server). Done
items are deleted; refused items keep a one-line reason. `openapi.yaml` is the
authority; `00-DESIGN.md` / `01-MODEL.md` / `STRUCTURE.md` explain the why.

## Done

- Spec-first contract: OpenAPI 3.0.3, 21 paths / 41 ops / 22 schemas, validated.
- Entity reshaped: `composition` (measured|derived) is the one structural axis;
  role/platform/collection are open labels; aggregation is a layer-computed
  `derivation` (Xymon has no native cross-host combo). Model prose realigned.
- Conformant **mock server** (`api/app.py`): loads the contract, auto-registers
  every op, serves the authored OpenAPI. `test_conformance.py`: 41/41.
- **Real read backend** (`api/xymon.py`), minimal parsing:
  - `/health /states /alarms /entities` ← `xymondboard` structured fields.
  - `/series` ← `rrdtool xport --json`; `/graphs` ← `showgraph` CGI proxy.
  - `reduce_worst()` helper for derived rollups.
- **Optional HTTP Basic auth** reusing Xymon's web htpasswd (`XYMON_API_PASSWD`).

## Next

1. **Wire derived entities** — `/entities` with `composition=derived` should
   report a computed verdict: evaluate `derivation = {selector, reduce}` over
   member states via `reduce_worst` (then `best`, `quorum>=N`). Expose the same
   rollup on `/states?rollup=entity,test` (the classic column colour). Acyclic.
2. **Writes (observed plane)** — map onto the 1984 protocol:
   - `POST /actions {type: ack|disable|enable}` → Xymon `ack`/`disable`/`enable`.
   - `POST /states` (ingest `readings[]`) → `combo`/`status` messages.
   - Return the spec's declared codes (201/202); enforce auth on writes.
3. **Richer reads** — surface `item` + `metrics{}` on `/states` for the few
   test types that warrant it (start with `disk`), keeping colour→verdict at the
   item level; per-metric semantic verdicts stay data (no rule re-evaluation).

## Hardening

- Auth: support apr1/bcrypt htpasswd (add `passlib`); bind localhost + document
  reverse-proxy/TLS; enforce on writes even when reads are open.
- `xymondboard`/rrd/CGI: configurable timeout/retries; graceful per-host failure
  (skip + log) instead of aborting; RRD path/DS resolution for item-keyed files.
- Conformance: add `schemathesis` (property-based) alongside the example check.

## Later / deferred (promote on demand)

- CRUD on the Defined plane (`/tests /rules /suppressions /graph-defs /views`)
  — writes Xymon config (hosts.cfg, analysis/alerts); heavy, deferred.
- Explicit `Relation{from,to,type}` graph for multi-hop / root-cause.
- Streaming board/alarm changes (SSE/websocket) — poll for now.
- `owner` (WHO) coverage on entities/tests — confirm it is populated.

## Consumers

- The RAG (`feat/xymon-rag`) already consumes `/states` via its `api` source;
  richer `/series` ingestion lands once item/metric reads above are done.
