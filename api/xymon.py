"""Real read backend: map a live Xymon server onto the API's schemas.

Minimal parsing by design (see docs/api/ and rag/PLAN.md): the data comes from
``xymondboard``'s *structured* fields (split on ``|``), with colour mapped to
the semantic verdict. No status-message body parsing, no flat files. ``metrics``
and multi-``item`` decomposition are deferred (optional in the schema), and the
numeric history is ``/series`` (rrdtool xport) and ``/graphs`` (showgraph CGI
proxy). Optional HTTP Basic auth reuses Xymon's web htpasswd.

The subprocess/HTTP/crypt seams (``xymondboard``, ``rrd_xport``,
``fetch_graph``, ``verify_basic``) are module-level so tests can substitute
synthetic data without a live server.
"""
from __future__ import annotations

import base64
import binascii
import hmac
import json
import os
import subprocess
from datetime import datetime, timezone
from urllib.parse import urlencode

XYMON_BIN = os.environ.get("XYMON_BIN", "xymon")
XYMON_SERVER = os.environ.get("XYMON_SERVER", "127.0.0.1")
RRDDIR = os.environ.get("XYMON_RRDDIR", "/var/lib/xymon/rrd")
CGI_URL = os.environ.get("XYMON_CGI_URL", "http://localhost/xymon-cgi").rstrip("/")
PASSWD_FILE = os.environ.get("XYMON_API_PASSWD", "")  # htpasswd; empty = auth off
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


# --- /series : rrdtool xport ------------------------------------------------
def rrd_xport(args: list[str]) -> str:
    """Run ``rrdtool xport --json ...`` and return its stdout (injectable)."""
    out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "rrdtool xport failed")
    return out.stdout


def series(entity: str, test: str, metric: str | None = None,
           frm: str = "-24h", to: str = "now") -> dict:
    """One numeric Series for (entity, test, metric) from its RRD.

    rrdtool accepts relative times (`-24h`, `now`) natively, so `from`/`to` pass
    through. DS name = metric; the RRD path follows Xymon's `<host>/<test>.rrd`
    convention (item-keyed files are a later refinement).
    """
    ds = metric or "lambda"
    rrd = f"{RRDDIR}/{entity}/{test}.rrd"
    raw = rrd_xport(["rrdtool", "xport", "--json", "--start", frm, "--end", to,
                     f"DEF:v={rrd}:{ds}:AVERAGE", "XPORT:v:v"])
    doc = json.loads(raw)
    meta = doc.get("meta", {})
    start, step = int(meta.get("start", 0)), int(meta.get("step", 1) or 1)
    points = []
    for i, row in enumerate(doc.get("data", [])):
        v = row[0] if row else None
        points.append({"t": _iso(str(start + i * step)) or
                       "1970-01-01T00:00:00Z", "v": v})
    labels = {"entity": entity or "", "test": test or ""}  # Labels values = str
    if metric:
        labels["metric"] = metric
    out = {"labels": labels, "points": points}
    if metric:
        out["metric"] = metric
    return out


# --- /graphs : proxy Xymon's showgraph CGI ----------------------------------
def fetch_graph(url: str) -> tuple[bytes, str]:
    """GET an image URL; return (bytes, content-type) (injectable)."""
    import httpx
    r = httpx.get(url, timeout=30)
    r.raise_for_status()
    return r.content, r.headers.get("content-type", "image/png")


def graph(entity: str | None = None, test: str | None = None,
          frm: str = "-24h", to: str = "now", fmt: str = "png") -> tuple[bytes, str]:
    """Proxy a rendered RRD graph from Xymon's showgraph CGI."""
    q = urlencode({"host": entity or "", "service": test or "",
                   "first": frm, "last": to, "action": "view", "format": fmt})
    data, ctype = fetch_graph(f"{CGI_URL}/showgraph.sh?{q}")
    if not ctype:
        ctype = "image/svg+xml" if fmt == "svg" else "image/png"
    return data, ctype


# --- HTTP Basic auth (optional; reuses Xymon's web htpasswd) -----------------
def parse_basic(header: str | None) -> tuple[str, str] | None:
    if not header or not header.lower().startswith("basic "):
        return None
    try:
        raw = base64.b64decode(header[6:].strip()).decode("utf-8", "replace")
    except (binascii.Error, ValueError):
        return None
    if ":" not in raw:
        return None
    user, password = raw.split(":", 1)
    return user, password


def verify_basic(user: str, password: str) -> bool:
    """Check (user, password) against the htpasswd PASSWD_FILE (crypt entries)."""
    if not PASSWD_FILE or not os.path.isfile(PASSWD_FILE):
        return False
    import crypt
    try:
        with open(PASSWD_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or ":" not in line:
                    continue
                u, h = line.split(":", 1)
                if u == user:
                    return hmac.compare_digest(crypt.crypt(password, h), h)
    except OSError:
        return False
    return False
