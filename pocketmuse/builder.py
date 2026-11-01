"""Build a pack: big Muse thinks ahead about your coming days and teaches the small model to answer.

Steps (while online, e.g. overnight on the charger):
  1. plan     - Muse reads what's coming up and writes ~16 note cards for the questions you're likely
                to ask, safety first for anything risky.
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
from .config import NOT_IN_PACK, PACKS_DIR, STUDENTS, format_card, student_system_prompt
from .pack import FactIndex
from .router import load_encoder
from .weather import forecast_card, geocode

PLAN_PROMPT = """Today is {today}. Here is what's coming up for the user, in their words: "{plan}"
{notes}
You are Muse, their personal assistant, thinking ahead. Predict the questions they will ask over
these days, and write the notes a tiny on-device assistant needs to answer them instantly, even with
no signal. It will only know what you write now.
Return ONE JSON object and nothing else:
{{"title": "short name, e.g. Tam hike, Sausalito kayak and Monday flight",
  "location": {{"name": "the town or area where most of the plans happen (use the area named in their notes, if any)", "lat": 0.0, "lon": 0.0}},
  "start_date": "YYYY-MM-DD",
  "days": 1-7,
  "cards": [{{"title": "...", "safety": true or false, "facts": ["...", "..."]}}]}}

Safety comes first. If anything in the plans has physical risk, the first cards (up to {n_safety})
are safety cards ("safety": true):
- One card per realistic hazard of THAT activity and place, with step-by-step what to do.
  Wildlife: cover every animal there that people are likely to meet or fear (e.g. bears, coyotes,
  mountain lions, snakes, sharks, jellyfish), saying how to respond to each one by name.
  Examples: hiking -> coyote, bear or mountain lion encounters, falls, getting lost, hypothermia, heat;
  kayaking -> capsizing and staying afloat, cold water, tides and currents, signaling from the water.
- Navigating without signal, by landmark: for each major landmark people can see there (peaks, cliffs,
  rivers, roads, coastline, bridges, buildings), which direction it lies and what it tells you
  ("the Golden Gate Bridge is south of Sausalito: paddle toward it to go south"). How to tell north,
  south, east and west from landmarks, the sun and water flow, and how to get back to the trailhead,
  road or shore.
- How to signal for help with no cell signal (whistle, mirror, satellite SOS, emergency calls).
- First aid for the most likely injuries.
- Emergency numbers and the nearest help (ranger station, hospital, harbor master).
Then practical cards ("safety": false), about {n_other}, one or more per thing in their plans: where it
is and how to get there, hours, timing (daylight, tides, traffic, when to leave), what to bring,
rules, and details they gave you (times, names, places). Use only details they gave you about their
own appointments; never invent personal details.

If the user gave notes, turn EVERY fact in them into cards, copied exactly (names, places, times,
menu items). Their notes beat your own knowledge. Facts about emergency equipment, call boxes or help
points go on safety cards. Never invent personal or local details (menus, room numbers, kit locations)
that aren't in their notes.

Each card has 3-6 short, specific facts (names, numbers, times, distances, exact steps).
Only write facts you are confident are accurate; leave out anything you are unsure of.
For life-threatening situations, the facts must say to call emergency services first.
Do not write a weather forecast; a live forecast is added separately."""

QA_PROMPT = """You are writing training data for Pocket Muse, the tiny on-device part of a personal assistant.
Muse prepared it ahead for: {title}.

Notes:
{card}

Write {n} different questions the user might ask in the moment that these notes answer, each with an answer.
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

GAP_PROMPT = """Muse prepared a tiny on-device assistant ahead for: {title}. It only knows these topics:
{titles}

Write {n} questions that these topics do NOT answer. Mix:
- things they might ask over these days that aren't covered (other services, prices, bookings)
- live information (news, scores, traffic or flight status right now)
- look-alikes about OTHER places (a trail in another state, another city's airport, weather elsewhere)
- general knowledge and tasks (how tall is Everest, a recipe, write an email)
Output one JSON object per line, exactly like: {{"q": "..."}}
Output nothing else."""

