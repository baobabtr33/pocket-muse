# Pocket Muse: Muse thinks ahead for you

## One-liner

Muse knows what's coming up for you. Overnight it predicts the questions you'll ask, starting with how to stay safe, and teaches a tiny model on your device to answer them. Answers are instant, private and free, and they still work with no signal.

## The problem

Personal AI assistants are reactive and live in a data center. You ask, they think from scratch, every time:

- **No signal, no assistant.** On a trail, on the water, in a basement or a plane, "Hey Meta, there's a coyote, what do I do?" gets nothing.
- **Slow and costly for predictable questions.** Most of tomorrow's questions are predictable from tomorrow's plans: when to leave for the airport, what the tide is doing, where the restaurant is. A data center round trip for each one is waste.
- **A generic offline model doesn't fix it.** A small model that knows a bit of everything knows nothing reliable about your trail, your tide or your Monday, and it hallucinates.

## The idea: Muse thinks ahead

You tell Muse what's coming up, the way you'd tell a friend, plus anything only you or your school know (today's menu, where the beach emergency kit is): "Saturday morning I'm hiking on Mount Tam, then kayaking out of Sausalito. Sunday dim sum with my parents at 11. Monday my flight leaves SFO at 6pm." (In the product this would come from your calendar. The MVP takes a sentence.)

While you're online (overnight, on the charger):

1. **Anticipate.** Big Muse (Muse Spark Open, Meta's open 816B model, in the cloud) predicts what you'll ask and writes note cards. **Safety always comes first**: for anything risky, every realistic hazard with step-by-step responses. Hiking gets coyote, mountain lion and rattlesnake encounters, falls, getting lost. Kayaking gets capsizing and staying afloat, cold water, tides and currents, signaling from the water. Other safety cards cover navigating by landmark with no signal ("the Golden Gate Bridge is south of Sausalito"), how to signal for help, first aid and emergency contacts. Then practical cards for each plan: where, when to leave, hours, what to bring.
2. **Forecast snapshot.** A real forecast for the area is fetched and stored with a timestamp.
3. **Teach.** Muse writes hundreds of practice Q&A pairs, in parallel, with the most practice on safety: urgent and panicked phrasings, steps in order, emergency services first. It also writes questions the pack can't answer, so the small model learns to say "That's not in your pack."
4. **Distill.** A LoRA adapter is trained on Llama 3.2 1B (or 3B) on the laptop (MLX), then fused into a small model that runs on-device. Meta's open models end to end: open Muse teaches, Llama answers.

During your day, every question goes through a router on the device:

- **Anticipated** (safety, your plans, the forecast): Pocket Muse answers on-device in about a second, for $0, signal or not.
- **Time-sensitive** (weather): answered from the snapshot, with "forecast as of Friday 6pm."
- **Not anticipated, or live** (news, coding, anything else): sent to big Muse if you're online, or queued until you are.

## Why this is different

| | Cloud assistant | Generic offline model | Pocket Muse |
|---|---|---|---|
| Thinks ahead about your days | no | no | yes |
| Works with no signal | no | yes | yes, for what Muse anticipated |
| Knows your trail, tide, flight | yes, if online | no | yes |
| Safety protocols ready | if online | unreliable | first, by design |
| Says what it doesn't know | n/a | rarely | yes, and queues it |
| Cost per question | tokens every time | $0 | $0 on-device; one-time cost to prepare |

The architecture is the product: the big model thinks ahead while connected, a small specialist answers in the moment, and a router knows when to wait for the big one.

## Design choices

- **Safety first.** Safety cards are planned first, get 1.5x the practice questions, and must give steps in order with "call emergency services" first for life-threatening cases. A wrong answer here is the worst failure, so it gets the most training.
- **Facts in context, behavior in weights.** Each answer is generated with the retrieved notes in the prompt. Training teaches the model to use them, stay brief, timestamp the forecast and say when something isn't in the pack. Facts don't need memorizing, so training is a few minutes.
- **Fail toward "I don't know".** The router only answers on-device when the question is clearly close to what Muse anticipated. Otherwise it asks Muse or queues, rather than guessing.
- **Measure, don't claim.** Preparation cost (Muse tokens × list price), training time, latency and eval scores all come from real runs.

## MVP (what is built)

- `pack.py "<what's coming up>"`: anticipate, forecast, teach, train and fuse, with live progress.
- `demo.py`: chat with the pack. `/offline` and `/online` simulate signal loss (or really turn Wi-Fi off), unanswered questions are queued, and `/sync` sends them later.
- `eval.py`: routing checks, plus Pocket Muse vs the untuned base model (with and without notes). It measures key-term accuracy, invented numbers and "not in pack" behavior.

## Out of scope for the MVP

- Calendar, email or location integration. Plans are typed as one sentence.
- Real glasses or phone app. "Hey Meta" on glasses is the concept, shown on a laptop.
- Accounts, servers, multi-user anything. Maps and GPS.
- Live tide tables (Muse writes general tide and current guidance; real predictions are future work).
- Guaranteeing safety advice. Packs come from a model and say so. They don't replace emergency services or official guidance.

## The demo

Setup before going on stage: edit `data/today.md` with the real menu, places and emergency info, build the pack (`uv run python pack.py --demo`, about 5 minutes), and run `uv run python demo.py --voice`. Scenes 1-5 are filmed or acted; the terminal commands are what runs live.

1. **Studying, online.** The user, wearing glasses, studies at the computer and asks Muse a hard question: `/scene 1` ("Explain eigenvalues and eigenvectors intuitively, with a 2x2 example"). Big Muse answers from the cloud. Meanwhile Muse already knows the day: library, lunch, beach.
2. **Done with work, glasses on.** "Oh, I'm not getting any signal."
3. **"Hey Meta, what's the menu for lunch?"** `/scene 2`. The router keeps it on-device; Llama answers from the pack in under a second, for $0, with no network: "margherita pizza, grilled chicken Caesar salad, and vegetable stir-fry with tofu (vegan)", spoken aloud with `--voice`.
4. **Go to lunch**, filmed through the glasses.
5. **After school, at the beach, no signal.** "Hey Meta, I'm not getting any signal. Do you have any idea where the closest emergency kit is?" `/scene 3`: "Emergency kit with AED inside Lifeguard Tower 2 at bottom of Shore Path stairs..."
6. **How it's developed.** `/how` shows this pack's real build record:
   - **Teacher:** Muse Spark Open (Meta's open 816B model) read the day plus the user's notes and wrote safety cards first (rip currents, the emergency call box, kit and AED locations, landmark navigation), then cards for the day, plus a live forecast snapshot. It wrote about 300 practice Q&A pairs in about 30 seconds, for about $0.15.
   - **Student:** Llama 3.2 1B, LoRA fine-tuned on those pairs on the laptop with MLX in about 5 minutes, then fused: a 23 MB adapter.
   - **In the moment:** on-device inference only. The knowledge was learned beforehand, so no network is needed. Anything outside the pack goes to big Muse when online, or is queued.
7. Optional: ask something off-pack offline ("What's the latest news?"), show it queued, then `/online` and `/sync`.

### Demo risk plan

- Building takes about 5 minutes with Llama 3.2 1B (about 30 seconds of Muse, about 4.5 minutes of training). Build it before going on stage; if you show a live build, keep the finished pack ready to switch to.
- Run `uv run python eval.py` on the stage pack, and rehearse the exact script questions.
- Rehearsed cloud answers are cached, so `/sync` still works if venue Wi-Fi is flaky.

## Pitch

> "Every assistant today waits for you to ask, then thinks from scratch in a data center. Lose signal on a trail or on the water, and it's gone exactly when you need it.
>
> Muse can think ahead. It knows your weekend: a hike on Mount Tam, kayaking out of Sausalito, a Monday flight. Overnight, it predicts what you'll ask, starting with how to stay safe: the coyote on the trail, staying afloat if you flip, which landmark points south. Then it teaches a tiny model on your device. In a few minutes and for about a quarter, every one of those answers is instant, private and works with zero bars. And it tells you honestly what it doesn't know, then asks Muse when you're back."

## Future work (pitch lines, not built)

- Calendar and location as the input, refreshed every night automatically.
- Packs on glasses and phones (hands-free: "Hey Meta, what do I do?").
- Live data snapshots beyond weather: tide tables, transit schedules, flight status.
- A learning loop: questions you actually asked shape what Muse anticipates next time.
- Phone sensors as offline signals (a barometer drop suggests a storm is coming).
