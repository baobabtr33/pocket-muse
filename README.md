# Pocket Muse

**Muse thinks ahead for you.** Tell Muse what's coming up. Overnight it predicts the questions you'll ask, safety first, and teaches a tiny model on your device to answer them. Answers are instant, private and free, and they still work with no signal.

```
$ uv run python pack.py --demo
✓ Pack: Mt Tam hike, Sausalito kayak, Richmond dim sum and SFO flight (15 note cards)
   safety · Wildlife: Mountain Lion, Coyote, Bobcat on Mt Tam
   safety · Kayaking: Capsize and Cold Water Survival
   safety · Tides, Currents, Wind and Boat Traffic
   safety · Navigate Without Signal by Landmarks
   ...    · (8 safety cards first, then 7 for the plans)
✓ Forecast snapshot: Saturday Oct 31: rain, high 64°F (18°C), low 47°F (8°C) ...
✓ 467 Q&A pairs from 19 Muse calls in 85s (est. $0.270)
Training Pocket Muse ━━━━━━━━━━━━━━━━━━━━━━━━━━ 200/200 steps
✓ Pack ready in 458s total (training 373s). Adapter: 23 MB on Llama 3.2 1B.

$ uv run python demo.py --offline
● offline > There's a coyote on the trail right in front of me, what do I do?
POCKET MUSE · on-device | 0.64s | $0.0000
Coyote is common dawn/dusk: Stop, wave arms, make loud noise, throw small rocks near not at it. Do not turn your back or run ...
● offline > Which landmark should I look for to head south?
POCKET MUSE · on-device | 0.38s | $0.0000
Golden Gate Bridge is south of Sausalito, paddling away is north into Richardson Bay.
● offline > What's the latest news?
QUEUED · needs big Muse | No signal, and this isn't in your pack. Queued: I'll ask Muse when you're back online.
```

Then, during your day:

- **Anticipated** (safety, your plans, places, timing): answered on-device in about a second, for $0, signal or not.
- **Weather**: answered from the forecast snapshot, with the time it was fetched.
- **Not anticipated, or live** (news, coding): sent to big Muse when online, queued when not.

See [`IDEAS.md`](IDEAS.md) for the full idea, pitch and demo script.

## How it works

1. **Anticipate.** Muse reads what's coming up and writes note cards for the questions you're likely to ask. Safety cards always come first for anything risky: hazards with step-by-step responses (coyotes on the trail, staying afloat if your kayak flips, tides and currents), navigating by landmark, how to signal for help, first aid, emergency contacts. Then practical cards for each plan.
2. **Forecast.** A real forecast for the area from [Open-Meteo](https://open-meteo.com) (no key needed), stored with a timestamp.
3. **Teach.** Muse writes practice Q&A for every card in parallel, with 1.5x more for safety cards, plus questions the pack can't answer (so the model learns to say "That's not in your pack").
4. **Distill.** LoRA fine-tune of Llama 3.2 1B Instruct (or 3B) with MLX, then fused into one small model.
5. **Answer in the moment.** A semantic router (bge-small embeddings, cosine similarity) decides: on-device, or big Muse (queued if offline). On-device answers get the 4 most relevant pack facts in the prompt; the model was trained on exactly that retrieval, and says "That's not in your pack" when the facts don't answer the question.

## Stack (all Meta open models, except the embedder)

| Role | Model | Where |
|---|---|---|
| Teacher, and big Muse for queued questions | Muse Spark Open (`meta-models/muse-spark-open-1026`, 816B-A42B) via Baseten | cloud, while online |
| Student ("Pocket Muse") | Llama 3.2 1B Instruct (default) or 3B, LoRA + fused, via MLX | on-device |
| Router and retrieval | BAAI/bge-small-en-v1.5 | on-device, CPU |
| Forecast | Open-Meteo API | fetched while online |

## Measured results (stage pack, Llama 3.2 1B)

From `eval.py` on 39 held-out practice questions (key terms from Muse's reference answer found in the answer; invented numbers = numbers that appear nowhere in the pack):

| Setup | Key terms | Invented numbers | Says "not in pack" on off-pack questions | Latency |
|---|---|---|---|---|
| Pocket Muse (1B + pack) | 80% | 0/39 | 6/6 | 0.48s |
| Llama 3.2 1B + same notes, untuned | 14% | 0/39 | 5/6 | 0.22s |
| Llama 3.2 1B, no notes | 14% | 0/39 | 6/6 | 0.15s |

Stage script: 8/8 routes correct, all on-device answers correct. Pack cost: about $0.27 of Muse tokens (estimate: tokens × list price) and about 6 minutes of training on an M4 Pro.

### 1B vs 3B

| | Llama 3.2 1B | Llama 3.2 3B |
|---|---|---|
| Strict stage check (safety answers right, off-topic refused) | 16/16 | 16/16 |
| Key terms on its own pack's held-out set (untuned + notes) | 80% (14%) | 63% (39%) |
| Invented numbers | 0 | 0 |
| On-device latency | ~0.5-0.6s | ~1.3-1.5s |
| Training, 200 steps on M4 Pro | ~6 min | ~14 min |
| Adapter size | 23 MB | 49 MB |

Each pack gets its own Muse-written held-out set, so key-term scores aren't directly comparable across sizes. 1B is the default: same strict-check result, 2-3x faster to answer and train.

## Setup

Requires an Apple Silicon Mac and [uv](https://docs.astral.sh/uv/).

```bash
uv sync
cp .env.example .env   # add BASETEN_API_KEY (or export baseten_meta in your shell)
```

## Build a pack

```bash
uv run python pack.py "Saturday hiking on Mount Tam, then kayaking out of Sausalito"
uv run python pack.py --demo                  # the stage plan in data/demo.json
uv run python pack.py --demo --student 3b     # Llama 3.2 3B student (default 1B)
uv run python pack.py "<plan>" --iters 100    # faster, less trained
uv run python pack.py --rebuild latest        # rewrite the dataset from the saved pack (no Muse calls) and retrain
uv run python pack.py --retrain latest        # retrain on the existing dataset
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
