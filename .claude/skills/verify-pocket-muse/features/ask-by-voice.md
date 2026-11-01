# Ask by voice

The user says "Hey Meta, …" (or holds "Hold to talk" and speaks, then lets go) and hears a short answer from the day's pack, produced on the phone with no network.

## Sub-features

- `wake` "Hey Meta"/"Hey Muse" starts capture; a 1.3 s pause after the question ends it.
- `hold` holding the button captures everything said; release ends capture and the answer starts automatically.
- `answer` retrieval of 4 pack facts plus on-device Llama answer, spoken back.
- `stop` the square button stops speaking or listening and returns to waiting.

## How to get to it (user POV)

- Say "Hey Meta, <question>" with the Muse tab open (glasses mic if connected, else phone mic).
- Hold "Hold to talk" at the bottom of the Muse tab, speak, release.
- Tap the speech-bubble menu (bottom left) and pick a scene (text path, no speech).

## Driving it with pm.sh

Preconditions:

- Doctor passes; the installed build matches the sources.

- **Real-user run.** Run `pm.sh selftest RUN`. "Hey Meta…" tests use the wake path, the rest use hold then release. Each line shows `heard:` and the answer; `SELFTEST DONE n/m` ends it.
- **Report.** `artifacts/verify/RUN/selftest.json` lists each question with `heard`, `answer`, `source` (`device` for pack answers), `seconds`.
- **Stop button (manual).** Human holds to talk, releases, then taps stop while it speaks. The voice stops and the caption returns to "Say “Hey Meta…” or hold to talk".
- **Glasses (manual).** With Ray-Ban Meta paired, the chip reads "Glasses"; the human asks a scene question by voice and hears the reply in the glasses.

## Gotchas

- With "Hey Meta" enabled in the Meta AI app, the glasses' own assistant answers too. Turn it off there.
- Robotic voice means no Premium/Enhanced voice installed (Settings > Accessibility > Read & Speak > Voices > Ava (Premium)); the app's Settings shows "· Default".
- On-device recognition sometimes splits "Hey Meta" oddly ("Hey, Meta." / "hey matter"); a wake-path FAIL with an empty question is a recognition miss, check `heard:`.
- Glasses mic forces Bluetooth call-quality audio; replies sound like a phone call.
