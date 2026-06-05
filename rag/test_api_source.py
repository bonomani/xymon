"""Test the `api` source: Xymon REST API States -> RAG documents (offline).

Checks the pure mapping and the HTTP path (httpx mocked), so the RAG can consume
the canonical Xymon REST API (feat/openapi) instead of shelling out to xymon.

    python test_api_source.py
"""
from __future__ import annotations

import sys

import httpx

import xymon_export
from config import Config

_STATES = [
    {"id": "web1:disk:/var", "entity": "web1", "test": "disk", "item": "/var",
     "verdict": "critical",
     "metrics": {"pct_used": {"value": 96, "verdict": "critical"},
                 "inodes": {"value": 41, "verdict": "ok"}},
     "time": "2026-06-05T09:00:00Z"},
    {"id": "db01:conn", "entity": "db01", "test": "conn", "verdict": "ok"},
]


def main() -> int:
    ok = True

    docs = xymon_export.states_to_docs(_STATES)
    print(f"states_to_docs: {len(docs)} docs")
    ok &= len(docs) == 2
    d = docs[0]
    ok &= d["meta"] == {"source": "api", "host": "web1", "test": "disk",
                        "color": "critical", "lastchange": "2026-06-05T09:00:00Z"}
    ok &= "CRITICAL" in d["text"] and "pct_used=96 (critical)" in d["text"]
    print(f"  doc0 text: {d['text']!r}")

    # HTTP path with httpx mocked
    def handler(request):
        assert request.url.path.endswith("/states")
        return httpx.Response(200, json={"items": _STATES})

    orig = httpx.Client
    httpx.Client = lambda *a, **k: orig(                      # type: ignore
        transport=httpx.MockTransport(handler), timeout=k.get("timeout"))
    try:
        d2 = xymon_export.api_status_docs(Config())
    finally:
        httpx.Client = orig                                   # type: ignore
    print(f"api_status_docs (mocked API): {len(d2)} docs, source={d2[0]['meta']['source']}")
    ok &= len(d2) == 2 and all(x["meta"]["source"] == "api" for x in d2)

    print("\n" + ("✅ PASS" if ok else "❌ FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
