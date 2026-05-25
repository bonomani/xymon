Xymon REST / OpenAPI interface — design (spec-first draft)
==========================================================

Status: DESIGN ONLY. This branch defines the contract (docs/api/openapi.yaml)
and the decisions behind it. No implementation is committed yet; the spec is
deliberately implementation-agnostic so we can choose CGI-in-C vs a decoupled
gateway later without changing the contract.

Branch base: `main`.


1. Why this is mostly a presentation layer
-------------------------------------------
xymond already exposes a complete, structured query + command protocol over its
wire protocol. The REST API is a translation/presentation layer over it, not new
monitoring logic. Existing precedent: `web/appfeed.c` already serves an XML feed
built from `xymondboard`.

Wire verbs we map:

  | Wire verb          | Direction | REST mapping                              |
  |--------------------|-----------|-------------------------------------------|
  | `ping`             | read      | `GET /ping`                               |
  | `xymondboard`      | read      | `GET /board`                              |
  | `xymondlog`        | read      | `GET /hosts/{host}/tests/{test}`          |
  | `hostinfo`         | read      | `GET /hosts/{host}`                        |
  | `ghostlist`        | read      | `GET /ghosts`                             |
  | `config`           | read      | `GET /config/{file}`                      |
  | `status`           | write     | `POST /status`                            |
  | `data`             | write     | `POST /data`                              |
  | `disable`/`enable` | write     | `POST /hosts/{host}/tests/{test}:disable` |
  | `ack`              | write     | `POST /hosts/{host}/tests/{test}/acks`    |
  | `drop`/`rename`    | admin     | `POST /hosts/{host}:drop` / `:rename`     |

The status-item resource model is `host` -> `test` (Xymon's "hostname.testname"
column). A board entry is one (host, test) cell.


2. Resource / field model
--------------------------
A board/status entry mirrors the `xymondboard`/`xymondlog` fields (the protocol
already names them): `hostname`, `testname`, `color`, `flags`, `lastchange`,
`logtime`, `validtime`, `acktime`, `disabletime`, `sender`, `cookie`, `line1`
(first line of the message), `ackmsg`, `dismsg`, `msg` (full status text),
`client`, `hostinfo`. The JSON schema (BoardEntry / StatusDetail in the spec)
maps these directly, with epoch-seconds rendered as RFC 3339 timestamps and
`color` constrained to the Xymon set (green/yellow/red/blue/clear/purple).


3. Cross-cutting decisions
--------------------------
- **Versioning**: base path `/xymon/api/v1`. Breaking changes -> `/v2`.
- **Content type**: `application/json` for bodies; errors as
  `application/problem+json` (RFC 7807).
- **Auth** (security schemes in the spec; deployment chooses which to enable):
  - `bearerAuth`: an API token (recommended for automation).
  - `basicAuth`: reuse the existing web user db (htpasswd via useradm.cgi).
  - mTLS at the transport layer is orthogonal and recommended between the API
    process and xymond: the API becomes the only thing speaking the wire
    protocol, and can do so over the native-TLS `xymons://` channel.
- **Pagination/filtering**: `GET /board` accepts `host`, `test`, `color`,
  `page`, `tag` filters (passed through to `xymondboard`'s filter syntax) and
  `fields` to project columns; `limit`/`cursor` cap large result sets.
- **Idempotency**: `POST /status` is an upsert of a (host,test) cell; safe to
  retry. Disable/enable/ack are state transitions.
- **Errors**: 400 invalid params, 401 unauthenticated, 403 unauthorized,
  404 unknown host/test, 409 conflict (e.g. drop of active host), 502 if xymond
  is unreachable, 504 on wire timeout.


4. Open questions (to settle before implementation)
----------------------------------------------------
- Authorization granularity: per-token host/test scoping?
- Write-path safety: should `POST /status` require the submitting identity to
  match the host (anti-spoofing), or trust the API's own auth?
- Streaming/long-poll for board changes (SSE/websocket) vs poll-only for v1.
- `config`/`download` expose server files — restrict to an allow-list.
- Character encoding: appfeed.c emits ISO-8859-1; the API standardizes on UTF-8
  (transcode at the boundary).


5. Implementation options (deferred)
------------------------------------
- **JSON CGI in the C tree** (like appfeed.c): fits the project build, web
  server, and existing web auth; the hand-written spec must stay in sync.
- **Decoupled gateway** (e.g. Go or Python+FastAPI): can auto-generate the
  spec, fast to build, talks to xymond (optionally over native TLS); adds a
  non-C toolchain and its own build/CI.

The contract in openapi.yaml is the source of truth either way.
