"""Ingestion pipeline: Xymon -> documents -> chunks -> embeddings -> store.

    python ingest.py status      # index the live board
    python ingest.py history      # index the state-change history
    python ingest.py status --json xymon-docs.json   # index a saved export
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import chunk as chunking
import embed as embedding
import xymon_export
from config import Config
from store import VectorStore


def run(cfg: Config, source: str, json_path: Path | None = None,
        *, embedder=None, store=None) -> int:
    if json_path is not None:
        docs = json.loads(json_path.read_text())
    else:
        docs = xymon_export.export(cfg, source)

    chunks = chunking.chunk_all(docs, cfg)
    if not chunks:
        print("nothing to ingest")
        return 0

    # Backends are injectable so the pipeline is testable without the heavy
    # ML/DB deps; default to the real ones from config.
    embedder = embedder or embedding.build(cfg)
    vectors = embedder.embed([c["text"] for c in chunks])

    store = store or VectorStore(cfg)
    store.upsert(chunks, vectors)
    print(f"ingested {len(chunks)} chunk(s) from {len(docs)} doc(s); "
          f"collection now holds {store.count()} chunk(s)")
    return len(chunks)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", choices=["status", "history"])
    ap.add_argument("--json", type=Path, default=None,
                    help="ingest a saved xymon_export JSON instead of polling")
    args = ap.parse_args()
    run(Config(), args.source, args.json)


if __name__ == "__main__":
    main()