SMALL_TALK = [
    ("hi", "Hi! I'm Pocket Muse. Muse prepared me for {title}. Ask me anything."),
    ("hello there", "Hello! I'm Pocket Muse, ready for {title}."),
    ("hey", "Hey! What do you need to know?"),
    ("thanks!", "You're welcome!"),
    ("thank you so much", "Anytime. Stay safe out there!"),
    ("who are you", "I'm Pocket Muse, the on-device part of Muse. Muse thought ahead about {title} and taught me, so I answer instantly, even with no signal."),
    ("what can you help me with", "I'm ready for: {topics}."),
    ("what do you know", "Muse prepared me on: {topics}."),
    ("are you online", "I run fully on your device. Anything outside what Muse prepared, I'll pass to Muse when you're online."),
    ("bye", "Bye! Enjoy {title}."),
]


def forecast_pairs(card: dict, today: date, forecast_index: int) -> list[dict]:
    """Exact Q&A straight from the forecast data. Weather is the most common question, so its answers
    shouldn't depend on Muse's phrasing or the model's guesses."""
    pairs = []
    for day in card["days"]:
        d = date.fromisoformat(day["date"])
        offset = (d - today).days
        wd = d.strftime("%A")
        qs = [f"what's the weather on {wd}", f"{wd} forecast", f"will it rain {wd}?"]
        if offset == 0:
            qs += ["what's the weather today", "weather today?", "is it going to rain today", "how cold will it get tonight", "do I need a jacket today"]
        elif offset == 1:
            qs += ["What's the weather tomorrow?", "weather tomorrow", "will it rain tomorrow", "how warm will it be tomorrow", "tomorrow's forecast?"]
        label = {0: "Today, ", 1: "Tomorrow, "}.get(offset, "")
        answer = f"{label}{day['text']} That's the forecast as of {card['fetched']}; it can't update offline."
        pairs += [{"q": q, "a": answer, "card": forecast_index, "kind": "qa"} for q in qs]
        sunset = day.get("sunset") or (re.search(r"sunset (\d+:\d+ [AP]M)", day["text"]) or [None, None])[1]
        if sunset and offset in (0, 1):
            # The card also holds the fetch time; without exact sunset answers the model read that as sunset.
            when = "today" if offset == 0 else "tomorrow"
            sq = [f"What time is sunset {when}?", f"when does the sun set {when}", f"sunset time {when}?",
                  f"how long until dark {when}", f"when is golden hour {when}"]
            sa = f"{label}{wd} sunset is at {sunset}, from the forecast as of {card['fetched']}."
            pairs += [{"q": q, "a": sa, "card": forecast_index, "kind": "qa"} for q in sq]
    return pairs


EXPLAIN_PROMPT = """The user said what's coming up: "{plan}"
You (Muse) prepared these note cards so a tiny on-device model can answer with no signal:

{cards}

Explain your thinking to the user, plainly and briefly. Return ONE JSON object and nothing else:
{{"reasoning": "2-4 sentences: what you expect their day to need, what could go wrong, and why you put safety first",
  "why": ["one short sentence per card, in the same order: the moment they'd need this card"]}}"""


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
    return re.sub(r"[^a-z0-9]+", "-", text.lower())[:48].strip("-") or "pack"


