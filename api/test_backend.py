"""Test the real read backend mapping (xymondboard -> API schemas), offline.

A synthetic board is injected; we check the colour->status mapping, the alarms
filter, distinct entities, derived worst-of, and that the live read endpoints
return that data through the app.

    python test_backend.py
"""
from __future__ import annotations

import sys

from fastapi.testclient import TestClient

import app as app_mod
import xymon

_BOARD = "\n".join([
    "db01|disk|red|1700000000",
    "db01|conn|green|1700000000",
    "web01|http|yellow|1700000100",
    "web01|cpu|green|1700000100",
])


def main() -> int:
    xymon.xymondboard = lambda: _BOARD              # type: ignore
    ok = True

    states = xymon.states()
    by = {(s["entity"], s["test"]): s["verdict"] for s in states}
    print(f"states: {len(states)}  verdicts={by}")
    ok &= by[("db01", "disk")] == "critical"        # red -> critical
    ok &= by[("db01", "conn")] == "ok"              # green -> ok
    ok &= by[("web01", "http")] == "warning"        # yellow -> warning
    ok &= all("time" in s for s in states)          # epoch -> RFC 3339

    al = xymon.alarms()
    print(f"alarms: {[(a['entity'], a['test'], a['severity']) for a in al]}")
    ok &= len(al) == 2 and all(a["status"] == "firing" for a in al)  # 2 greens excluded

    ents = xymon.entities()
    print(f"entities: {[e['id'] for e in ents]} comp={ents[0]['composition']}")
    ok &= sorted(e["id"] for e in ents) == ["db01", "web01"]
    ok &= all(e["composition"] == "measured" for e in ents)

    worst = xymon.reduce_worst(states)              # db01 disk is critical
    print(f"reduce_worst(all) = {worst}")
    ok &= worst == "critical"

    # through the app
    c = TestClient(app_mod.build_app())
    base = "/xymon/api/v1"
    r = c.get(base + "/states", params={"entity": "db01"})
    ok &= r.status_code == 200 and len(r.json()["items"]) == 2
    h = c.get(base + "/health").json()
    print(f"GET /states?entity=db01 -> {len(r.json()['items'])} rows; /health={h}")
    ok &= h["alive"] is True

    print("\n" + ("✅ PASS" if ok else "❌ FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
