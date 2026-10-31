"""Big Muse in the cloud: teaches packs while online, answers questions a pack can't.

Providers:
  baseten   - Meta's Muse Spark Open via Baseten (OpenAI-compatible API). Default.
  anthropic - Claude via the Anthropic API.

Answers to user questions are cached on disk by provider and question, so a rehearsed
question still works if the venue network fails. Cost = real token usage x list price.
"""

import json
import os
from dataclasses import dataclass

from .config import CLOUD_CACHE_FILE, CLOUD_PROVIDERS, DEFAULT_CLOUD_PROVIDER

SYSTEM = (
    "You are Muse, a helpful personal assistant. Answer clearly in under 150 words. "
    "Use plain text and simple math like A*v = 3*v; no LaTeX."
)


@dataclass
class CloudAnswer:
    text: str
    input_tokens: int
    output_tokens: int
    provider: str
    cached: bool = False

    @property
    def cost(self) -> float:
        return token_cost(self.provider, self.input_tokens, self.output_tokens)


def token_cost(provider: str, input_tokens: int, output_tokens: int) -> float:
    price = CLOUD_PROVIDERS[provider]["price_per_mtok"]
    return (input_tokens * price["input"] + output_tokens * price["output"]) / 1_000_000


def api_key(provider: str) -> str | None:
    for name in CLOUD_PROVIDERS[provider]["key_env"]:
        if os.environ.get(name):
            return os.environ[name]
    return None


class CloudModel:
    def __init__(self, provider: str | None = None):
        self.provider = provider or os.environ.get("CLOUD_PROVIDER", DEFAULT_CLOUD_PROVIDER)
        self.spec = CLOUD_PROVIDERS[self.provider]
        self.cache = json.loads(CLOUD_CACHE_FILE.read_text()) if CLOUD_CACHE_FILE.exists() else {}
        self.client = self._client()

    def _client(self):
        if self.provider == "baseten":
            from openai import OpenAI

            return OpenAI(base_url=self.spec["base_url"], api_key=api_key("baseten") or "missing", timeout=120)
        import anthropic

        return anthropic.Anthropic()

    def complete(self, system: str, user: str, max_tokens: int = 8000, effort: str = "low") -> CloudAnswer:
        """One uncached call. Used by the pack builder."""
        if self.provider == "baseten":
            # Muse Spark always reasons; reasoning comes back separately and the answer is in content.
            response = self.client.chat.completions.create(
                model=self.spec["model"],
                messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
                max_tokens=max_tokens,
                reasoning_effort=effort,
            )
            text = (response.choices[0].message.content or "").strip()
            return CloudAnswer(text, response.usage.prompt_tokens, response.usage.completion_tokens, self.provider)
        response = self.client.beta.messages.create(
            model=self.spec["model"],
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
            output_config={"effort": effort},
            betas=["server-side-fallback-2026-07-01"],
            extra_body={"fallbacks": "default"},
        )
        if response.stop_reason == "refusal":
            text = "The cloud model declined this request."
        else:
            text = "".join(b.text for b in response.content if b.type == "text").strip()
        return CloudAnswer(text, response.usage.input_tokens, response.usage.output_tokens, self.provider)

    def answer(self, question: str, context: str = "") -> CloudAnswer:
        """Answer a user question; falls back to the disk cache if the call fails.

        context: what Muse already knows about the user's coming days (it's their personal assistant).
        """
        key = self.provider + ":" + " ".join(question.lower().split())
        system = SYSTEM + (f"\n\nWhat you know about the user:\n{context}" if context else "")
        try:
            result = self.complete(system, question, max_tokens=4000)
        except Exception:
            if key in self.cache:
                return CloudAnswer(**self.cache[key], cached=True)
            raise
        self.cache[key] = {
            "text": result.text,
            "input_tokens": result.input_tokens,
            "output_tokens": result.output_tokens,
            "provider": result.provider,
        }
        CLOUD_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CLOUD_CACHE_FILE.write_text(json.dumps(self.cache, indent=2))
        return result
