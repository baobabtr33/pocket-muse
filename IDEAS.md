# Pocket Muse: Muse thinks ahead for you

## One-liner

Muse knows what's coming up for you. Overnight it predicts the questions you'll ask, starting with how to stay safe, and teaches a tiny model on your device to answer them. Answers are instant, private and free, and they still work with no signal.

## The problem

Personal AI assistants are reactive and live in a data center. You ask, they think from scratch, every time:

- **No signal, no assistant.** On a trail, on the water, in a basement or a plane, "Hey Meta, there's a coyote, what do I do?" gets nothing.
- **Slow and costly for predictable questions.** Most of tomorrow's questions are predictable from tomorrow's plans: when to leave for the airport, what the tide is doing, where the restaurant is. A data center round trip for each one is waste.
- **A generic offline model doesn't fix it.** A small model that knows a bit of everything knows nothing reliable about your trail, your tide or your Monday, and it hallucinates.

## The idea: Muse thinks ahead

You tell Muse what's coming up, the way you'd tell a friend: "Saturday morning I'm hiking on Mount Tam, then kayaking out of Sausalito. Sunday dim sum with my parents at 11. Monday my flight leaves SFO at 6pm." (In the product this would come from your calendar. The MVP takes a sentence.)

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

1. **Tell Muse about the weekend.** `uv run python pack.py --demo`. Muse anticipates the cards (safety ones tagged red), the forecast arrives, the Q&A counter climbs and the training bar fills. Show the measured cost and time. If time is tight, narrate over it, or switch to a pack built earlier.
2. **Lose signal.** Turn Wi-Fi off (or `/offline`). "You're on the trail."
3. "There's a coyote on the trail right in front of me, what do I do?" Answered on-device, with steps.
4. "Which landmark should I look for to head south?" Answered by landmark.
5. "My kayak flipped, how do I stay afloat?" and "What should I know about tides and currents out there?"
6. "What's the weather tomorrow?" Answered from the snapshot, with its timestamp.
7. "When should I leave for the airport on Monday?" Muse anticipated this one too.
8. "What's the latest news?" Queued: Muse couldn't know this ahead of time.
9. `/compare` on the coyote question: the same small model without a pack vs Pocket Muse.
10. **Get signal back.** `/online`, then `/sync`. Muse answers the queued questions. `/stats` shows the session.

### Demo risk plan

- Live building takes about 7–8 minutes with Llama 3.2 1B (about 1.5 minutes of Muse, about 6 minutes of training). Start it, narrate over the progress bars, and switch to a finished pack built earlier. `--iters 100` halves training if needed.
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
