"""Offline test of the Xymon REST API (FastAPI TestClient, mocked board).

    python test_api.py        # prints a report, exits non-zero on failure
"""
from __future__ import annotations

import sys

from fastapi.testclient import TestClient

import xymon_api
import xymon_export

_BOARD = "\n".join([
    "db01|disk|red|1700000000|/var 98% full|Filesystem /var is 98% full",
    "db01|conn|green|1700000000|ok|Connection OK",
    "web01|http|yellow|1700000100|slow|HTTP latency high (2.1s)",
])


def main() -> int:
    # Inject synthetic board + history (no real Xymon server needed).
    xymon_export._xymondboard = lambda c: _BOARD                  # type: ignore
    xymon_export.host_history = (                                  # type: ignore
        lambda c, h: "db01 disk green->red at 02:10" if h == "db01" else None)

    client = TestClient(xymon_api.app)
    ok = True

    r = client.get("/healthz")
    ok &= r.status_code == 200 and r.json()["status"] == "ok"
    print(f"GET /healthz        -> {r.status_code}")

    r = client.get("/hosts")
    print(f"GET /hosts          -> {r.status_code} {r.json()}")
    ok &= r.json() == ["db01", "web01"]

    r = client.get("/status", params={"host": "db01"})
    print(f"GET /status?host=db01 -> {r.status_code} ({len(r.json())} rows)")
    ok &= r.status_code == 200 and len(r.json()) == 2

    r = client.get("/alerts")
    colors = sorted(row["color"] for row in r.json())
    print(f"GET /alerts         -> {r.status_code} colors={colors}")
    ok &= colors == ["red", "yellow"]                # the green conn is excluded

    r = client.get("/history/db01")
    print(f"GET /history/db01   -> {r.status_code}")
    ok &= r.status_code == 200 and "green->red" in r.json()["history"]

    r = client.get("/history/nope")
    print(f"GET /history/nope   -> {r.status_code} (expect 404)")
    ok &= r.status_code == 404

    # OpenAPI schema is generated and exposes the endpoints.
    schema = client.get("/openapi.json").json()
    paths = set(schema.get("paths", {}))
    print(f"openapi paths       -> {sorted(paths)}")
    ok &= {"/hosts", "/status", "/alerts", "/history/{host}"} <= paths

    print("\n" + ("✅ PASS" if ok else "❌ FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
