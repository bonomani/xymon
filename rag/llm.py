"""LLM providers: answer a prompt given retrieved Xymon context.

Backends, chosen by ``Config.llm_provider``:

* ``anthropic`` -- Claude via the Anthropic API (needs ``ANTHROPIC_API_KEY``).
* ``openai``    -- GPT models via the OpenAI API (needs ``OPENAI_API_KEY``).
* ``local``     -- any OpenAI-compatible local endpoint (Ollama, llama.cpp,
                   vLLM) at ``Config.llm_base_url`` -- nothing leaves the host.
"""
from __future__ import annotations

from typing import Protocol

from config import Config


class LLM(Protocol):
    def complete(self, system: str, user: str) -> str: ...


class AnthropicLLM:
    def __init__(self, model: str) -> None:
        import anthropic  # lazy
        self._client = anthropic.Anthropic()
        self._model = model

    def complete(self, system: str, user: str) -> str:
        msg = self._client.messages.create(
            model=self._model, max_tokens=1024, system=system,
            messages=[{"role": "user", "content": user}])
        return "".join(b.text for b in msg.content if b.type == "text")


class OpenAICompatLLM:
    """OpenAI API and any OpenAI-compatible local server share this client."""

    def __init__(self, model: str, base_url: str | None = None) -> None:
        from openai import OpenAI  # lazy
        # base_url=None -> real OpenAI; set -> local endpoint.
        self._client = OpenAI(base_url=base_url) if base_url else OpenAI()
        self._model = model

    def complete(self, system: str, user: str) -> str:
        resp = self._client.chat.completions.create(
            model=self._model,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}])
        return resp.choices[0].message.content or ""


def build(cfg: Config) -> LLM:
    if cfg.llm_provider == "anthropic":
        return AnthropicLLM(cfg.llm_model)
    if cfg.llm_provider == "openai":
        return OpenAICompatLLM(cfg.llm_model)
    if cfg.llm_provider == "local":
        return OpenAICompatLLM(cfg.llm_model, base_url=cfg.llm_base_url)
    raise ValueError(f"unknown llm provider: {cfg.llm_provider!r}")
