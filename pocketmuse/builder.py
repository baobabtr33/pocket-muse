"""Build a pack: big Muse writes notes and practice Q&A for a trip, then the student trains on them.

Steps (all while online):
  1. plan     - Muse turns the user's plan into ~16 note cards from its own knowledge.
  2. forecast - real forecast snapshot from Open-Meteo, as one more card.
  3. teach    - Muse writes practice Q&A for every card, in parallel.
  4. dataset  - Q&A become chat examples with the source card in the prompt (facts in context,
                behavior in weights), plus "not in your pack" and small-talk examples.
Training is in train.py.
"""

import json
import random
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date

from .cloud import CloudModel
from .config import NOT_IN_PACK, PACKS_DIR, format_card, student_system_prompt
from .weather import forecast_card, geocode

PLAN_PROMPT = """Today is {today}. The user is about to lose internet access. Their plan: "{plan}"

You are packing a tiny offline assistant for them. It will only know what you write now.
Return ONE JSON object and nothing else:
{{"title": "short name for the pack, e.g. Yosemite Valley hiking weekend",
  "location": {{"name": "main place", "lat": 0.0, "lon": 0.0}} or null if there is no single place,
  "start_date": "YYYY-MM-DD",
  "days": 1-7,
  "cards": [{{"title": "...", "safety": true or false, "facts": ["...", "..."]}}]}}

Safety comes first. The first {n_safety} cards are safety cards ("safety": true):
- One card per realistic hazard of THIS activity and place, with step-by-step what to do.
  Wildlife: cover every animal there that people are likely to meet or fear (e.g. bears, coyotes,
  mountain lions, snakes, sharks, jellyfish), saying how to respond to each one by name.
  Examples: hiking -> bear, coyote or mountain lion encounters, falls, getting lost, hypothermia, heat;
  kayaking -> capsizing and staying afloat, cold water, tides and currents, signaling from the water.
- Navigating without signal, by landmark: for each major landmark people can see there (peaks, cliffs,
  rivers, roads, coastline, buildings), which direction it lies and what it tells you ("Half Dome is at
  the east end of the Valley: walk toward it to go east"). How to tell north, south, east and west
  from landmarks, the sun and water flow, and how to get back to the trailhead, road or shore.
- How to signal for help with no cell signal (whistle, mirror, satellite SOS, emergency calls).
- First aid for the most likely injuries.
- Emergency numbers and the nearest help (ranger station, hospital, harbor master).
Then {n_other} practical cards ("safety": false): key places and getting around, hours and rules,
timing (daylight, tides, schedules), gear, food and water, and knowledge specific to their plan.

Each card has 3-6 short, specific facts (names, numbers, times, distances, exact steps).
Only write facts you are confident are accurate; leave out anything you are unsure of.
For life-threatening situations, the facts must say to call emergency services first.
Do not write a weather forecast; a live forecast is added separately."""

QA_PROMPT = """You are writing training data for Pocket Muse, a tiny offline assistant packed for: {title}.

Notes:
{card}

Write {n} different questions the user might ask while offline that these notes answer, each with an answer.
Rules:
- Vary the wording a lot: short and long, casual, typos, no punctuation, different synonyms.
- Every answer is 1-2 short sentences and uses ONLY the notes. Include the specific names, numbers and times.
- Never add facts that are not in the notes.{extra}
- Output one JSON object per line, exactly like: {{"q": "...", "a": "..."}}
- Output nothing else."""

SAFETY_EXTRA = (
    "\n- These are safety notes. Include urgent, panicked and short questions (\"coyote right in front of me what do i do\")."
    "\n- Answers give the steps in order, exactly as the notes say. If the notes say to call emergency services, say so first."
)

FORECAST_EXTRA = (
    "\n- These notes are a forecast snapshot. Every answer must say it is the forecast as of {fetched} "
    "and that it can't update offline. Questions may say today, tomorrow, or a weekday; today is {today}."
)