class Builder:
    def __init__(
        self,
        plan: str,
        student: str,
        notes: str = "",
        n_safety: int = 8,
        n_other: int = 8,
        per_card: int = 20,
        n_gaps: int = 40,
        log=print,
    ):
        self.student, self.notes = student, notes
        self.plan, self.n_safety, self.n_other, self.per_card, self.n_gaps = plan, n_safety, n_other, per_card, n_gaps
        self.log = log
        self.cloud = CloudModel()
        self.today = date.today()
        self.usage = {"input_tokens": 0, "output_tokens": 0, "calls": 0}

    def _ask(self, system: str, user: str, effort: str = "low", max_tokens: int = 8000) -> str:
        ans = self.cloud.complete(system, user, effort=effort, max_tokens=max_tokens)
        self.usage["input_tokens"] += ans.input_tokens
        self.usage["output_tokens"] += ans.output_tokens
        self.usage["calls"] += 1
        return ans.text

    def plan_cards(self) -> dict:
        prompt = PLAN_PROMPT.format(
            today=self.today.strftime("%A, %B %-d, %Y"),
            plan=self.plan,
            notes=f"\nNotes the user and their school gave you (facts to use exactly):\n---\n{self.notes}\n---\n" if self.notes else "",
            n_safety=self.n_safety,
            n_other=self.n_other,
        )
        for attempt in range(3):  # Muse occasionally emits malformed JSON; a retry is cheaper than a dead demo
            # High effort uses ~7.5k tokens incl. reasoning; 8k truncated it. (JSON mode degenerated, so it's off.)
            text = self._ask(
                "You are Muse, a careful personal assistant. Output only valid JSON.", prompt, effort="high", max_tokens=20000
            )
            try:
                spec = parse_json_object(text)
                break
            except (ValueError, json.JSONDecodeError):
                self.log(f"  [yellow]Muse's plan wasn't valid JSON, retrying ({attempt + 1}/3)[/]")
        else:
            raise RuntimeError("Muse returned invalid JSON three times")
        spec["cards"] = [
            {"title": c["title"], "facts": [str(f) for f in c["facts"]], "kind": "safety" if c.get("safety") else "note"}
            for c in spec["cards"]
            if c.get("title") and c.get("facts")
        ]
        spec["cards"].sort(key=lambda c: c["kind"] != "safety")  # safety first, stable otherwise
        return spec

    def explain(self, spec: dict) -> None:
        """Muse's reasoning for the pack, shown in the app: why these cards, and when each one helps."""
        cards = "\n\n".join(f"{i + 1}. [{c['kind']}] {format_card(c)}" for i, c in enumerate(spec["cards"]))
        try:
            text = self._ask("You are Muse. Output only valid JSON.", EXPLAIN_PROMPT.format(plan=self.plan, cards=cards))
            out = parse_json_object(text)
        except Exception as e:  # reasoning is nice to have; never fail a build over it
            self.log(f"  [yellow]no reasoning ({type(e).__name__})[/]")
            return
        spec["reasoning"] = str(out.get("reasoning", ""))
        for c, why in zip(spec["cards"], out.get("why", [])):
            c["why"] = str(why)

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
        lat, lon = geocode(loc["name"], (float(loc["lat"]), float(loc["lon"])))
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
                effort="medium",
            )
            return [dict(p, card=i, kind="qa") for p in parse_lines(text, ("q", "a"))]

        def gaps() -> list[dict]:
            titles = "\n".join(f"- {c['title']}" for c in spec["cards"])
            text = self._ask(
                "You write clean training data. Follow the output format exactly.",
                GAP_PROMPT.format(title=title, titles=titles, n=self.n_gaps),
            )
            answer = f"{NOT_IN_PACK}, so I won't guess. I'll ask Muse when you're online."
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

        for i, card in enumerate(spec["cards"]):
            if card["kind"] == "forecast":
                pairs += forecast_pairs(card, self.today, i)

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
        index = FactIndex(cards, load_encoder(), [p for p in pairs if p["split"] == "train"])

        def example(p: dict) -> dict:
            # Same retrieval as at answer time, plus the facts this answer was written from.
            notes = index.notes(p["q"], source=p["card"], answer=p["a"], today=self.today)
            return {
                "messages": [
                    {"role": "system", "content": student_system_prompt(spec["title"], today, notes)},
                    {"role": "user", "content": p["q"]},
                    {"role": "assistant", "content": p["a"]},
                ]
            }

        out = PACKS_DIR / f"{slugify(spec['title'])}-{self.student}"
        (out / "dataset").mkdir(parents=True, exist_ok=True)
        for split in ("train", "valid"):
            with open(out / "dataset" / f"{split}.jsonl", "w") as f:
                for p in pairs:
                    if p["split"] == split:
                        f.write(json.dumps(example(p)) + "\n")
        pack = {
            "title": spec["title"],
            "plan": self.plan,
            "notes": self.notes,
            "built": self.today.isoformat(),
            "location": spec.get("location"),
            "reasoning": spec.get("reasoning", ""),
            "cards": cards,
            "student": STUDENTS[self.student],
            "teacher": {"provider": self.cloud.provider, "model": self.cloud.spec["model"], **self.usage},
        }
        (out / "pack.json").write_text(json.dumps(pack, indent=2))
        (out / "pairs.json").write_text(json.dumps(pairs, indent=2))
        return out
