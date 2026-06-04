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


def iter_status(cfg: Config) -> Iterator[dict]:
    """Yield one document per host/test from the live board."""
    for raw in _xymondboard(cfg).splitlines():
        if not raw.strip():
            continue
        parts = raw.split("|")
        row = dict(zip(_BOARD_FIELDS, parts))
        host, test = row.get("hostname", "?"), row.get("testname", "?")
        color = row.get("color", "?")
        msg = (row.get("msg") or row.get("line1") or "").replace("\\n", "\n")
        text = (f"Host {host}, test {test} is {color.upper()}.\n"
                f"{msg.strip()}")
        yield {
            "id": f"status:{host}:{test}",
            "text": text,
            "meta": {"source": "status", "host": host, "test": test,
                     "color": color, "lastchange": row.get("lastchange", "")},
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


def export(cfg: Config, source: str) -> list[dict]:
    if source == "status":
        return list(iter_status(cfg))
    if source == "history":
        return list(iter_history(cfg))
    raise ValueError(f"unknown source: {source!r} (use status|history)")


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", choices=["status", "history"])
    ap.add_argument("-o", "--out", type=Path, default=Path("xymon-docs.json"))
    args = ap.parse_args()

    cfg = Config()
    docs = export(cfg, args.source)
    args.out.write_text(json.dumps(docs, indent=2, ensure_ascii=False))
    print(f"{len(docs)} document(s) -> {args.out} "
          f"({time.strftime('%Y-%m-%d %H:%M:%S')})")


if __name__ == "__main__":
    main()
