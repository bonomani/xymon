# Xymon REST API — mock server

A **spec-conformant mock** of the Xymon REST API. It loads the authoritative
contract (`../docs/api/openapi.yaml`), auto-registers every operation, and
answers with a conformant example — the author's declared `example` when
present, else a value synthesised from the response schema.

It exists so consumers (the RAG pipeline, n8n, dashboards) can develop against
the **real shapes** before any Xymon backend exists. Later, real handlers
replace the mock ones **path by path**; the contract and every consumer stay
unchanged.

## Run

```bash
pip install -r requirements.txt
uvicorn app:app --reload          # Swagger UI at /docs, schema at /openapi.json
# e.g. GET /xymon/api/v1/states  |  /alarms  |  /entities  |  /health
```

The served `/openapi.json` **is** `docs/api/openapi.yaml` verbatim.

## Conformance

```bash
python test_conformance.py
```

For every operation it calls the mock and validates the response against the
schema the contract declares (via `jsonschema`, `$ref`s resolved against the
spec), plus a couple of semantic spot-checks. Current: **41/41 operations
conformant**.

## Files

| File | Role |
|------|------|
| `app.py` | FastAPI app; loads the spec, auto-registers routes, serves the authored OpenAPI. |
| `example.py` | Conformant example generator (author example → else synthesised from schema). |
| `test_conformance.py` | Validates every response against its declared schema. |

## Real vs mock

Read endpoints are backed by a live Xymon server (`xymon.py`), with **minimal
parsing** (see `docs/api/` and the RAG `rag/PLAN.md`); the rest stay conformant
mocks until their backend lands.

| Endpoint | Status | Source |
|----------|--------|--------|
| `GET /health` | **real** | `xymondboard` reachability |
| `GET /states` | **real** | `xymondboard` structured fields, colour→status (`item`/`metrics` deferred) |
| `GET /alarms` | **real** | non-ok states |
| `GET /entities` | **real** | distinct hosts (`composition=measured`, `role` label) |
| `GET /series` | mock | next: `rrdtool xport` |
| `GET /graphs` | mock | next: proxy Xymon's `showgraph` CGI |
| derived entities | helper ready (`reduce_worst`) | API computes `derivation.reduce` over members — the on-demand rollup, no native Xymon combo |
| writes / CRUD (`/actions`, `POST /states`, `/tests` …) | mock | deferred |

Point the real reads at a server with `XYMON_BIN` / `XYMON_SERVER`.
