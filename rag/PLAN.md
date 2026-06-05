# Xymon RAG — Plan

Single plan for the `rag/` subproject. Done items are deleted; refused items
keep a one-line reason.

## Done

- 3-part pipeline scaffold (extract → ingest → generate), provider-agnostic.
- Injectable backends + offline `selftest.py` (glue validated).
- Real retrieval verified: BGE embeddings + ChromaDB rank the correct
  host/test first, including the root-cause history chunk.
- `api` source: the RAG consumes the canonical Xymon REST API (the
  `feat/openapi` branch's `/states`) over HTTP -- `states_to_docs()` +
  `api_status_docs()`, tested offline (`test_api_source.py`). The earlier local
  `xymon_api.py` facade was removed; the canonical API (spec + mock + real read
  backend) lives on `feat/openapi`, so we don't ship two competing APIs.

## Next — LLM generation test

The retrieval half is proven; the generation half is still unexercised.

1. **Local / private path (Ollama)** — no data leaves the host.
   - `export XYMON_RAG_LLM=local XYMON_RAG_LLM_URL=http://localhost:11434/v1 XYMON_RAG_LLM_MODEL=llama3.1`
   - `python query.py "why is db01 red and what is the cause?"` against the
     `sample.json` store.
   - Acceptance: answer cites `db01`/`disk` and the `/var full` cause, drawn
     only from context.
2. **API path** — `XYMON_RAG_LLM=anthropic` (`ANTHROPIC_API_KEY`) or `=openai`.
   - Same acceptance check.
3. Add a `--show-context` flag to `query.py` to print the retrieved chunks
   alongside the answer (debuggability + manual grounding check).
4. Smoke test in `selftest.py` already covers the call shape; add one real
   integration test gated behind an env flag (skip when no backend reachable).

## MVP hardening

- **Scheduled re-ingestion** — a thin runner (`scheduler.py` or a systemd
  timer / cron snippet in `docs/`) that runs `ingest.py status` every N
  minutes and `ingest.py history` daily. Make N configurable.
- **Incremental updates** — avoid re-embedding unchanged data:
  - content-hash each chunk (blake2b of `text`); skip upsert when the stored
    hash matches (store the hash in chunk metadata).
  - prune vectors whose parent doc disappeared from the board (stale hosts).
- **Xymon server auth / transport** — current `xymon_export` assumes an open
  `xymondboard` on `XYMON_SERVER`. Add:
  - TLS / `xymonsend` over the documented port; configurable timeout/retries.
  - optional shared-secret / source-IP note in the README (Xymon ACLs).
  - graceful per-host failure (skip + log) instead of aborting the export.
- **Canonical REST API (on `feat/openapi`)** — harden it there, not here: real
  `/series` (rrdtool) + `/graphs` (showgraph CGI proxy), HTTP Basic auth reusing
  Xymon's web users, then derived-entity rollups. The RAG's `api` source then
  gets richer data for free.

## Later (not MVP)

- Evaluation harness: a fixed Q→expected-host set, assert retrieval@k.
- Citations rendered as `[host/test]` footnotes in the answer.
- Metrics source (RRD values) in addition to status/history text.
- Web/API front end (FastAPI) — refused for now: CLI is enough for the MVP,
  revisit once generation is validated.