GAP_PROMPT = """A tiny offline assistant was packed for: {title}. It only knows these topics:
{titles}

Write {n} questions the user might plausibly ask on this trip that these topics do NOT answer
(different places, services, facts or live information not covered).
Output one JSON object per line, exactly like: {{"q": "..."}}
Output nothing else."""

SMALL_TALK = [
    ("hi", "Hi! I'm Pocket Muse, packed for {title}. Ask me anything from your pack."),
    ("hello there", "Hello! I'm Pocket Muse, your offline assistant for {title}."),
    ("hey", "Hey! What do you need to know about {title}?"),
    ("thanks!", "You're welcome! Have a great trip."),
    ("thank you so much", "Anytime. Stay safe out there!"),
    ("who are you", "I'm Pocket Muse, a small offline assistant Muse packed for {title}. I work without internet."),
    ("what can you help me with", "I can help with: {topics}."),
    ("what do you know", "My pack covers: {topics}."),
    ("are you online", "No, I run fully on your device. I'll pass anything outside my pack to Muse when you're back online."),
    ("bye", "Bye! Enjoy {title}."),
]


def parse_json_object(text: str) -> dict:
    return json.loads(text[text.index("{") : text.rindex("}") + 1])


def parse_lines(text: str, keys: tuple[str, ...]) -> list[dict]:
    out = []
    for line in text.splitlines():
        m = re.search(r"\{.*\}", line)
        if not m:
            continue
        try:
            obj = json.loads(m.group(0))
        except json.JSONDecodeError:
            continue
        if all(str(obj.get(k, "")).strip() for k in keys):
            out.append({k: str(obj[k]).strip() for k in keys})
    return out


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:48] or "pack"


