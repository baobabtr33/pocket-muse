---
name: verify-pocket-muse
description: Drive and prove Pocket Muse on the real iPhone (the iOS app that answers by voice through Ray-Ban Meta glasses, on-device Llama 3.2 1B plus a LoRA adapter per day) and on the Mac (pack builds, eval.py). Use before claiming any app, pack, speech or answer change works, before a stage demo, or when the phone behaves oddly.
---

# Verify Pocket Muse

Pocket Muse has two surfaces. The **iPhone app** (`ios/`) is what the user touches on stage: it listens while "Hold to talk" is held, answers on-device, and speaks. The **Mac CLI** (`pack.py`, `demo.py`, `eval.py`, `export_ios.py`) builds the packs the app ships. The helper `scripts/pm.sh` drives both. Paths below are relative to the repo root.

The phone has no UI automation. Its programmatic driver is the app's **self-test**: launched with `-selftest`, it switches to every pack, plays recorded questions (macOS `say`, exported per scenario) through the same speech recognizer and hold-to-talk code as a real voice, with no signal, checks each answer, prints `SELFTEST` lines and writes `Documents/selftest.json`, then exits. Anything only a finger can do (tabs, menus, the stop-speaking button) is a manual step for the human; say so rather than claiming it.

## Launch

1. Packs must be built, one per scenario in `data/scenarios.json`: `uv run python pack.py --scenario school|trip|city` (~5 min each; needs the Baseten key in the environment, e.g. `set -a; . ./.env; set +a`).
2. Export and install: `.claude/skills/verify-pocket-muse/scripts/pm.sh build` (runs `ios/run.sh --export`: quantizes the shared 8-bit base once, copies adapters, records spoken tests, builds Release, installs, launches).
   - **Build gate.** Xcode refuses to build until the `CudaBuild` plugin from `mlx-swift` is trusted. An agent's `-skipPackagePluginValidation` is blocked by the permission classifier. Either the human runs `! ios/run.sh --export` themselves, or trusts the plugin once in Xcode (open `ios/PocketMuse.xcodeproj`, "Trust & Enable"). Report this gate; don't work around it.
   - USB is more reliable than Wi-Fi for the ~1.5 GB install. A `Connection reset by peer` on install: retry `xcrun devicectl device install app --device <id> ios/build/Build/Products/Release-iphoneos/PocketMuse.app`.
3. Ready means the app's status reads `Ready` (normal launch) or the console prints the first `SELFTEST` line (self-test). Loading the base, embedder and first adapter takes ~10-20 s.

Type-checking without building (no plugin gate, needs one earlier successful build for the module files): compile the app sources with `swiftc -typecheck` against `ios/build/Build/Products/Release-iphoneos` plus every `-fmodule-map-file` in `ios/build/Build/Intermediates.noindex/GeneratedModuleMaps-iphoneos/` and every `.spm/checkouts/**/include` dir. That proves it compiles, nothing more.

## Doctor

`pm.sh doctor` (read-only). It checks: iPhone paired, app installed, app running or not, `ios/Bundle/index.json` exported and which packs, a built pack per scenario, and warns when Swift sources are newer than the installed build (the phone runs old code). Exit 0 means worth driving. Run it first and whenever results look stale.

## Drive

- **Phone, full real-user run:** `pm.sh selftest [RUN]`. Takes ~3 min. Streams `SELFTEST PASS|FAIL [pack] said: … | heard: … | <source> <secs>s | <answer>` and ends with `SELFTEST DONE n/m`.
- **Phone, for a human:** `pm.sh launch`, then the human speaks. Phrases that should work are each scenario's `scenes` and `tests` in `data/scenarios.json`.
- **Mac, same questions without speech:** `pm.sh mac [RUN]` (runs `uv run python eval.py --scenarios` with the phone's 8-bit base and pass rule). Use it to separate a model/pack problem from a speech/app problem: Mac passes and phone fails means speech capture or the app.
- **Mac CLI demo:** `uv run python demo.py --pack <name> --offline`, piping questions on stdin works for scripted runs (`printf 'what is for lunch\n/quit\n' | uv run python demo.py --offline`).

See `features/README.md` for per-feature recipes.

## Evidence

Everything goes to `artifacts/verify/<RUN>/` (gitignored; `stop` never touches it):

- `console.log`: the full self-test console stream.
- `selftest.json`: the app's own report pulled from the phone (`passed`, `total`, per question `spoken`, `heard`, `answer`, `source`, `seconds`, `expect`).
- `mac-scenarios.log`: the Mac check.

Proof standards:

- A pass is the real path: recorded speech through the recognizer, hold release, retrieval, on-device generation. Calling `AppModel.ask` with text is not voice proof.
- Report what was heard as well as the answer: a wrong answer from a mis-heard question is a speech bug, not a model bug.
- "On-device" claims need `source` = `device`. The self-test forces no signal, so a pass never used the cloud.
- A self-test against an old install proves the old code. If doctor warns the source is newer, rebuild first or say the result is for the previous build.
- Spoken output (the voice through glasses) is not captured; the human must listen.

## Cleanup

`pm.sh stop` terminates the running app by its pid on the phone (never by name on the Mac). The self-test exits on its own. Nothing else is created on the phone except `Documents/selftest.json`, which the next run overwrites. Evidence in `artifacts/verify/` stays.

## Helpers

`.claude/skills/verify-pocket-muse/scripts/pm.sh {doctor|build|selftest [RUN]|launch|stop|mac [RUN]}`. Run with no args for usage.
