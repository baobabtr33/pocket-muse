# Pocket Muse

**Pack an AI for the trip.** Cloud AI disappears when the signal does. Before you go offline, big Muse (Meta's Muse Spark, in the cloud) teaches a tiny on-device model exactly what you'll need, starting with how to stay safe. Then it runs on your laptop with Wi-Fi off.

```
$ uv run python pack.py "Hiking in Yosemite Valley this weekend, no cell signal on the trails"
✓ Pack: Yosemite Valley hiking weekend (16 note cards)
   safety · Coyote & Mountain Lion Encounters
   safety · Signaling for Help Without Cell Service
   ...
✓ Forecast snapshot: Saturday Oct 31: heavy rain, high 54°F ...
✓ 400+ Q&A pairs from Muse
Training Pocket Muse ━━━━━━━━━━━━━━━━━━━━ 120/120 steps
✓ Pack ready
```

Then, offline:

- **In the pack** (safety, places, rules, gear): answered on-device in about a second, for $0.
- **Weather**: answered from the forecast snapshot, with the time it was fetched.
- **Not in the pack, or live** (news, coding): queued, and sent to Muse when you're back online.

See [`IDEAS.md`](IDEAS.md) for the full idea, pitch and demo script.

## How it works

1. **Plan.** Muse turns your plan into note cards from its own knowledge. Safety cards always come first: hazards for this activity with step-by-step responses, navigating by landmark, how to signal for help, first aid, emergency contacts.
2. **Forecast.** A real forecast for the location from [Open-Meteo](https://open-meteo.com) (no key needed), stored with a timestamp.
3. **Teach.** Muse writes practice Q&A for every card in parallel, with 1.5x more for safety cards, plus questions the pack can't answer (so the model learns to say "That's not in your pack").
4. **Distill.** LoRA fine-tune of Qwen2.5-0.5B-Instruct with MLX, then fused into one small model.
5. **Answer offline.** A semantic router (bge-small embeddings, cosine similarity) decides: on-device, or queue for Muse. On-device answers get the most relevant pack notes in the prompt.

## Setup

Requires an Apple Silicon Mac and [uv](https://docs.astral.sh/uv/).

```bash
uv sync
cp .env.example .env   # add BASETEN_API_KEY (or export baseten_meta in your shell)
```

## Build a pack

```bash
uv run python pack.py "Kayaking around Point Reyes on Saturday"
uv run python pack.py "<plan>" --iters 80     # faster, less trained
uv run python pack.py --retrain latest        # retrain an existing pack's dataset
```

Packs go to `artifacts/packs/<name>/` (gitignored): `pack.json` (notes and build stats), `pairs.json` (Q&A), `dataset/`, `adapters/`, `fused/`.

## Check a pack

```bash
uv run python eval.py               # latest pack
uv run python eval.py --pack <name>
```

This checks routing on held-out pack questions, general questions and the stage script. It then compares Pocket Muse with the untuned base model (with the same notes, and with none) on key-term accuracy, invented numbers, "not in pack" answers and latency.

## Run the demo

```bash
uv run python demo.py              # latest pack
uv run python demo.py --offline    # start with no signal
```

Inside the demo:

- type any question
- `/offline`, `/online`: simulate losing and regaining signal (or really turn Wi-Fi off)
- `/sync`: send queued questions to Muse
- `/script`: run the stage questions from `data/demo.json`
- `/compare <question>`: the same small model without a pack vs Pocket Muse
- `/pack`: what's in the pack, and what it cost to build
- `/stats`: session summary

Rehearse `/sync` once online before the event. Cloud answers are cached in `artifacts/cloud_cache.json`, so rehearsed questions still work if the venue Wi-Fi is flaky.

## Fixing misroutes

Add phrases to `data/routes.json`. The router also uses every practice question in the active pack as a local example. When unsure, it queues for Muse.

## Safety note

Packs are written by a language model. They're meant to help when nothing else is available, not to replace emergency services, rangers or official guidance.
