"""Vector store wrapper (ChromaDB, persistent on disk).

Kept behind a tiny interface so swapping in Qdrant/Milvus later only touches
this file. Vectors are supplied by ``embed.py`` -- Chroma stores them verbatim
and does the nearest-neighbour search at query time.
"""
from __future__ import annotations

from typing import Any

from config import Config


class VectorStore:
    def __init__(self, cfg: Config) -> None:
        import chromadb  # lazy
        self._client = chromadb.PersistentClient(path=str(cfg.store_dir))
        self._col = self._client.get_or_create_collection(
            cfg.collection, metadata={"hnsw:space": "cosine"})

    def upsert(self, chunks: list[dict], vectors: list[list[float]]) -> None:
        if not chunks:
            return
        self._col.upsert(
            ids=[c["id"] for c in chunks],
            embeddings=vectors,
            documents=[c["text"] for c in chunks],
            metadatas=[_flatten(c["meta"]) for c in chunks],
        )

    def query(self, vector: list[float], top_k: int) -> list[dict]:
        res = self._col.query(query_embeddings=[vector], n_results=top_k,
                              include=["documents", "metadatas", "distances"])
        hits: list[dict] = []
        for doc, meta, dist in zip(res["documents"][0], res["metadatas"][0],
                                   res["distances"][0]):
            hits.append({"text": doc, "meta": meta, "distance": dist})
        return hits

    def count(self) -> int:
        return self._col.count()


def _flatten(meta: dict[str, Any]) -> dict[str, Any]:
    # Chroma only accepts scalar metadata values.
    return {k: (v if isinstance(v, (str, int, float, bool)) else str(v))
            for k, v in meta.items()}
