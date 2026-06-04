"""Offline self-test: exercise the whole pipeline with no heavy deps.

Real embeddings (sentence-transformers/torch), the real vector DB (ChromaDB)
and the real LLM (Anthropic/OpenAI) are replaced by tiny pure-Python fakes, so
this runs anywhere -- it validates the *glue* (board parsing, chunking, ingest
orchestration, retrieval ranking, prompt assembly, LLM call shape), not the
swappable backends.

    python selftest.py        # prints a short report, exits non-zero on failure
"""
from __future__ import annotations

import hashlib
import math
import sys

import ingest
import query
import xymon_export
from config import Config

_DIM = 64


def _hash_embed(text: str) -> list[float]:
    """Deterministic bag-of-words vector, L2-normalised. No numpy."""
    vec = [0.0] * _DIM
    for word in text.lower().split():
        h = int.from_bytes(hashlib.blake2b(word.encode(), digest_size=4)
                           .digest(), "big")
        vec[h % _DIM] += 1.0
    norm = math.sqrt(sum(x * x for x in vec)) or 1.0
    return [x / norm for x in vec]


class FakeEmbedder:
    def embed(self, texts: list[str]) -> list[list[float]]:
        return [_hash_embed(t) for t in texts]


class FakeStore:
    """In-memory cosine-NN store mirroring store.VectorStore's interface."""

    def __init__(self) -> None:
        self._ids: list[str] = []
        self._vecs: list[list[float]] = []
        self._docs: list[str] = []
        self._meta: list[dict] = []

    def upsert(self, chunks, vectors) -> None:
        for c, v in zip(chunks, vectors):
            if c["id"] in self._ids:                       # upsert semantics
                i = self._ids.index(c["id"])
                self._vecs[i], self._docs[i], self._meta[i] = v, c["text"], c["meta"]
            else:
                self._ids.append(c["id"])
                self._vecs.append(v)
                self._docs.append(c["text"])
                self._meta.append(c["meta"])

    def query(self, vector, top_k) -> list[dict]:
        scored = []
        for v, doc, meta in zip(self._vecs, self._docs, self._meta):
            sim = sum(a * b for a, b in zip(vector, v))    # both normalised
            scored.append((sim, doc, meta))
        scored.sort(key=lambda t: t[0], reverse=True)
        return [{"text": d, "meta": m, "distance": 1 - s}
                for s, d, m in scored[:top_k]]

    def count(self) -> int:
        return len(self._ids)


class FakeLLM:
    """Echoes the hosts it was given so we can assert the right context flowed."""

    def complete(self, system: str, user: str) -> str:
        assert "system administrator" in system.lower()
        hosts = sorted({ln.split("host=")[1].split()[0]
                        for ln in user.splitlines() if "host=" in ln})
        return f"[fake-llm] answered from hosts: {', '.join(hosts)}"


_BOARD = "\n".join([
    "db01|disk|red|1700000000|/var 98% full|Filesystem /var is 98% full - CRITICAL",
    "db01|conn|green|1700000000|ok|Connection OK",
    "web01|http|yellow|1700000100|slow|HTTP latency high (2.1s)",
    "web01|cpu|green|1700000100|ok|CPU load normal",
])


def main() -> int:
    cfg = Config()
    cfg.top_k = 3
    ok = True

    # 1. board parsing -- inject synthetic xymondboard output
    xymon_export._xymondboard = lambda c: _BOARD          # type: ignore
    docs = xymon_export.export(cfg, "status")
    print(f"1. export(status): {len(docs)} docs")
    ok &= len(docs) == 4
    ok &= any(d["meta"]["host"] == "db01" and d["meta"]["color"] == "red"
              for d in docs)

    # 2. full ingest with fakes
    store, embedder = FakeStore(), FakeEmbedder()
    n = ingest.run(cfg, "status", embedder=embedder, store=store)
    print(f"2. ingest: {n} chunks, store holds {store.count()}")
    ok &= store.count() == n >= 4

    # 3. retrieval ranks the right host first
    hits = store.query(embedder.embed(["why is db01 disk red, /var full?"])[0],
                       cfg.top_k)
    top = hits[0]["meta"]["host"]
    print(f"3. retrieve top host for 'db01 disk full' -> {top}")
    ok &= top == "db01"

    # 4. end-to-end query through the prompt + (fake) LLM
    ans = query.answer(cfg, "why is db01 red and what is the cause?",
                       embedder=embedder, store=store, model=FakeLLM())
    print(f"4. answer: {ans}")
    ok &= "db01" in ans

    print("\n" + ("✅ PASS" if ok else "❌ FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
