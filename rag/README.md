# Xymon RAG

Use a Xymon (formerly Hobbit) deployment as a knowledge source for a
Retrieval-Augmented Generation assistant: an expert-sysadmin LLM that explains
host/service state and outage root causes from your own monitoring data.

## Architecture (3 parts)

```
 Xymon server                  ingestion (RAG)                    AI engine
 ┌──────────┐   export    ┌───────────────────────────┐     ┌──────────────┐
 │ board /  │ ──────────► │ chunk → embed → vector DB  │ ◄── │ retrieve +   │
 │ history  │  JSON docs  │        (ChromaDB)          │ k   │ prompt → LLM │
 └──────────┘             └───────────────────────────┘     └──────────────┘
   xymon_export.py     chunk.py / embed.py / store.py        query.py / llm.py
```

| File | Role |
|------|------|
| `xymon_export.py` | Pull the live **board** (`xymondboard`) or per-host **history** into structured JSON documents. |
| `chunk.py` | Split long docs into overlapping word-window chunks. |
| `embed.py` | Text → vectors. Backends: `local` (sentence-transformers) or `openai`. |
| `store.py` | Persistent ChromaDB vector store (swap to Qdrant/Milvus here). |
| `ingest.py` | Orchestrates export → chunk → embed → store. |
| `llm.py` | Answer generation. Backends: `anthropic`, `openai`, or `local` (Ollama/llama.cpp). |
| `prompts.py` | System prompt + context assembly. |
| `query.py` | Retrieve top-k + ask the LLM. |
| `xymon_api.py` | Optional REST/OpenAPI facade over Xymon (`/hosts` `/status` `/alerts` `/history`) for other consumers (n8n, dashboards, LLMs). |

## REST API facade (optional)

Xymon exposes only the TCP 1984 protocol, CGIs and flat files -- no native
REST/OpenAPI. `xymon_api.py` puts a small FastAPI layer in front so any modern
consumer reads clean JSON, with Swagger UI at `/docs`:

```bash
uvicorn xymon_api:app --host 0.0.0.0 --port 8080
# GET /hosts | /status?color=red | /alerts | /history/{host} | /openapi.json
```

It reuses the same extraction code as the RAG export, so the assistant and any
external tool see one consistent view.

## The two design choices are configuration, not forks

Both questions the architecture raises are env-driven (see `config.py`):

- **Online vs local LLM** — `XYMON_RAG_LLM=anthropic|openai|local`. `local`
  points at any OpenAI-compatible endpoint (`XYMON_RAG_LLM_URL`), so nothing
  leaves your servers. Embeddings default to **local** for the same reason.
- **Real-time vs history** — `ingest.py status` indexes current alerts;
  `ingest.py history` indexes the outage timeline. Run either or both.

## Quick start

```bash
pip install -r requirements.txt

# 1. index the live board (local embeddings, no network)
XYMON_SERVER=monitor.example.com python ingest.py status

# 2. ask (default LLM = Anthropic Claude; set ANTHROPIC_API_KEY)
python query.py "why is host db01 red and what is the likely cause?"
```

Fully private variant (no data leaves the host):

```bash
export XYMON_RAG_LLM=local XYMON_RAG_LLM_URL=http://localhost:11434/v1 \
       XYMON_RAG_LLM_MODEL=llama3.1
python query.py "what failed overnight on the web tier?"
```

## Status

Scaffold / MVP. Defaults: ChromaDB store, `BAAI/bge-small-en-v1.5` local
embeddings, Anthropic Claude LLM. Not yet wired: scheduled re-ingestion,
incremental updates, auth to the Xymon server, evaluation harness.
