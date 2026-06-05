"""Real read backend: map a live Xymon server onto the API's schemas.

Minimal parsing by design (see docs/api/ and rag/PLAN.md): the data comes from
``xymondboard``'s *structured* fields (split on ``|``), with colour mapped to
the semantic verdict. No status-message body parsing, no flat files. ``metrics``
and multi-``item`` decomposition are deferred (optional in the schema), and the
numeric history lives in ``/series`` (RRD) -- not wired here.

``xymondboard`` is module-level so tests can substitute a synthetic board.
"""
from __future__ import annotations

import os
import subprocess
from datetime import datetime, timezone

XYMON_BIN = os.environ.get("XYMON_BIN", "xymon")
XYMON_SERVER = os.environ.get("XYMON_SERVER", "127.0.0.1")
BOARD_FIELDS = ["hostname", "testname", "color", "lastchange"]

# Semantic status -- never a colour (see Status schema / 01-MODEL §2).
COLOUR_STATUS = {"green": "ok", "yellow": "warning", "red": "critical",
                 "blue": "disabled", "clear": "nodata", "purple": "unknown"}
COLOUR_SEVERITY = {"red": "major", "purple": "critical", "yellow": "minor"}
# worst-of ordering for derived rollups (last = worst).
_WORST_ORDER = ["ok", "disabled", "nodata", "unknown", "warning", "critical"]


def xymondboard() -> str:
    """Raw xymondboard dump (structured fields) from the server."""
    cmd = [XYMON_BIN, XYMON_SERVER, f"xymondboard fields={','.join(BOARD_FIELDS)}"]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "xymondboard failed")
    return out.stdout


def _rows() -> list[dict]:
    rows: list[dict] = []
    for line in xymondboard().splitlines():
        if line.strip():
            rows.append(dict(zip(BOARD_FIELDS, line.split("|"))))
    return rows


def _iso(epoch: str) -> str | None:
    try:
        return datetime.fromtimestamp(int(epoch), timezone.utc) \
            .isoformat().replace("+00:00", "Z")
    except (ValueError, TypeError, OSError, OverflowError):
        return None


def states(entity: str | None = None, test: str | None = None,
           verdict: str | None = None) -> list[dict]:
    """Board rows as conformant State objects (one per host+test, item-level
    deferred)."""
    out: list[dict] = []
    for d in _rows():
        host, tst = d.get("hostname", "?"), d.get("testname", "?")
        st = {"id": f"{host}:{tst}", "entity": host, "test": tst,
              "verdict": COLOUR_STATUS.get(d.get("color", "clear"), "unknown")}
        t = _iso(d.get("lastchange", ""))
        if t:
            st["time"] = t
        out.append(st)
    if entity:
        out = [s for s in out if s["entity"] == entity]
    if test:
        out = [s for s in out if s["test"] == test]
    if verdict:
        out = [s for s in out if s["verdict"] == verdict]
    return out


def alarms() -> list[dict]:
    """Non-ok states surfaced as conformant Alarm objects."""
    res: list[dict] = []
    for d in _rows():
        colour = d.get("color", "clear")
        if COLOUR_STATUS.get(colour, "unknown") == "ok":
            continue
        host, tst = d.get("hostname", "?"), d.get("testname", "?")
        a = {"id": f"{host}:{tst}", "entity": host, "test": tst,
             "severity": COLOUR_SEVERITY.get(colour, "minor"), "status": "firing"}
        t = _iso(d.get("lastchange", ""))
        if t:
            a["since"] = t
        res.append(a)
    return res


def entities() -> list[dict]:
    """Distinct hosts as measured entities (role label, never branched on)."""
    seen: dict[str, dict] = {}
    for d in _rows():
        host = d.get("hostname", "?")
        seen.setdefault(host, {"id": host, "composition": "measured",
                               "labels": {"role": "host"}})
    return list(seen.values())


def reduce_worst(member_states: list[dict]) -> str:
    """Verdict of a derived entity = worst of its members (the rollup)."""
    worst = "ok"
    for s in member_states:
        v = s.get("verdict", "unknown")
        if v in _WORST_ORDER and _WORST_ORDER.index(v) > _WORST_ORDER.index(worst):
            worst = v
    return worst
