# Pocket Muse verification map

The maintained source for verifying what a Pocket Muse user can do. Read this index, then use the matching feature file as the recipe.

## Baseline preconditions

- `pm.sh doctor` exits 0: iPhone paired, app installed, `ios/Bundle` exported with every scenario pack.
- The installed build is not older than the Swift sources (doctor warns otherwise).
- Packs exist for `school`, `trip` and `city` (`data/scenarios.json`).
- Only drive the app instance this run launched (`pm.sh selftest` and `pm.sh launch` both pass `--terminate-existing`).

## Driving conventions

- Phone actions go through `pm.sh` (devicectl). Finger-only steps are marked **manual** and are done by the human.
- Questions come from `data/scenarios.json` (`scenes` for the stage, `tests` for the self-test). Edit there, re-export, rebuild.
- Mac-side reproduction of a phone result: `pm.sh mac`.

## Proof and skip reporting

- Capture the spoken question, what was heard, the answer and its source for each question.
- A manual step not done by the human is reported as unverified, not as passed through another path.
- Record the RUN id with every claim.

## Features

- [ask-by-voice.md](ask-by-voice.md): wake word and hold-to-talk, answered on-device.
- [no-signal-fallback.md](no-signal-fallback.md): off-pack questions queued with no signal, sent to big Muse online.
- [switch-day.md](switch-day.md): switching between school, trip and city packs.
- [pack-and-reasons.md](pack-and-reasons.md): Pack tab, Muse's reasoning, learned Q&A, "Why this answer".
- [build-pack.md](build-pack.md): building and exporting a day's pack on the Mac.
