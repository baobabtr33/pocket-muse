"""Load a built pack and find the notes relevant to a question (offline)."""

import json
import re
from datetime import date
from pathlib import Path

import numpy as np

from .config import DEFAULT_STUDENT, PACKS_DIR, STUDENTS, format_card


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


def focus(question: str) -> str:
    """'I'm not getting any signal. Where's the closest emergency kit?' -> the part that asks something.
    Preamble sentences otherwise pull retrieval toward the wrong facts (here: the no-signal call box)."""
    parts = [p.strip() for p in SENTENCE.split(question.strip()) if p.strip()]
    asks = [p for p in parts if p.endswith("?")]
    # "I saw a rattlesnake. What should I do?": a generic ask carries no topic, so keep the whole question.
    if len(parts) > 1 and asks and len(content_words(asks[-1])) >= 2:
        return asks[-1]
    return question


GENERIC = set("""what whats what's where wheres where's when how who which why is are am do does did should
could would can will i i'm im me my you your it its it's the a an to of for in on at now here there this that
then so please hey meta muse ok okay""".split())


def content_words(text: str) -> list[str]:
    return [w for w in re.findall(r"[a-z']+", text.lower()) if w not in GENERIC]


def label_day(fact: str, today: date) -> str:
    """'Sunday Nov 1: ...' -> 'Tomorrow, Sunday Nov 1: ...', relative to the device's date, so the
    model never has to work out which forecast day is today."""
    for offset, word in ((0, "Today"), (1, "Tomorrow")):
        day = date.fromordinal(today.toordinal() + offset).strftime("%A %b %-d:")
        if fact.startswith(day):
            return f"{word}, {fact}"
    return fact


SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9])")


class FactIndex:
    """Finds the pack facts most relevant to a question.

    Facts are scored by their best-matching sentence, so a key sentence ("Golden Gate Bridge is SOUTH
    of Sausalito") isn't diluted by the rest of a long fact. But the whole fact is shown, so a
    sentence never loses its subject ("If bitten, call 911" stays attached to "Rattlesnake").
    The student sees only a few facts: short prompts are faster, and a small model picks the right
    line far more often with fewer wrong lines next to it. Training uses this same index, so the
    model trains on exactly what it sees at answer time.
    """

    def __init__(self, cards: list[dict], encoder, practice: list[dict] | None = None):
        """practice: Muse's practice Q&A ({q, a, card}); each one votes for the fact its answer came from."""
        self.cards, self.encoder = cards, encoder
        self.units = [
            (ci, fi, sent) for ci, c in enumerate(cards) for fi, f in enumerate(c["facts"]) for sent in SENTENCE.split(f) if sent
        ]
        texts = [f"{cards[ci]['title']}: {sent}" for ci, _, sent in self.units]
        self.vectors = encoder.encode(texts, normalize_embeddings=True)
        self.facts = sorted({(ci, fi) for ci, fi, _ in self.units})
        self.fact_pos = {f: i for i, f in enumerate(self.facts)}
        self.unit_fact = np.array([self.fact_pos[(ci, fi)] for ci, fi, _ in self.units])
        practice = [p for p in practice or [] if p.get("card") is not None]
        self.practice_q = [p["q"] for p in practice]
        if practice:
            self.practice_vecs = encoder.encode(self.practice_q, normalize_embeddings=True)
            answer_vecs = encoder.encode([p["a"] for p in practice], normalize_embeddings=True)
            self.practice_fact = np.array(
                [self._best_fact(answer_vecs[i], p["card"]) for i, p in enumerate(practice)]
            )

    def _best_fact(self, vec, card: int) -> int:
        sims = self.vectors @ vec
        own = [i for i, (ci, _, _) in enumerate(self.units) if ci == card]
        return int(self.unit_fact[max(own, key=lambda i: sims[i])])

    def _fact_scores(self, question: str) -> np.ndarray:
        q = self.encoder.encode([question], normalize_embeddings=True)[0]
        scores = np.full(len(self.facts), -1.0)
        np.maximum.at(scores, self.unit_fact, self.vectors @ q)  # a fact scores as its best sentence
        if self.practice_q:
            # The closest practice questions vote for the facts their answers came from.
            sims = self.practice_vecs @ q
            for i in np.argsort(-sims)[:5]:
                if sims[i] >= 0.75 and self.practice_q[i] != question:
                    scores[self.practice_fact[i]] += 0.1 * float(sims[i])
        return scores

    def _ranked_facts(self, scores: np.ndarray, only_card: int | None = None) -> list[tuple[int, int]]:
        ranked = [self.facts[i] for i in np.argsort(-scores)]
        return [f for f in ranked if only_card is None or f[0] == only_card]

    def top(self, question: str, k: int = 4, source: int | None = None, answer: str | None = None) -> list[tuple]:
        picked = self._ranked_facts(self._fact_scores(question))[:k]
        if source is not None and answer:
            # Training: the facts the answer was written from must be in the prompt, or we'd teach guessing.
            a = self.encoder.encode([answer], normalize_embeddings=True)[0]
            a_scores = np.full(len(self.facts), -1.0)
            np.maximum.at(a_scores, self.unit_fact, self.vectors @ a)
            needed = self._ranked_facts(a_scores, only_card=source)[:2]
            picked = needed + [f for f in picked if f not in needed][: k - len(needed)]
        return picked

    def notes(
        self, question: str, k: int = 4, source: int | None = None, answer: str | None = None, today: date | None = None
    ) -> str:
        groups: dict[int, list[str]] = {}
        picked = self.top(question, k, source, answer)
        # Forecast days in date order (today first), not relevance order: easier for a small model.
        forecast = sorted(f for f in picked if self.cards[f[0]]["kind"] == "forecast")
        picked = [forecast.pop(0) if self.cards[f[0]]["kind"] == "forecast" else f for f in picked]
        for ci, fi in picked:
            fact = self.cards[ci]["facts"][fi]
            if self.cards[ci]["kind"] == "forecast":
                fact = label_day(fact, today or date.today())
            groups.setdefault(ci, []).append(fact)
        return "\n\n".join(format_card({"title": self.cards[ci]["title"], "facts": f}) for ci, f in groups.items())


class Pack:
    def __init__(self, path: Path, encoder):
        self.path = path
        meta = json.loads((path / "pack.json").read_text())
        self.title, self.cards, self.meta = meta["title"], meta["cards"], meta
        self.pairs = json.loads((path / "pairs.json").read_text())
        self.adapter = path / "adapters"
        self.base_model = meta.get("student") or STUDENTS[DEFAULT_STUDENT]
        self.index = FactIndex(self.cards, encoder, [p for p in self.pairs if p["split"] == "train"])

    def local_examples(self) -> list[str]:
        """Router examples for on-device answers: practice questions, card titles and facts."""
        qs = [p["q"] for p in self.pairs if p["split"] == "train" and p["kind"] in ("qa", "smalltalk")]
        cards = [c["title"] for c in self.cards] + [f for c in self.cards for f in c["facts"]]
        return qs + cards

    def notes_for(self, question: str) -> str:
        return self.index.notes(focus(question))


def resolve_expect(expect: str, cards: list[dict], today: date | None = None) -> str:
    """Test expectations that depend on the pack's live data: SUNSET -> today's sunset time from the forecast."""
    if expect != "SUNSET":
        return expect
    today = (today or date.today()).isoformat()
    for c in cards:
        for day in c.get("days", []):
            m = re.search(r"sunset (\d+:\d+ [AP]M)", day.get("text", ""))
            if day["date"] == today and (day.get("sunset") or m):
                return (day.get("sunset") or m.group(1)).lower()
    return expect

