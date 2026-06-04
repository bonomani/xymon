"""Central configuration for the Xymon RAG pipeline.

Everything is driven by environment variables so the same code runs against an
online LLM (Anthropic/OpenAI) or a fully local/private stack, and against either
the live Xymon board or the historical logs -- the two open design choices stay
configuration, not code forks.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass
class Config:
    # --- Xymon source -----------------------------------------------------
    # Path to the `xymon` client binary and the server address it talks to.
    xymon_bin: str = field(default_factory=lambda: _env("XYMON_BIN", "xymon"))
    xymon_server: str = field(
        default_factory=lambda: _env("XYMON_SERVER", "127.0.0.1"))
    # Where Xymon keeps host history (flat files), used for the history source.
    xymon_histdir: Path = field(
        default_factory=lambda: Path(_env("XYMON_HISTDIR",
                                          "/var/lib/xymon/hist")))

    # --- Embeddings -------------------------------------------------------
    # "local"  -> sentence-transformers (no network, privacy-friendly)
    # "openai" -> OpenAI embeddings API
    embed_provider: str = field(
        default_factory=lambda: _env("XYMON_RAG_EMBED", "local"))
    embed_model: str = field(
        default_factory=lambda: _env("XYMON_RAG_EMBED_MODEL",
                                     "BAAI/bge-small-en-v1.5"))

    # --- Vector store -----------------------------------------------------
    store_dir: Path = field(
        default_factory=lambda: Path(_env("XYMON_RAG_STORE", "./rag_store")))
    collection: str = field(
        default_factory=lambda: _env("XYMON_RAG_COLLECTION", "xymon"))

    # --- LLM --------------------------------------------------------------
    # "anthropic" | "openai" | "local"  (local = OpenAI-compatible endpoint,
    # e.g. Ollama / llama.cpp server)
    llm_provider: str = field(
        default_factory=lambda: _env("XYMON_RAG_LLM", "anthropic"))
    llm_model: str = field(
        default_factory=lambda: _env("XYMON_RAG_LLM_MODEL",
                                     "claude-opus-4-8"))
    llm_base_url: str = field(
        default_factory=lambda: _env("XYMON_RAG_LLM_URL",
                                     "http://localhost:11434/v1"))

    # --- Chunking / retrieval --------------------------------------------
    chunk_words: int = field(
        default_factory=lambda: int(_env("XYMON_RAG_CHUNK_WORDS", "180")))
    chunk_overlap: int = field(
        default_factory=lambda: int(_env("XYMON_RAG_CHUNK_OVERLAP", "30")))
    top_k: int = field(default_factory=lambda: int(_env("XYMON_RAG_TOPK", "6")))


def load() -> Config:
    return Config()
