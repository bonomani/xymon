Xymon REST / OpenAPI interface — design (spec-first draft)
==========================================================

Status: DESIGN ONLY (contract in docs/api/openapi.yaml). No implementation yet.
Branch base: `main`.

Scope for now: **minimal and read-only.** Just enough to get Xymon status out
as JSON. Submission, disable/ack, and streaming are deliberately left out of v1.


1. Why this is easy
-------------------
xymond already has a structured query protocol; the API is a thin presentation
layer over it (precedent: `web/appfeed.c` already serves an XML feed from
`xymondboard`). v1 maps three read verbs:

  | Endpoint                          | Wire verb     |
  |-----------------------------------|---------------|
  | `GET /ping`                       | `ping`        |
  | `GET /board`                      | `xymondboard` |
  | `GET /hosts/{host}/tests/{test}`  | `xymondlog`   |

A board entry is one (host, test) cell. Fields mirror the protocol's own names
(`hostname`, `testname`, `color`, `lastchange`, the message), with epoch times
rendered as RFC 3339 and `color` from the Xymon set.


2. Decisions (kept minimal)
---------------------------
- Base path `/xymon/api/v1`.
- `application/json`; epoch -> RFC 3339; UTF-8 at the boundary.
- Auth: HTTP basic, reusing the existing Xymon web user db (one scheme).
- `GET /board` filters: `host`, `test`, `color` (passed to xymondboard). No
  pagination yet -- add a `limit`/cursor only if result sizes demand it.
- Errors: plain JSON `{error, detail}`, kind carried by the HTTP status.


3. Deferred (revisit when v1 is in use)
---------------------------------------
- Writes: `POST /status`, disable/enable, acknowledge (need an auth/anti-spoof
  decision first).
- Streaming board changes (SSE/websocket).
- `config`/file fetch, ghostlist, richer host views.
- Per-token authorization scoping.


4. Implementation (also deferred)
---------------------------------
Either a JSON CGI in the C tree (like appfeed.c; fits the existing build/web
auth) or a small decoupled gateway that talks to xymond (optionally over native
TLS). The contract in openapi.yaml is the source of truth either way.
