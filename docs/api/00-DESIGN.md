Xymon REST / OpenAPI interface — design (spec-first draft)
==========================================================

Status: DESIGN ONLY (contract in docs/api/openapi.yaml). No implementation yet.
Branch base: `main`.

Goal: a **simple** REST/JSON interface over xymond — clean paths, one auth
scheme, plain errors — covering the full *common* surface (read status, submit
status, host/test actions). "Simple" is about low friction, not a cut-down
feature set; the heavier or contentious bits are decided with a sensible
default rather than dropped.


1. Why this is mostly a presentation layer
-------------------------------------------
xymond already exposes a structured query + command protocol; the API is a thin
translation over it (precedent: `web/appfeed.c` already serves an XML feed from
`xymondboard`). Verb mapping:

  | Endpoint                                  | Wire verb     |
  |-------------------------------------------|---------------|
  | `GET  /ping`                              | `ping`        |
  | `GET  /board`                             | `xymondboard` |
  | `GET  /hosts/{host}`                      | `hostinfo`    |
  | `GET  /hosts/{host}/tests/{test}`         | `xymondlog`   |
  | `POST /status`                            | `status`      |
  | `POST /hosts/{host}/tests/{test}/disable` | `disable`     |
  | `POST /hosts/{host}/tests/{test}/enable`  | `enable`      |
  | `POST /hosts/{host}/tests/{test}/ack`     | `ack`         |
  | `GET  /ghosts`                            | `ghostlist`   |
  | `GET  /config/{file}`                     | `config`      |

The status-item model is `host` -> `test` (Xymon's "hostname.testname" cell).
Board/status fields mirror the protocol's own names (`hostname`, `testname`,
`color`, `lastchange`, `sender`, `msg`, ...), with epoch times rendered as
RFC 3339 and `color` from the Xymon set.


2. Conventions (the "simple" part)
----------------------------------
- Base path `/xymon/api/v1`; breaking changes -> `/v2`.
- `application/json` bodies; UTF-8 at the boundary (appfeed.c emits 8859-1).
- **One** auth scheme: HTTP basic, reusing the existing Xymon web user db.
- **One** error shape: `{error, detail}` JSON; the HTTP status carries the kind
  (400/401/403/404/409/502/504). No RFC 7807 ceremony.
- Filtering on `GET /board`: `host`, `test`, `color`, `page`, `tag` (passed to
  xymondboard) plus a plain `limit`. No opaque cursors unless data demands it.
- `POST /status` is an idempotent upsert of a (host,test) cell.


3. Decisions made up front (so nothing is left "open")
-------------------------------------------------------
- **Authorization**: API-level. An authenticated caller may read and submit;
  per-host/per-token scoping is a later refinement, not a v1 gate.
- **Write anti-spoofing**: v1 trusts the API's own auth (a caller may submit for
  any host). Tightening to "identity must match host" is a later option.
- **config exposure**: server-side **allow-list** of fetchable files (no
  arbitrary path access).


4. Deferred (add when there's demand)
-------------------------------------
- Streaming board changes (SSE/websocket) — poll for now.
- Destructive admin verbs `drop`/`rename`.
- Cursor pagination, richer host/event/history views.


5. Implementation (deferred; spec is the source of truth)
---------------------------------------------------------
Either a JSON CGI in the C tree (like appfeed.c; fits the existing build and web
auth) or a small decoupled gateway that talks to xymond (optionally over native
TLS). Either way openapi.yaml is authoritative.
