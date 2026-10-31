"""Load a built pack and find the notes relevant to a question (offline)."""

import json
from pathlib import Path

import numpy as np

from .config import PACKS_DIR, format_card


def list_packs() -> list[Path]:
    packs = [p.parent for p in PACKS_DIR.glob("*/pack.json") if (p.parent / "adapters").exists()]
    return sorted(packs, key=lambda p: p.stat().st_mtime, reverse=True)


def resolve(name: str | None) -> Path:
    packs = list_packs()
    if not packs:
        raise SystemExit("No packs built yet. Run: uv run python pack.py \"<your plan>\"")
    if name is None:
        return packs[0]
    for p in packs:
        if p.name == name or p.name.startswith(name):
            return p
    raise SystemExit(f"No pack named {name!r}. Built packs: {', '.join(p.name for p in packs)}")


class Pack:
    def __init__(self, path: Path, encoder):
        self.path = path
        meta = json.loads((path / "pack.json").read_text())
        self.title, self.cards, self.meta = meta["title"], meta["cards"], meta
        self.pairs = json.loads((path / "pairs.json").read_text())
        self.adapter = path / "adapters"
        self.encoder = encoder
        # A card is found by its own text or by any of the practice questions written for it.
        texts, owners = [], []
        for i, card in enumerate(self.cards):
            texts.append(format_card(card))
            owners.append(i)
        for p in self.pairs:
            if p["split"] == "train" and p["card"] is not None:
                texts.append(p["q"])
                owners.append(p["card"])
        self.owners = np.array(owners)
        self.vectors = encoder.encode(texts, normalize_embeddings=True)

    def train_questions(self) -> list[str]:
        return [p["q"] for p in self.pairs if p["split"] == "train" and p["kind"] in ("qa", "smalltalk")]

    def notes_for(self, question: str, k: int = 2) -> str:
        q = self.encoder.encode([question], normalize_embeddings=True)[0]
        order = np.argsort(-(self.vectors @ q))
        picked = []
        for idx in order:
            card = int(self.owners[idx])
            if card not in picked:
                picked.append(card)
            if len(picked) == k:
                break
        return "\n\n".join(format_card(self.cards[i]) for i in picked)
