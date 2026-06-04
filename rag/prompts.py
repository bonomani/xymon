"""System prompt and context assembly for the Xymon RAG assistant."""
from __future__ import annotations

SYSTEM = (
    "You are an expert system administrator analysing a Xymon (formerly "
    "Hobbit) monitoring deployment. Use ONLY the Xymon data provided in the "
    "context to explain host/service state and the likely root cause of an "
    "outage. Cite the host and test you rely on. If the context does not "
    "contain the answer, say so plainly instead of guessing."
)


def build_user_prompt(question: str, hits: list[dict]) -> str:
    blocks: list[str] = []
    for i, h in enumerate(hits, 1):
        m = h.get("meta", {})
        tag = f"[{i}] host={m.get('host', '?')} test={m.get('test', '-')} " \
              f"source={m.get('source', '?')}"
        blocks.append(f"{tag}\n{h['text']}")
    context = "\n\n".join(blocks) if blocks else "(no matching Xymon data)"
    return f"Question: {question}\n\nXymon context:\n{context}"
