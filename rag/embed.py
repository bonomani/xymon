"""Embedding providers: turn text into vectors.

Two backends, chosen by ``Config.embed_provider``:

* ``local``  -- sentence-transformers, runs on your hardware, no data leaves
                the host (recommended for infrastructure data).
* ``openai`` -- OpenAI embeddings API (needs ``OPENAI_API_KEY``).

Heavy SDKs are imported lazily so the module loads even when only one backend
is installed.
"""
from __future__ import annotations

from typing import Protocol

from config import Config


class Embedder(Protocol):
    def embed(self, texts: list[str]) -> list[list[float]]: ...


class LocalEmbedder:
    def __init__(self, model: str) -> None:
        from sentence_transformers import SentenceTransformer  # lazy
        self._model = SentenceTransformer(model)

    def embed(self, texts: list[str]) -> list[list[float]]:
        vecs = self._model.encode(texts, normalize_embeddings=True)
        return [v.tolist() for v in vecs]


class OpenAIEmbedder:
    def __init__(self, model: str) -> None:
        from openai import OpenAI  # lazy
        self._client = OpenAI()
        self._model = model

    def embed(self, texts: list[str]) -> list[list[float]]:
        resp = self._client.embeddings.create(model=self._model, input=texts)
        return [d.embedding for d in resp.data]


def build(cfg: Config) -> Embedder:
    if cfg.embed_provider == "local":
        return LocalEmbedder(cfg.embed_model)
    if cfg.embed_provider == "openai":
        model = cfg.embed_model
        if model.startswith("BAAI/"):          # local default; pick an API one
            model = "text-embedding-3-small"
        return OpenAIEmbedder(model)
    raise ValueError(f"unknown embed provider: {cfg.embed_provider!r}")
