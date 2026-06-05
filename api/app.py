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


def build_app(spec: dict | None = None) -> FastAPI:
    spec = spec or load_spec()
    base = (spec.get("servers") or [{}])[0].get("url", "").rstrip("/")
    app = FastAPI(title=spec["info"]["title"],
                  version=spec["info"]["version"],
                  description="MOCK server -- conformant example responses.")

    for path, item in spec.get("paths", {}).items():
        for method, op in item.items():
            if method not in _HTTP_METHODS:
                continue
            status, body = success_example(op, spec)
            app.add_route(base + path, make_handler(status, body),
                          methods=[method.upper()])

    # Serve the authored contract verbatim as the OpenAPI document.
    app.openapi = lambda: spec                      # type: ignore[assignment]
    return app


app = build_app()
