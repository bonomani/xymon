"""Split exported Xymon documents into overlapping word-window chunks.

Histories and long status messages are cut into small logical blocks so the
retriever can match a query against a focused passage instead of a whole file.
Each chunk keeps a back-reference to its parent document id and metadata.
"""
from __future__ import annotations

from typing import Iterator

from config import Config


def _windows(words: list[str], size: int, overlap: int) -> Iterator[list[str]]:
    if size <= 0:
        raise ValueError("chunk size must be positive")
    step = max(1, size - overlap)
    for start in range(0, max(1, len(words)), step):
        window = words[start:start + size]
        if window:
            yield window
        if start + size >= len(words):
            break


def chunk_doc(doc: dict, cfg: Config) -> list[dict]:
    words = doc["text"].split()
    chunks: list[dict] = []
    for i, window in enumerate(_windows(words, cfg.chunk_words,
                                        cfg.chunk_overlap)):
        chunks.append({
            "id": f"{doc['id']}#{i}",
            "text": " ".join(window),
            "meta": {**doc["meta"], "parent": doc["id"], "chunk": i},
        })
    return chunks


def chunk_all(docs: list[dict], cfg: Config) -> list[dict]:
    out: list[dict] = []
    for doc in docs:
        out.extend(chunk_doc(doc, cfg))
    return out
