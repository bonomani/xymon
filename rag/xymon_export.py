"""Extract Xymon data into structured JSON documents for the RAG pipeline.

Two sources, selectable on the command line:

* ``status``  -- the live board: every host/test current colour + status text,
                 pulled with ``xymon <server> "xymondboard ..."``.
* ``history`` -- the per-host flat-file history under ``XYMON_HISTDIR``: the
                 record of past state changes (the "panne" timeline).

Each document is a dict with a stable ``id`` plus ``text`` (what gets embedded)
and ``meta`` (host/test/colour/time, kept for filtering and citation).
"""
from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Iterator

from config import Config

# Fields requested from xymondboard, in order; matched to keys below.
_BOARD_FIELDS = ["hostname", "testname", "color", "lastchange", "line1", "msg"]


def _xymondboard(cfg: Config) -> str:
    """Return the raw xymondboard dump from the server."""
    fields = ",".join(_BOARD_FIELDS)
    cmd = [cfg.xymon_bin, cfg.xymon_server,
           f"xymondboard fields={fields}"]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(f"xymondboard failed: {out.stderr.strip()}")
    return out.stdout


def parse_board(raw: str) -> list[dict]:
    """Parse a xymondboard dump into structured rows (host/test/color/msg)."""
    rows: list[dict] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        row = dict(zip(_BOARD_FIELDS, line.split("|")))
        msg = (row.get("msg") or row.get("line1") or "").replace("\\n", "\n")
        rows.append({
            "host": row.get("hostname", "?"),
            "test": row.get("testname", "?"),
            "color": row.get("color", "?"),
            "lastchange": row.get("lastchange", ""),
            "msg": msg.strip(),
        })
    return rows


def status_rows(cfg: Config) -> list[dict]:
    """Structured live board rows -- shared by the RAG export and REST API."""
    return parse_board(_xymondboard(cfg))


def host_history(cfg: Config, host: str) -> str | None:
    """Return one host's raw state-change history, or None if absent."""
    path = cfg.xymon_histdir / host
    if not path.is_file():
        return None
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def iter_status(cfg: Config) -> Iterator[dict]:
    """Yield one document per host/test from the live board."""
    for r in status_rows(cfg):
        text = (f"Host {r['host']}, test {r['test']} is {r['color'].upper()}.\n"
                f"{r['msg']}")
        yield {
            "id": f"status:{r['host']}:{r['test']}",
            "text": text,
            "meta": {"source": "status", "host": r["host"], "test": r["test"],
                     "color": r["color"], "lastchange": r["lastchange"]},
        }


def iter_history(cfg: Config) -> Iterator[dict]:
    """Yield one document per host history file (state-change timeline)."""
    histdir = cfg.xymon_histdir
    if not histdir.is_dir():
        raise FileNotFoundError(f"history dir not found: {histdir}")
    for path in sorted(histdir.glob("*")):
        if not path.is_file():
            continue
        host = path.name
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        if not text.strip():
            continue
        yield {
            "id": f"history:{host}",
            "text": f"State-change history for host {host}:\n{text}",
            "meta": {"source": "history", "host": host},
        }


def states_to_docs(states: list[dict]) -> list[dict]:
    """Map Xymon REST API State objects to RAG documents (pure; no network)."""
    docs: list[dict] = []
    for s in states:
        ent, test = s.get("entity", "?"), s.get("test", "?")
        verdict = s.get("verdict", "unknown")
        metrics = s.get("metrics") or {}
        mtxt = "; ".join(
            f"{k}={m.get('value')}"
            + (f" ({m['verdict']})" if isinstance(m, dict) and m.get("verdict")
               else "")
            for k, m in metrics.items())
        text = f"Entity {ent}, test {test} is {verdict.upper()}."
        if mtxt:
            text += f"\n{mtxt}"
        docs.append({
            "id": s.get("id", f"{ent}:{test}"),
            "text": text,
            "meta": {"source": "api", "host": ent, "test": test,
                     "color": verdict, "lastchange": s.get("time", "")},
        })
    return docs


def api_status_docs(cfg: Config) -> list[dict]:
    """Pull current states from the Xymon REST API and map them to documents."""
    import httpx
    base = cfg.xymon_api_url.rstrip("/")
    with httpx.Client(timeout=30) as client:
        resp = client.get(f"{base}/states")
        resp.raise_for_status()
        states = resp.json().get("items", [])
    return states_to_docs(states)


def export(cfg: Config, source: str) -> list[dict]:
    if source == "status":
        return list(iter_status(cfg))
    if source == "history":
        return list(iter_history(cfg))
    if source == "api":
        return api_status_docs(cfg)
    raise ValueError(f"unknown source: {source!r} (use status|history|api)")


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", choices=["status", "history", "api"])
    ap.add_argument("-o", "--out", type=Path, default=Path("xymon-docs.json"))
    args = ap.parse_args()

    cfg = Config()
    docs = export(cfg, args.source)
    args.out.write_text(json.dumps(docs, indent=2, ensure_ascii=False))
    print(f"{len(docs)} document(s) -> {args.out} "
          f"({time.strftime('%Y-%m-%d %H:%M:%S')})")


if __name__ == "__main__":
    main()
