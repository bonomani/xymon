Xymon REST / OpenAPI interface — design
=======================================

Status: DESIGN ONLY. No implementation yet. Branch base: `main`.

This file holds the API conventions and decisions. The three docs split as:
- **`01-MODEL.md`** — the domain model (Host→Test→State→Alarm→Action; the law;
  State as a label-set). *Read this first.*
- **`openapi.yaml`** — the authoritative contract (OpenAPI 3.0.3, validated).
- **`STRUCTURE.md`** — the visual endpoint map.


1. Shape: two planes
--------------------
The API is the model's two planes, each a uniform set of resources:

- **Defined** (config; full CRUD): `/entities` `/tests` `/rules` `/suppressions`
  `/graph-defs` `/views` — `GET`/`POST` on the collection, `GET`/`PUT`/`DELETE`
  on the item. (`/entities` = monitored subjects of any `kind` — host/net/
  service/link/app; `/views` = the curated page tree, presentation only.)
- **Observed** (runtime; read-only + the two real writes): `/states` `/alarms`
  `/actions` `/series` `/graphs` — `GET` to read/query; `POST /states` ingests
  readings; `POST /actions` issues operator commands (ack/disable/enable);
  `/series` and `/graphs` are a value's history (data) and its rendered RRD
  image. Plus `GET /health`.

Every config resource has the identical shape; differences live in the record
schema, not the API structure.


2. Conventions (kept simple)
----------------------------
- OpenAPI **3.0.3** (widest tooling; `nullable` valid); validated with
  openapi-spec-validator.
- Base path `/xymon/api/v1`; breaking changes → `/v2`.
- `application/json`; UTF-8 at the boundary; epoch → RFC 3339.
- **One** auth scheme: HTTP Basic, reusing the existing Xymon web user db.
- **One** error shape: `{error, detail}`; each operation enumerates its real
  status codes (400/401/403/404/409/502).
- **Query by dimension** on `/states`: every label is a filter (`entity`, `test`,
  `metric`, `verdict`, free dims via `selector`), with `rollup` for group-by
  aggregates (the classic "column color"), `fields` for projection, `limit`.
- **Ingest is batch-shaped** (`POST /states` with `readings[]`) — the `combo`
  path; readings decompose into atomic States.
- **No bespoke verbs.** ack/disable/enable are `POST /actions {type}`; an
  operator action may create a Suppression; "enable" = delete that suppression.


3. Decisions taken up front (no open questions block it)
--------------------------------------------------------
- **Authorization**: API-level — an authenticated caller may read and write.
  Per-token/per-entity scoping (ties to `owner`/WHO) is a later refinement.
- **Write anti-spoofing**: v1 trusts API auth for ingest; tightening to
  "sender identity must match entity" is a later option (mTLS makes it natural).
- **`config` / file exposure**: not in v1; if added, a server-side allow-list.


4. Deferred (promote on demand)
-------------------------------
- Explicit `Relation{from,to,type}` edges — today relations are labels +
  selectors (member-of→combo, depends-on→suppression, group→view); promote to a
  relation graph only for multi-hop / root-cause.
- Streaming board/alarm changes (SSE/websocket) — poll for now.
- `owner` (WHO) coverage on entities/tests — confirm it's populated.

The contract in `openapi.yaml` is the source of truth; this file and the model
explain the *why*.