class Builder:
    def __init__(self, plan: str, n_safety: int = 8, n_other: int = 8, per_card: int = 20, n_gaps: int = 30, log=print):
        self.plan, self.n_safety, self.n_other, self.per_card, self.n_gaps = plan, n_safety, n_other, per_card, n_gaps
        self.log = log
        self.cloud = CloudModel()
        self.today = date.today()
        self.usage = {"input_tokens": 0, "output_tokens": 0, "calls": 0}

    def _ask(self, system: str, user: str, effort: str = "low") -> str:
        ans = self.cloud.complete(system, user, effort=effort)
        self.usage["input_tokens"] += ans.input_tokens
        self.usage["output_tokens"] += ans.output_tokens
        self.usage["calls"] += 1
        return ans.text

    def plan_cards(self) -> dict:
        text = self._ask(
            "You are Muse, a careful personal assistant. Output only valid JSON.",
            PLAN_PROMPT.format(
                today=self.today.strftime("%A, %B %-d, %Y"), plan=self.plan, n_safety=self.n_safety, n_other=self.n_other
            ),
            effort="medium",
        )
        spec = parse_json_object(text)
        spec["cards"] = [
            {"title": c["title"], "facts": [str(f) for f in c["facts"]], "kind": "safety" if c.get("safety") else "note"}
            for c in spec["cards"]
            if c.get("title") and c.get("facts")
        ]
        spec["cards"].sort(key=lambda c: c["kind"] != "safety")  # safety first, stable otherwise
        return spec

    def add_forecast(self, spec: dict) -> dict | None:
        loc = spec.get("location")
        if not loc or loc.get("lat") is None:
            return None
        try:
            start = date.fromisoformat(spec.get("start_date") or "")
        except ValueError:
            start = self.today
        # Open-Meteo only forecasts ~16 days ahead; the user also needs today while packing.
        start = min(max(start, self.today), date.fromordinal(self.today.toordinal() + 9))
        days = int(spec.get("days") or 3) + (start - self.today).days
        lat, lon = geocode(loc["name"]) or (float(loc["lat"]), float(loc["lon"]))
        card = forecast_card(loc["name"], lat, lon, self.today, days)
        spec["cards"].append(card)
        return card

    def teach(self, spec: dict, on_card=None) -> list[dict]:
        title = spec["title"]
        today = self.today.strftime("%A, %B %-d")

        def qa_for(i: int) -> list[dict]:
            card = spec["cards"][i]
            n, extra = self.per_card, ""
            if card["kind"] == "forecast":
                extra = FORECAST_EXTRA.format(fetched=card["fetched"], today=today)
            elif card["kind"] == "safety":  # the questions that matter most get the most practice
                n, extra = round(self.per_card * 1.5), SAFETY_EXTRA
            text = self._ask(
                "You write clean training data. Follow the output format exactly.",
                QA_PROMPT.format(title=title, card=format_card(card), n=n, extra=extra),
            )
            return [dict(p, card=i, kind="qa") for p in parse_lines(text, ("q", "a"))]

        def gaps() -> list[dict]:
            titles = "\n".join(f"- {c['title']}" for c in spec["cards"])
            text = self._ask(
                "You write clean training data. Follow the output format exactly.",
                GAP_PROMPT.format(title=title, titles=titles, n=self.n_gaps),
            )
            answer = f"{NOT_IN_PACK}, so I can't answer that reliably offline. I'll ask Muse when you're back online."
            return [{"q": p["q"], "a": answer, "card": None, "kind": "gap"} for p in parse_lines(text, ("q",))]

        pairs = []
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = {pool.submit(qa_for, i): spec["cards"][i]["title"] for i in range(len(spec["cards"]))}
            futures[pool.submit(gaps)] = "Questions outside the pack"
            for fut in as_completed(futures):
                try:
                    got = fut.result()
                except Exception as e:  # one failed card shouldn't sink the pack
                    got = []
                    self.log(f"  [yellow]failed: {futures[fut]} ({type(e).__name__})[/]")
                pairs.extend(got)
                if on_card:
                    on_card(futures[fut], len(got))

        topics = ", ".join(c["title"].lower() for c in spec["cards"])
        for q, a in SMALL_TALK:
            pairs.append({"q": q, "a": a.format(title=title, topics=topics), "card": None, "kind": "smalltalk"})

        seen, unique = set(), []
        for p in pairs:
            key = p["q"].lower().strip(" ?!.")
            if key not in seen:
                seen.add(key)
                unique.append(p)
        return unique

    def write(self, spec: dict, pairs: list[dict]) -> "Path":  # noqa: F821
        rng = random.Random(0)
        rng.shuffle(pairs)
        # Hold out some note questions for eval; small talk always trains.
        qa_idx = [i for i, p in enumerate(pairs) if p["kind"] != "smalltalk"]
        n_valid = max(20, len(qa_idx) // 10)
        valid_idx = set(qa_idx[:n_valid])
        for i, p in enumerate(pairs):
            p["split"] = "valid" if i in valid_idx else "train"

        cards = spec["cards"]
        today = self.today.strftime("%A, %B %-d")

        def example(p: dict) -> dict:
            # Source card plus one distractor, in random order, mirrors retrieval at inference.
            others = [i for i in range(len(cards)) if i != p["card"]]
            chosen = ([p["card"]] if p["card"] is not None else [rng.choice(others)]) + [rng.choice(others)]
            rng.shuffle(chosen)
            notes = "\n\n".join(format_card(cards[i]) for i in chosen)
            return {
                "messages": [
                    {"role": "system", "content": student_system_prompt(spec["title"], today, notes)},
                    {"role": "user", "content": p["q"]},
                    {"role": "assistant", "content": p["a"]},
                ]
            }

        out = PACKS_DIR / slugify(spec["title"])
        (out / "dataset").mkdir(parents=True, exist_ok=True)
        for split in ("train", "valid"):
            with open(out / "dataset" / f"{split}.jsonl", "w") as f:
                for p in pairs:
                    if p["split"] == split:
                        f.write(json.dumps(example(p)) + "\n")
        pack = {
            "title": spec["title"],
            "plan": self.plan,
            "built": self.today.isoformat(),
            "location": spec.get("location"),
            "cards": cards,
            "teacher": {"provider": self.cloud.provider, "model": self.cloud.spec["model"], **self.usage},
        }
        (out / "pack.json").write_text(json.dumps(pack, indent=2))
        (out / "pairs.json").write_text(json.dumps(pairs, indent=2))
        return out
