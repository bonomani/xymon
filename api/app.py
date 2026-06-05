"""Spec-conformant mock server for the Xymon REST API.

Loads the authoritative contract (``docs/api/openapi.yaml``), auto-registers a
route for every operation, and answers with a conformant example. The served
``/openapi.json`` is the authored contract verbatim, so consumers (the RAG,
n8n, dashboards) can develop against the real shapes before any Xymon backend
exists. Later, real handlers replace the mock ones path by path -- the contract
and every consumer stay unchanged.

    uvicorn app:app --reload          # then open /docs
"""
from __future__ import annotations

from pathlib import Path

import yaml
from fastapi import FastAPI
from starlette.responses import JSONResponse, Response

import xymon
from example import success_example

_HTTP_METHODS = {"get", "post", "put", "patch", "delete"}
SPEC_PATH = Path(__file__).resolve().parent.parent / "docs" / "api" / "openapi.yaml"


def load_spec() -> dict:
    return yaml.safe_load(SPEC_PATH.read_text())


def make_handler(status: int, body):
    async def handler(request):                     # mock: ignore inputs
        if body is None or status == 204:
            return Response(status_code=status)
        return JSONResponse(body, status_code=status)
    return handler


# Real read endpoints backed by a live Xymon server. Everything else stays a
# conformant mock until its backend lands.
async def _states(request):
    q = request.query_params
    return JSONResponse({"items": xymon.states(
        q.get("entity"), q.get("test"), q.get("verdict"))})


async def _alarms(request):
    return JSONResponse({"items": xymon.alarms()})


async def _entities(request):
    return JSONResponse({"items": xymon.entities()})


async def _health(request):
    try:
        xymon.xymondboard()
        alive = True
    except Exception:                               # noqa: BLE001
        alive = False
    return JSONResponse({"alive": alive})


def _upstream(exc: Exception) -> JSONResponse:
    return JSONResponse({"error": "upstream", "detail": str(exc)}, status_code=502)


async def _series(request):
    q = request.query_params
    try:
        s = xymon.series(q.get("entity"), q.get("test"), q.get("metric"),
                         q.get("from", "-24h"), q.get("to", "now"))
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return JSONResponse({"series": [s]})


async def _graphs(request):
    q = request.query_params
    try:
        data, ctype = xymon.graph(q.get("entity"), q.get("test"),
                                  q.get("from", "-24h"), q.get("to", "now"),
                                  q.get("format", "png"))
    except Exception as exc:                        # noqa: BLE001
        return _upstream(exc)
    return Response(content=data, media_type=ctype)


REAL_HANDLERS = {
    ("get", "/states"): _states,
    ("get", "/alarms"): _alarms,
    ("get", "/entities"): _entities,
    ("get", "/health"): _health,
    ("get", "/series"): _series,
    ("get", "/graphs"): _graphs,
}


def build_app(spec: dict | None = None, require_auth: bool | None = None) -> FastAPI:
    spec = spec or load_spec()
    base = (spec.get("servers") or [{}])[0].get("url", "").rstrip("/")
    if require_auth is None:
        require_auth = bool(xymon.PASSWD_FILE)
    app = FastAPI(title=spec["info"]["title"],
                  version=spec["info"]["version"],
                  description="MOCK server -- conformant example responses.")

    if require_auth:
        @app.middleware("http")
        async def _basic_auth(request, call_next):
            if request.url.path.startswith(base):
                creds = xymon.parse_basic(request.headers.get("authorization"))
                if not creds or not xymon.verify_basic(*creds):
                    return JSONResponse(
                        {"error": "unauthorized", "detail": "Basic auth required."},
                        status_code=401,
                        headers={"WWW-Authenticate": 'Basic realm="xymon"'})
            return await call_next(request)

    for path, item in spec.get("paths", {}).items():
        for method, op in item.items():
            if method not in _HTTP_METHODS:
                continue
            real = REAL_HANDLERS.get((method, path))
            if real is not None:
                handler = real
            else:
                status, body = success_example(op, spec)
                handler = make_handler(status, body)
            app.add_route(base + path, handler, methods=[method.upper()])

    # Serve the authored contract verbatim as the OpenAPI document.
    app.openapi = lambda: spec                      # type: ignore[assignment]
    return app


app = build_app()
