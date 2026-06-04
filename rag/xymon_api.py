"""A small REST API in front of Xymon, documented with OpenAPI/Swagger.

Xymon has no native REST/OpenAPI interface -- only the TCP 1984 protocol, CGIs
and flat files. This FastAPI app exposes the monitoring state as clean JSON so
modern consumers (this RAG pipeline, n8n, dashboards, other LLMs) can read it,
with auto-generated docs at ``/docs`` and a schema at ``/openapi.json``.

Run:
    uvicorn xymon_api:app --reload
Endpoints:
    GET /healthz            liveness
    GET /hosts              distinct host names on the board
    GET /status            full board, optional ?color= and ?host= filters
    GET /alerts            non-green statuses only (red/yellow/purple)
    GET /history/{host}    a host's state-change history
"""
from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

import xymon_export
from config import Config

ALERT_COLORS = {"red", "yellow", "purple"}

app = FastAPI(
    title="Xymon REST API",
    version="0.1.0",
    description="REST/OpenAPI facade over a Xymon (Hobbit) server.",
)


def _cfg() -> Config:
    # Indirection so tests can monkeypatch xymon_export internals.
    return Config()


class StatusRow(BaseModel):
    host: str = Field(examples=["web01"])
    test: str = Field(examples=["http"])
    color: str = Field(examples=["red", "yellow", "green"])
    lastchange: str = Field(default="", description="epoch seconds, as reported")
    msg: str = Field(default="", description="status message text")


class HostHistory(BaseModel):
    host: str
    history: str


@app.get("/healthz", tags=["meta"])
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/hosts", response_model=list[str], tags=["xymon"])
def hosts() -> list[str]:
    """Distinct host names currently on the board."""
    rows = xymon_export.status_rows(_cfg())
    return sorted({r["host"] for r in rows})


@app.get("/status", response_model=list[StatusRow], tags=["xymon"])
def status(
    color: Annotated[str | None, Query(description="filter by colour")] = None,
    host: Annotated[str | None, Query(description="filter by host")] = None,
) -> list[StatusRow]:
    """Full board, optionally filtered by colour and/or host."""
    rows = xymon_export.status_rows(_cfg())
    if color:
        rows = [r for r in rows if r["color"] == color]
    if host:
        rows = [r for r in rows if r["host"] == host]
    return [StatusRow(**r) for r in rows]


@app.get("/alerts", response_model=list[StatusRow], tags=["xymon"])
def alerts() -> list[StatusRow]:
    """Non-green statuses only (red/yellow/purple)."""
    rows = xymon_export.status_rows(_cfg())
    return [StatusRow(**r) for r in rows if r["color"] in ALERT_COLORS]


@app.get("/history/{host}", response_model=HostHistory, tags=["xymon"])
def history(host: str) -> HostHistory:
    """A single host's state-change history."""
    text = xymon_export.host_history(_cfg(), host)
    if text is None:
        raise HTTPException(status_code=404, detail=f"no history for {host!r}")
    return HostHistory(host=host, history=text)
