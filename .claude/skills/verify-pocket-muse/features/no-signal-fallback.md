# No-signal fallback

A question the pack can't answer gets "That's not in your pack" from the on-device model. With no signal it is queued; online with a Baseten key it goes to big Muse (Muse Spark Open) in the cloud.

## Sub-features

- `refuse` on-device model refuses off-pack questions instead of guessing.
- `queue` with no signal the turn is marked QUEUED.
- `cloud` online with a key, the answer comes from big Muse (`BIG MUSE · CLOUD`).
- `sync` "Ask Muse the N queued" sends queued turns once online.

## How to get to it (user POV)

- Ask something off-topic ("What's the score of the Warriors game?").
- Tap the Online chip to toggle "No signal".
- Speech-bubble menu > "Ask Muse the N queued".

## Driving it with pm.sh

Preconditions:

- Doctor passes. For `cloud`, `ios/Secrets.xcconfig` has `BASETEN_KEY = …` and the build includes it.

- **Refuse and queue.** `pm.sh selftest RUN` includes `REFUSE` tests per pack; a pass has `source` not `device`. With forced no signal the source is `queued`.
- **Cloud (manual).** Human turns signal on (chip reads Online), asks an off-topic question, and sees a `BIG MUSE · CLOUD` card with a cost.
- **Mac reproduction.** `pm.sh mac` shows the on-device text for each REFUSE test.

## Gotchas

- Without a Baseten key the app always queues, even online (Settings says "No Baseten key").
- The cloud key must never be committed: it lives only in the gitignored `ios/Secrets.xcconfig`.
