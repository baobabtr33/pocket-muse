# Pocket Muse

**Your AI packs before you do.**

[Watch the 3-minute demo](https://youtu.be/zVn9xjb9PvE)

Pocket Muse is an AI assistant that works with no signal. You often need help most when you have none: on a trail, at the beach, on a plane, or abroad.

The night before, you tell Pocket Muse your plans. Muse Spark, Meta's large model, predicts what you will need and teaches Llama 3.2 1B on your phone to answer it. The next day you ask through your Ray-Ban Meta glasses, and the phone answers in about a second, with no network and no cost. If a question isn't covered, Pocket Muse doesn't guess. It saves the question and asks Muse when you're back online.

| 1. Plan | 2. Pack | 3. Go |
|---|---|---|
| Tell Muse about your day | Muse writes notes and teaches the small model | Ask with no signal; the phone answers |

The pack has two parts:

- **Knowledge pack (retrieval).** Hours, places, prices, the forecast and safety steps, saved as text. The 4 most relevant facts go into the prompt with each question.
- **Skill pack (LoRA adapter, 23 MB).** Teaches the small model how to use those facts: answer from the notes, keep it short, safety steps first, and say "That's not in your pack" instead of guessing.

## Results at a glance

- **On a real iPhone:** 45 of 48 spoken test questions passed across 5 days, about 1 second per answer, with no network (phone self-test, 2026-11-02). The Orange County day from the video passed 13 of 13.
- **Distillation matters:** on the same 35 questions, untrained Llama 3.2 1B passes 11 with the retrieved notes, and 13 with the whole pack pasted into its prompt. After Muse's training it passes 32. [Details](#why-distill-couldnt-the-phone-just-read-the-pack)
- **Cheap and fast to build:** about $0.26 of Muse tokens and about 6 minutes of training on a MacBook for one day's pack.

## Meta products used

| Product | Role |
|---|---|
| Muse Spark Open (via Baseten) | The teacher. Plans the day, writes the notes and about 500 practice questions, safety first. Answers off-pack questions when online. |
| Llama 3.2 1B Instruct | The student. Fine-tuned with LoRA, then runs fully on the iPhone with MLX Swift. |
| Ray-Ban Meta glasses | The interface. Used as a Bluetooth headset: hold to talk, hear the answer in the glasses. |

## The demo day: Orange County

The video follows one day: studying at the Newport Beach Central Library, class and lunch at UC Irvine, tide pools at Crystal Cove, and a bonfire at Huntington Beach. The facts come from official pages, written into [`data/oc.md`](data/oc.md). Muse turns them into the pack word for word and never invents hours or prices. Answers below are from the Mac check on 2026-11-02 (`uv run python eval.py --scenarios --only oc`, 12 of 13 passed).

| Question (no signal) | Pocket Muse's answer, on the device |
|---|---|
| "Hey Meta, what time does the library close today?" | Monday to Thursday 9am to 9pm; Friday and Saturday 9am to 6pm; Sunday 12 noon to 5pm. |
| "Hey Meta, where can I get lunch on campus and when is it open?" | The Anteatery (Mesa Court) and Brandywine (Middle Earth) serve lunch 11:30am to 2:00pm. |
| "Hey Meta, can I take a shell home from the tide pools?" | Look but don't touch: collecting shells, rocks or anything natural is prohibited by law. |
| "Hey Meta, I'm getting pulled out by the water, what do I do?" | Don't fight it. Swim parallel to shore until you're out of the pull, then swim back to shore at an angle. |
| "Hey Meta, where are the fire pits?" | There are 127 fire pits from south of First Street to Beach Blvd. |
| "What's the score of the Lakers game?" | That's not in your pack, so I won't guess. I'll ask Muse when you're online. |

Each answer took 0.3 to 0.7 seconds on a MacBook (M4 Pro). See [`script.md`](script.md) for the filming script and [`IDEAS.md`](IDEAS.md) for the pitch.

## How it's developed

Big Muse is the teacher, Llama is the student, and the student lives on your device.

1. **Anticipate.** Muse reads your plan and your notes, then writes note cards for the questions you're likely to ask. For anything risky, safety cards come first: hazards with step-by-step responses (rip currents, a coyote on the trail, a capsized kayak), finding your way by landmark, signaling for help, first aid and emergency contacts. Practical cards for each part of the day follow.
2. **Forecast.** A real forecast for the area from [Open-Meteo](https://open-meteo.com) (no key needed), saved with the time it was fetched.
3. **Teach.** Muse writes practice questions and answers for every card in parallel, 1.5x as many for safety cards. It also writes questions the pack can't answer, so the student learns to say "That's not in your pack" instead of guessing.
4. **Distill.** A LoRA fine-tune of Llama 3.2 1B Instruct (or 3B) with MLX, fused into one small model.
5. **Answer in the moment.** A semantic router decides whether a question belongs on the device or with big Muse. On-device answers get the 4 most relevant pack facts in the prompt, the same retrieval the model was trained on. Questions the pack doesn't cover go to big Muse when online, and are queued for later when not. The phone runs the same two gates: Gate 1 (intent) compares the question with the pack's own questions and with general/live ones, and only clearly anticipated questions reach Llama; Gate 2 (grounding) is the student saying "That's not in your pack" when its notes don't answer.

```
$ uv run python pack.py --demo
✓ Pack: Study, Lunch & Northfield Beach – Oct 31
   safety · Rip Current & Swimming Safety – Northfield Beach
   safety · No Signal – Emergency Call Box
   safety · Emergency Kits, AED & Lifeguard Help
   ...    · (5 safety cards first, then 4 for the day and a forecast)
✓ 304 Q&A pairs from Muse in 31s (est. $0.15)
Training Pocket Muse ━━━━━━━━━━━━━━━━━━━━━━━━━━ 200/200 steps
✓ Pack ready in 305s total (training 274s). Adapter: 23 MB on Llama 3.2 1B.

$ uv run python demo.py --offline
● offline > Hey Meta, what's the menu for lunch?
POCKET MUSE · on-device | 0.71s | $0.0000
margherita pizza, grilled chicken Caesar salad, and vegetable stir-fry with tofu (vegan) ...
● offline > What's the latest news?
QUEUED · needs big Muse | No signal, and this isn't in your pack. Queued: I'll ask Muse when you're back online.
```

## Stack

All Meta open models, except the embedder.

| Role | Model | Where it runs |
|---|---|---|
| Teacher, and big Muse for open questions | Muse Spark Open (`meta-models/muse-spark-open-1026`, 816B-A42B) via Baseten | Cloud, while online |
| Student ("Pocket Muse") | Llama 3.2 1B Instruct (default) or 3B, LoRA and fused, via MLX | On the device |
| Router and retrieval | BAAI/bge-small-en-v1.5 | On the device, CPU |
| Forecast | Open-Meteo API | Fetched while online |
| Glasses | Ray-Ban Meta, used as a Bluetooth headset (microphone and speaker, HFP); no glasses SDK | Paired with the phone |

## Measured results

**Stage pack** (study, lunch, beach; Llama 3.2 1B):

- All 8 stage questions routed correctly.
- Strict check 16/16: lunch menu, Tower 2 emergency kit, rip-current escape, call box and forecast all correct; off-topic questions refused.
- About 0.6s per on-device answer.
- Built in 305s: 31s of Muse (about $0.15) and 274s of training.

**Earlier pack** (Mount Tam hike, Sausalito kayak, flight; Llama 3.2 1B), scored by `eval.py` on 39 held-out practice questions. "Key terms" means terms from Muse's reference answer that appear in the answer. "Invented numbers" means numbers that appear nowhere in the pack.

| Setup | Key terms | Invented numbers | Says "not in pack" on off-pack questions | Latency |
|---|---|---|---|---|
| Pocket Muse (1B + pack) | 80% | 0/39 | 6/6 | 0.48s |
| Llama 3.2 1B + same notes, untuned | 14% | 0/39 | 5/6 | 0.22s |
| Llama 3.2 1B, no notes | 14% | 0/39 | 6/6 | 0.15s |

That pack cost about $0.27 of Muse tokens (tokens × list price) and about 6 minutes of training.

### Why distill? Couldn't the phone just read the pack?

The pack is small (900 to 2,800 tokens), so the obvious alternative to training is to skip it and put the pack in the prompt when the phone goes offline. That was tested with the same phone model (Llama 3.2 1B, 8-bit), same 35 spoken-test questions from `data/scenarios.json` as text, same pass rule as the phone's self-test:

| Setup | Passed |
|---|---|
| Untuned 1B, whole pack in the prompt (no training) | 13/35 |
| Untuned 1B, retrieved notes in the prompt | 11/35 |
| Pocket Muse: 1B + pack adapter + retrieved notes | **32/35** |

The untuned 1B model fails both ways. It refuses facts that are right there in its prompt ("That's not in your pack" for the soup, the library hours, the rip-current escape) and answers off-pack questions from its own memory (a pizza poem, a pad thai recipe, a stale "news" answer). Training is how Muse teaches the small model to follow the day's notes: say what the pack says, refuse what it doesn't, in one or two sentences. The facts still come from retrieval; the adapter teaches the behavior.

A bigger model (3B or 8B) follows notes in its prompt better, at more memory and latency on the phone. Untested next step: one general "pack follower" adapter trained once, so a new day needs no training at all.

Reproduce:

```bash
uv run python eval.py --scenarios                 # student (what the phone runs)
uv run python eval.py --scenarios --setup rag     # untuned base + retrieved notes
uv run python eval.py --scenarios --setup full    # untuned base + whole pack in the prompt
```

### Lean vs rich packs

Same Orange County day, two notes files (`data/oc-lean.md`, `data/oc-rich.md`; calendar, habits, Lakers scores and conference program are labeled test fixtures). Lean holds the calendar, personal patterns, repeated questions, safety and static logistics. Rich adds a game-score snapshot, background on each place and activity, and the conference program. Both trained 200 steps; `uv run python eval.py --scenarios --only oc-lean,oc-rich` (2026-11-02):

| | Lean | Rich |
|---|---|---|
| Cards (safety) / facts | 10 (3) / 38 | 24 (8) / 87 |
| Muse tokens, cost (est.) | 7.1k in + 30.5k out, $0.14 | 15.4k in + 70.3k out, $0.32 |
| Practice Q&A, training | 262, 264 s | 621, 286 s |
| Adapter | 22.6 MB | 22.6 MB |
| 8 shared day questions | 8/8 | 7/8 (rip current answer left out "swim parallel") |
| 5 rich-only questions | 5/5 refused | 5/5 answered |

The adapter's size is set by the LoRA rank, not the pack. The rich pack covers more, but at the same 200 steps it trains about 1.3 passes over its data instead of 3, and its one miss was the safety answer. Lean also answered "swim parallel" when that line wasn't in its retrieved notes, so the adapter does memorize some heavily practiced facts.

### 1B vs 3B

| | Llama 3.2 1B | Llama 3.2 3B |
|---|---|---|
| Strict stage check (safety answers right, off-topic refused) | 16/16 | 16/16 |
| Key terms on its own pack's held-out set (untuned + notes) | 80% (14%) | 63% (39%) |
| Invented numbers | 0 | 0 |
| On-device latency | ~0.5-0.6s | ~1.3-1.5s |
| Training, 200 steps on M4 Pro | ~6 min | ~14 min |
| Adapter size | 23 MB | 49 MB |

Each pack gets its own Muse-written held-out set, so key-term scores aren't directly comparable across sizes. 1B is the default: same strict-check result, and 2-3x faster to answer and to train.

## Setup

Requires an Apple Silicon Mac and [uv](https://docs.astral.sh/uv/).

```bash
uv sync
cp .env.example .env   # add BASETEN_API_KEY (or export baseten_meta in your shell)
```

## Run the stage demo

```bash
# 1. Put your real menu, places and emergency info in data/today.md
# 2. Build the stage pack from data/demo.json + data/today.md (about 5 minutes)
uv run python pack.py --demo
# 3. Run it, speaking on-device answers aloud like the glasses
uv run python demo.py --voice
```

Then, in the demo:

- `/scene 1`: online, big Muse explains a hard study question
- `/scene 2`: offline, "Hey Meta, what's the menu for lunch?"
- `/scene 3`: offline, at the beach, "Where's the closest emergency kit?"
- `/how`: how this pack was made (teacher, student, cards, cost, time), from its real build record

Rehearse all three scenes after every rebuild. Packs vary slightly from build to build, so check the answers before going on stage. Cloud answers are cached in `artifacts/cloud_cache.json`, so rehearsed questions still work if the venue Wi-Fi is flaky.

What's real and what's acted: every answer is produced live on the laptop, with scenes 2 to 4 running fully offline. The glasses themselves are acted and filmed, and `--voice` (the Mac's built-in speech) stands in for their audio.

### iPhone app with the glasses

The same pack runs on an iPhone (`ios/`): Llama 3.2 1B (8-bit) and fact retrieval via MLX Swift, on-device speech recognition, and spoken answers, all with no signal. It listens through the Ray-Ban Meta microphone over Bluetooth while you hold the button, and answers through the glasses.

```bash
uv run python export_ios.py   # quantize the latest pack's model and copy the embedder into ios/Bundle
ios/run.sh                    # build, install and launch on the connected iPhone (USB is more reliable)
```

Before the demo:

- In the Meta AI app, turn off "Hey Meta" so the glasses' own assistant doesn't answer too. In Pocket Muse, hold "Hold to talk", ask, and let go. Saying "Hey Meta" first is fine; it's ignored.
- On the iPhone, download a Premium voice: Settings > Accessibility > Read & Speak (or Spoken Content) > Voices > English > Ava (Premium). Without it, iOS uses its robotic default voice. Check it in the app's settings (Muse voice: "Ava · Premium").
- Optional: put `BASETEN_KEY = <key>` in `ios/Secrets.xcconfig` (gitignored) so off-pack questions go to big Muse when online.
- The scene menu (bottom left) runs each stage question with one tap, as a backup to voice.

### All demo commands

- Type any question
- `/offline`, `/online`: simulate losing and regaining signal (or really turn Wi-Fi off)
- `/sync`: send queued questions to Muse
- `/scene N`: run stage scene N (sets online or offline for it)
- `/how`: how the pack was made
- `/script`: run every stage question from `data/demo.json`
- `/compare <question>`: the same small model without a pack vs Pocket Muse
- `/pack`: what's in the pack, and what it cost to build
- `/stats`: session summary

`uv run python demo.py --offline` starts with no signal.

## Build your own pack

```bash
uv run python pack.py "Saturday hiking on Mount Tam, then kayaking out of Sausalito"
uv run python pack.py "<your day>" --notes my_notes.md   # facts Muse can't know: menus, rooms, kit locations
uv run python pack.py --demo --student 3b     # Llama 3.2 3B student (default 1B)
uv run python pack.py "<plan>" --iters 100    # faster, less trained
uv run python pack.py --rebuild latest        # rewrite the dataset from the saved pack (no Muse calls) and retrain
uv run python pack.py --retrain latest        # retrain on the existing dataset
```

Packs are saved to `artifacts/packs/<name>/` (gitignored): `pack.json` (notes and build stats), `pairs.json` (Q&A), `dataset/`, `adapters/`, `fused/`.

## Check a pack

```bash
uv run python eval.py               # latest pack
uv run python eval.py --pack <name>
```

This checks routing on held-out pack questions, general questions and the stage script. It then compares Pocket Muse with the untuned base model (with the same notes, and with none) on key-term accuracy, invented numbers, "not in pack" answers and latency.

## Fixing misroutes

Add phrases to `data/routes.json`. The router also uses every practice question in the active pack as a local example. When unsure, it sends the question to Muse, or queues it when offline.

## Safety note

Packs are written by a language model. They're meant to help when nothing else is available, not to replace emergency services, lifeguards, rangers or official guidance.
