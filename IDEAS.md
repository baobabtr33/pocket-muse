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

Filmed at UC Irvine, Newport Beach and Top of the World (Laguna Beach) with the iPhone app (`ios/`) and Ray-Ban Meta glasses. Pack: **UC Irvine day** (`uv run python pack.py --scenario uci`, notes in `data/uci.md`). Before filming: fill in the real lunch menu and class in `data/uci.md`, rebuild the day before, install with `ios/run.sh --export`, and run the self-test from the How tab (or `pm.sh selftest`).

1. **Studying, online.** At the laptop: "Explain eigenvalues and eigenvectors intuitively, with a 2x2 example." Big Muse answers from the cloud. Line: *"Muse already knows my day: class, lunch, Newport, sunset at Top of the World."*
2. **Privacy beat (say it here, while Muse is shown knowing the schedule).** *"Muse knowing my schedule is private by design. Meta built Private Processing so that personal context from AI glasses is processed in confidential virtual machines that even Meta can't see into. And once the pack is on my phone, every question I ask in the moment stays on the device: it's answered locally, never sent anywhere."*
3. **Done with class, glasses on, no signal.** "Hey Meta, where can I get lunch on campus and when is it open?" Answered on the phone in about a second, spoken in the glasses.
4. **Lunch**, filmed through the glasses.
5. **Newport Beach, no signal.** "Hey Meta, I'm getting pulled out by the water, what do I do?" → "Don't fight the current, swim parallel to shore…"
6. **Top of the World at sunset, no signal.** "Hey Meta, I'm not getting any signal. Which way is the ocean from here?" and "What time is sunset today?" (exact time from the forecast snapshot).
7. **How it's developed.** The app's How and Pack tabs: Muse Spark Open (teacher) wrote safety cards first, explained why, and wrote ~450 practice Q&A for about $0.24; Llama 3.2 1B (student) learned them as a 23 MB add-on; answers run on the phone with no network. Off-pack questions ("What's the score of the Lakers game?") are queued for big Muse instead of guessed.

**Privacy: what's true in this prototype, and what to say carefully.**

- True today: questions asked in the moment, and their answers, never leave the phone. Speech recognition, retrieval and Llama all run on-device, with or without signal. That's the honest headline.
- True today: the only cloud calls are building the pack (Muse reads the one-sentence plan and the notes file) and off-pack questions when online.
- Not true of this prototype: the pack build calls the open Muse Spark model through Baseten's API, not Meta's Private Processing. Say it as the product design ("in the product, Muse thinks ahead inside Meta's Private Processing"), not as what this demo ran on.

Meta's own wording, for reference: Private Processing is Meta's "confidential computing infrastructure for AI workloads", running in confidential virtual machines backed by hardware trusted execution environments, which "extends the trust boundary" of AI glasses into the data center. The glasses verify the environment against a public transparency ledger before sending personal context. Source: Meta Engineering, "Private Processing for Meta AI glasses" (engineering.fb.com, 2026-09-23).

### Demo risk plan

- Run the phone self-test after every rebuild; read what it *heard* as well as the answer.
- Packs vary build to build. Rebuild the day before filming (fresh forecast and sunset), then re-test.
- The scene menu (bottom left on the Muse tab) runs each stage question with one tap if voice misfires.
- Turn off "Hey Meta" in the Meta AI app so the glasses' own assistant doesn't answer too.

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
