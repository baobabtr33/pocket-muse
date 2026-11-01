"""Shared paths, model IDs, prices and the student's prompt format."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
ROUTES_FILE = DATA_DIR / "routes.json"
DEMO_FILE = DATA_DIR / "demo.json"
SCENARIOS_FILE = DATA_DIR / "scenarios.json"

# Generated artifacts (gitignored).
ARTIFACTS = ROOT / "artifacts"
PACKS_DIR = ARTIFACTS / "packs"
CLOUD_CACHE_FILE = ARTIFACTS / "cloud_cache.json"

# Students: Meta's small open Llama 3.2 models. Each pack is a LoRA adapter on one of them, fused.
STUDENTS = {
    "1b": "mlx-community/Llama-3.2-1B-Instruct-bf16",  # default: fast enough to train live on stage
    "3b": "mlx-community/Llama-3.2-3B-Instruct-bf16",  # better answers, slower to train
}
DEFAULT_STUDENT = "1b"
# Router and pack retrieval embeddings.
EMBED_MODEL = "BAAI/bge-small-en-v1.5"

# Cloud model ("big Muse"): teaches the packs while online, answers hard questions when online.
# Pick with CLOUD_PROVIDER=baseten|anthropic. Prices are USD per million tokens; reasoning bills as output.
CLOUD_PROVIDERS = {
    "baseten": {
        "label": "Muse Spark Open",
        "model": "meta-models/muse-spark-open-1026",  # open Muse Spark (816B-A42B); the hackathon key only accepts this ID
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


# "Hey Meta, ..." is the glasses' wake word, not part of the question.
WAKE = re.compile(r"^\s*(hey|hi|ok|okay)[\s,]+meta[\s,.!:]*", re.IGNORECASE)


def strip_wake(question: str) -> str:
    return WAKE.sub("", question).strip() or question


def student_system_prompt(pack_title: str, today: str, notes: str) -> str:
    """Training and inference must use this exact format."""
    return (
        f"You are Pocket Muse, the on-device part of Muse. Muse prepared you ahead for: {pack_title}. "
        f"Today is {today}.\n"
        "Answer in 1-2 short sentences using only the pack notes below. "
        f"If the notes do not answer the question, say \"{NOT_IN_PACK}\" and that you will ask Muse "
        "when you're online.\n\n"
        f"Pack notes:\n{notes}"
    )


def format_card(card: dict) -> str:
    return f"## {card['title']}\n" + "\n".join(f"- {f}" for f in card["facts"])
