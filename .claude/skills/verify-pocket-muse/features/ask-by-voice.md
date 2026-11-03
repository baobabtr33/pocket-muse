# Ask by voice

The user holds "Hold to talk", speaks (saying "Hey Meta, …" first is fine; it's stripped), lets go, and hears a short answer from the day's pack, produced on the phone with no network. The mic is open only while the button is held; there is no wake word.

## Sub-features

- `hold` holding the button opens the mic and captures everything said; release ends capture and the answer starts automatically.
- `answer` retrieval of 4 pack facts plus on-device Llama answer, spoken back.
- `stop-speaking` while Muse speaks, a speaker-slash button appears at the right of the hold button; tapping it stops the voice. It is hidden otherwise. Holding to talk also cuts the voice off.

## How to get to it (user POV)

- Hold "Hold to talk" at the bottom of the Muse tab, speak, release (glasses mic if connected, else phone mic).
- Tap the speech-bubble menu (bottom left) and pick a scene (text path, no speech).

## Driving it with pm.sh

Preconditions:

- Doctor passes; the installed build matches the sources.

- **Real-user run.** Run `pm.sh selftest RUN`. Every test holds, plays the recorded question, then releases 0.4 s after it ends. Each line shows `heard:` and the answer; `SELFTEST DONE n/m` ends it.
- **Report.** `artifacts/verify/RUN/selftest.json` lists each question with `heard`, `answer`, `source` (`device` for pack answers), `seconds`.
- **Stop speaking (manual).** Human holds to talk, releases, then taps the speaker-slash button while it speaks. The voice stops, the button disappears and the caption returns to "Hold to talk". Saying "Hey Meta" without holding must do nothing.
- **Glasses (manual).** With Ray-Ban Meta paired, the chip reads "Glasses"; the human asks a scene question by voice and hears the reply in the glasses.

## Gotchas

- With "Hey Meta" enabled in the Meta AI app, the glasses' own assistant answers too. Turn it off there.
- Robotic voice means no Premium/Enhanced voice installed (Settings > Accessibility > Read & Speak > Voices > Ava (Premium)); the app's Settings shows "· Default".
- Releasing too early cuts off the last words; check `heard:` before blaming the model.
- Glasses mic forces Bluetooth call-quality audio; replies sound like a phone call.
