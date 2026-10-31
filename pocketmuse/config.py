"""Shared paths, model IDs, prices and the student's prompt format."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
ROUTES_FILE = DATA_DIR / "routes.json"
DEMO_FILE = DATA_DIR / "demo.json"

# Generated artifacts (gitignored).
ARTIFACTS = ROOT / "artifacts"
PACKS_DIR = ARTIFACTS / "packs"
CLOUD_CACHE_FILE = ARTIFACTS / "cloud_cache.json"

# Student: an already-small open-weight model. Each pack is a LoRA adapter on top of it.
STUDENT_BASE_MODEL = "mlx-community/Qwen2.5-0.5B-Instruct-bf16"
# Router and pack retrieval embeddings.
EMBED_MODEL = "BAAI/bge-small-en-v1.5"

# Cloud model ("big Muse"): teaches the packs while online, answers hard questions when online.
# Pick with CLOUD_PROVIDER=baseten|anthropic. Prices are USD per million tokens; reasoning bills as output.
CLOUD_PROVIDERS = {
    "baseten": {
        "label": "Muse Spark",
        "model": "meta-models/muse-spark-open-1026",  # hackathon key only works with this exact name
        "base_url": "https://inference.baseten.co/v1",
        "key_env": ["baseten_meta", "BASETEN_API_KEY"],
        "price_per_mtok": {"input": 1.25, "output": 4.25},  # from Baseten /v1/models pricing, 2026-10-29
    },
    "anthropic": {
        "label": "Claude Opus 5.5",
        "model": "claude-opus-5-5",
        "key_env": ["ANTHROPIC_API_KEY"],
        "price_per_mtok": {"input": 4.00, "output": 20.00},
    },
}
DEFAULT_CLOUD_PROVIDER = "baseten"

# The edge model says this exact phrase when a question is outside its pack; the demo queues those.
NOT_IN_PACK = "That's not in your pack"


def student_system_prompt(pack_title: str, today: str, notes: str) -> str:
    """Training and inference must use this exact format."""
    return (
        f"You are Pocket Muse, an offline assistant packed for: {pack_title}. Today is {today}.\n"
        "Answer in 1-2 short sentences using only the pack notes below. "
        f"If the notes do not answer the question, say \"{NOT_IN_PACK}\" and that you will ask Muse "
        "when you're back online.\n\n"
        f"Pack notes:\n{notes}"
    )


def format_card(card: dict) -> str:
    return f"## {card['title']}\n" + "\n".join(f"- {f}" for f in card["facts"])
