# Pocket Muse: pack an AI for the trip

## One-liner

Cloud AI disappears when the signal does. Before you go offline, big Muse teaches a tiny on-device model exactly what you'll need, starting with how to stay safe. Then it works with no internet.

## The problem

Personal AI assistants live in data centers. The moments you most need help are often the moments you have no signal: on a trail, on the water, on a long flight, after a disaster. "Hey Meta, what do I do, there's a coyote" does nothing with zero bars.

A general offline model doesn't fix this. A small model that knows a bit of everything knows nothing reliable about your trail, your tide or your trip, and it hallucinates.

## The idea: just-in-time distillation

You tell Muse your plan: "Hiking in Yosemite Valley this weekend, no cell signal on the trails." While you're still online:

1. **Plan.** Big Muse (Muse Spark, in the cloud) writes the pack's note cards from its own knowledge. **Safety cards always come first**: every realistic hazard for this activity with step-by-step responses (hiking: coyote, bear or mountain lion encounters, falls, getting lost, hypothermia; kayaking: capsizing and staying afloat, cold water, tides and currents, signaling from the water), navigating by landmark with no signal (which way is Half Dome, how to find south, how to get back to the trailhead), how to signal for help, first aid, and emergency contacts. Then practical cards: places, rules, timing, gear, food and water.
2. **Forecast snapshot.** A real forecast is fetched for the location and stored with a timestamp.
3. **Teach.** Muse writes hundreds of practice Q&A pairs from those cards, in parallel, with the most practice on safety: urgent and panicked phrasings, steps in order, emergency services first. It also writes questions the pack can't answer, so the small model learns to say "That's not in your pack."
4. **Distill.** A LoRA adapter is trained on a 0.5B model on the laptop (MLX), then fused into a small model that runs on-device.

Offline, every question goes through a router:

- **In the pack** (safety, places, the forecast): Pocket Muse answers on-device from the pack notes, for $0 and in about a second.
- **Time-sensitive** (weather): answered from the snapshot, with "forecast as of Friday 6pm, it can't update offline."
- **Not in the pack, or live** (news, coding, anything else): queued. "I'll ask Muse when you're back online." `/sync` sends them when signal returns.

## Why this is different

| | Cloud assistant | Generic offline model | Pocket Muse |
|---|---|---|---|
| Works with no signal | no | yes | yes |
| Knows your trip, trail, tide | yes | no | yes |
| Safety protocols drilled in | if online | unreliable | first, by design |
| Says what it doesn't know | n/a | rarely | yes, and queues it |
| Cost per question | tokens every time | $0 | $0 offline, one-time pack cost |

The architecture is the product: big model as teacher while connected, small specialist on the edge, and a router that knows when to wait for the big one.

## Design choices

- **Safety first.** Safety cards are planned first, get 1.5x the practice questions, and must give steps in order with "call emergency services" first for life-threatening cases. A wrong answer here is the worst failure, so it gets the most training.
- **Facts in context, behavior in weights.** Each answer is generated with the retrieved pack notes in the prompt. Training teaches the model to use those notes, stay brief, timestamp the forecast and say when something isn't in the pack. Facts don't have to be memorized, so training stays short.
- **Fail toward "I don't know".** The router only answers locally when the question is clearly close to the pack. Otherwise it queues, rather than guessing.
- **Measure, don't claim.** Pack cost (Muse tokens × list price), training time, latency and eval scores all come from real runs.

## MVP (what is built)

- `pack.py "<plan>"`: plan, forecast, teach, train, fuse, with live progress.
- `demo.py`: chat with the pack. `/offline` and `/online` simulate signal loss (or really turn Wi-Fi off), questions get queued, and `/sync` sends them later.
- `eval.py`: routing checks, plus Pocket Muse vs the untuned base model (with and without notes): key-term accuracy, invented numbers, and "not in pack" behavior.

## Out of scope for the MVP

- Real glasses or phone app. "Hey Meta" on glasses is the concept, shown on a laptop.
- Accounts, sync servers, multi-user anything.
- Maps, GPS, offline navigation.
- Guaranteeing safety advice. Packs come from a model and say so. They are not a replacement for emergency services or official guidance.
- Benchmark-grade evaluation. A held-out set with honest numbers is enough.

## The demo

1. **Pack it live, online.** `uv run python pack.py "Hiking in Yosemite Valley this weekend, no cell signal on the trails"`. Muse plans the cards (safety ones tagged red), the forecast arrives, the Q&A counter climbs, and the training bar fills. Show the measured cost and time. If time is tight, start the build and narrate over it, or switch to a pack built earlier.
2. **Lose signal.** Turn Wi-Fi off (or `/offline`).
3. "There's a coyote on the trail right in front of me, what do I do?" Answered on-device, with steps.
4. "Which landmark should I look for to head south?" Answered on-device, by landmark.
5. "How do I signal for help with no cell signal?" Answered on-device.
6. "What's the weather tomorrow?" Answered from the forecast snapshot, with its timestamp.
7. "What's the latest news?" Queued.
8. `/compare` on the coyote question: the same small model without a pack vs Pocket Muse.
9. **Get signal back.** `/online`, then `/sync`. Muse answers the queued questions. `/stats` shows the session.

### Demo risk plan

- Live training takes a few minutes. Always have a finished pack ready to switch to.
- Run `uv run python eval.py` on the stage pack, and rehearse the exact script questions.
- Rehearsed cloud answers are cached, so `/sync` still works if venue Wi-Fi is flaky.

## Pitch

> "Every personal AI today has the same weak spot: it lives in a data center. Lose signal on a trail, on the water, or after a storm, and your assistant is gone exactly when you need it.
>
> Pocket Muse fixes that. Before you go, big Muse teaches a tiny model that runs on your device exactly what you'll need, starting with how to stay safe: what to do about the coyote on the trail, how to signal for help. In a few minutes and for a few cents, you have a specialist in your pocket that works with zero bars and tells you honestly what it doesn't know. When you're back online, Muse picks up the rest."

## Future work (pitch lines, not built)

- Packs on glasses and phones (hands-free: "Hey Meta, what do I do?").
- A self-improving loop: questions asked offline feed the next pack.
- Phone sensors as offline signals (a barometer drop suggests a storm is coming).
- Shared packs: a park ranger or harbor master publishes an official one.
