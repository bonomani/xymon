"""Offline tests for /series (rrdtool), /graphs (CGI proxy) and Basic auth.

The rrdtool/HTTP/crypt seams are injected, so this runs without a live backend.

    python test_series_graphs_auth.py
"""
from __future__ import annotations

import base64
import sys

from fastapi.testclient import TestClient

import app as app_mod
import xymon

BASE = "/xymon/api/v1"


def main() -> int:
    ok = True

    # --- /series : mocked rrdtool xport ---------------------------------
    xymon.rrd_xport = lambda args: (                # type: ignore
        '{"meta":{"start":1700000000,"step":300},'
        '"data":[[96.0],[97.5],[null]]}')
    s = xymon.series("web1", "disk", "pct_used")
    print(f"series points: {[(p['t'][-9:], p['v']) for p in s['points']]}")
    ok &= s["labels"] == {"entity": "web1", "test": "disk", "metric": "pct_used"}
    ok &= s["metric"] == "pct_used" and len(s["points"]) == 3
    ok &= s["points"][0]["v"] == 96.0 and s["points"][2]["v"] is None

    # --- /graphs : mocked CGI fetch -------------------------------------
    xymon.fetch_graph = lambda url: (b"\x89PNG-bytes", "image/png")  # type: ignore
    client = TestClient(app_mod.build_app(require_auth=False))
    r = client.get(BASE + "/graphs", params={"entity": "web1", "test": "disk"})
    print(f"GET /graphs -> {r.status_code} {r.headers.get('content-type')} "
          f"{len(r.content)}B")
    ok &= r.status_code == 200 and r.headers["content-type"] == "image/png"
    ok &= r.content == b"\x89PNG-bytes"

    rs = client.get(BASE + "/series", params={"entity": "web1", "test": "disk",
                                              "metric": "pct_used"})
    ok &= rs.status_code == 200 and len(rs.json()["series"][0]["points"]) == 3

    # --- Basic auth ------------------------------------------------------
    xymon.verify_basic = lambda u, p: (u, p) == ("admin", "secret")  # type: ignore
    auth_app = TestClient(app_mod.build_app(require_auth=True))
    xymon.xymondboard = lambda: "db01|conn|green|1700000000"  # type: ignore

    r = auth_app.get(BASE + "/states")
    print(f"GET /states no creds  -> {r.status_code} (expect 401, "
          f"{r.headers.get('www-authenticate')!r})")
    ok &= r.status_code == 401 and "Basic" in r.headers.get("www-authenticate", "")
    ok &= r.json().get("error") == "unauthorized"

    tok = base64.b64encode(b"admin:secret").decode()
    r = auth_app.get(BASE + "/states", headers={"Authorization": f"Basic {tok}"})
    print(f"GET /states good creds -> {r.status_code} (expect 200)")
    ok &= r.status_code == 200

    bad = base64.b64encode(b"admin:wrong").decode()
    r = auth_app.get(BASE + "/states", headers={"Authorization": f"Basic {bad}"})
    ok &= r.status_code == 401

    print("\n" + ("✅ PASS" if ok else "❌ FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
