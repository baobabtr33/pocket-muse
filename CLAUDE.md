# CLAUDE.md

Guidance for Claude when working in this repository.

## Project

Pocket Muse: Muse thinks ahead. From what's coming up in the user's days, a big cloud model (Muse Spark) predicts the questions they'll ask and teaches a tiny on-device model a "pack" (safety first, then practical notes for each plan, plus a forecast snapshot). In the moment, a router answers anticipated questions on-device (instant, free, works with no signal) and sends or queues the rest for big Muse. Full idea, pitch and demo script are in `IDEAS.md`. Read it before making product decisions.

## The goal is the demo

Everything in this repo exists to produce a working MVP and a successful live demo. When deciding what to do, ask: "Does this make the demo work, or make it more convincing?" If not, skip it or note it as future work.

The demo must show, end to end:
1. A pack built from a plain-language description of the coming days (Muse anticipates, forecast, Q&A, training), with measured time and cost.
2. Offline: safety and practical questions answered on-device; the forecast answered with its timestamp.
3. Offline: out-of-pack or live questions queued, then answered by Muse after `/sync`.

## Working rules

- **End-to-end first.** A crude full pipeline beats a perfect component that isn't wired in.
- **Safety first.** Safety cards come first and get the most practice. Never weaken this.
- **Keep scope tight.** No auth, databases, mobile apps, maps/GPS or new frameworks unless the user asks. The out-of-scope list in `IDEAS.md` is binding.
- **Prefer boring, proven tools.** MLX for local training and inference, small well-known libraries.
- **Runs on a laptop.** The offline path must run with Wi-Fi off on the presenter's Mac.
- **Fail toward "not in your pack".** When unsure, queue for Muse rather than guess.
- **Measure, don't claim.** Latency, pack cost and eval numbers must come from real runs. Cost is tokens × published price, labeled as an estimate.
- **Demo-proof.** Greedy decoding, model warmed up, a finished pack ready as fallback, cached cloud answers for rehearsed questions.
- **Secrets.** API keys come from environment variables (`.env`, gitignored). Never commit or print them.

## Before saying something is done

- Build a pack, run `eval.py` on it, and run the stage script from `data/demo.json` in `demo.py` (offline, then `/sync`).
- Report real results, including failures and wrong routes.

## Repo conventions

- Keep the structure small and obvious; README says how to run the demo.
- Router phrases and the stage script live in `data/` as plain JSON.
- Packs, model weights and caches live under `artifacts/` (gitignored).
