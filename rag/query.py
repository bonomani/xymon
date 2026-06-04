"""Ask a question against the indexed Xymon data (retrieve + generate).

    python query.py "why is host db01 red?"
    python query.py "what failed overnight on the web tier?" --k 8

Retrieves the top-k most relevant chunks from the vector store, builds the
expert-sysadmin prompt, and sends it to the configured LLM.
"""
from __future__ import annotations

import argparse

import embed as embedding
import llm as llm_mod
import prompts
from config import Config
from store import VectorStore


def answer(cfg: Config, question: str, top_k: int | None = None,
           *, embedder=None, store=None, model=None) -> str:
    k = top_k or cfg.top_k
    # Injectable backends (see ingest.run) for dependency-free testing.
    store = store or VectorStore(cfg)
    if store.count() == 0:
        return "The vector store is empty -- run ingest.py first."

    qvec = (embedder or embedding.build(cfg)).embed([question])[0]
    hits = store.query(qvec, k)

    model = model or llm_mod.build(cfg)
    user = prompts.build_user_prompt(question, hits)
    return model.complete(prompts.SYSTEM, user)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("question")
    ap.add_argument("--k", type=int, default=None, help="top-k chunks")
    args = ap.parse_args()
    print(answer(Config(), args.question, args.k))


if __name__ == "__main__":
    main()
