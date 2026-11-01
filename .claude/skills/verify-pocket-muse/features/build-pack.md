# Build a pack

On the Mac, Muse plans a day (safety cards first), explains its reasoning, writes practice Q&A, and Llama 3.2 1B is LoRA-trained on them; `export_ios.py` ships every day to the app.

## Sub-features

- `scenario` `pack.py --scenario <id>` builds from `data/scenarios.json` (plan plus optional notes file).
- `explain` Muse's reasoning per pack and card.
- `export` shared 8-bit base, adapters, spoken tests into `ios/Bundle`.
- `check` `eval.py --scenarios` on the Mac.

## How to get to it (user POV)

- `uv run python pack.py --scenario school` (or trip, city).
- `uv run python export_ios.py`.

## Driving it with pm.sh

Preconditions:

- Baseten key in the environment (`baseten_meta` or `BASETEN_API_KEY`, from `.env`).

- **Build.** `uv run python pack.py --scenario trip`. Ends with `✓ Pack ready in …s`; `artifacts/packs/<slug>-1b/pack.json` has `"scenario": "trip"` and `build`.
- **Check.** `pm.sh mac RUN`; each test prints PASS/FAIL and the total.
- **Export.** `uv run python export_ios.py` ends `✓ ios/Bundle ready: N packs`.

## Gotchas

- Packs vary build to build; always run the check before the stage.
- Two builds at once fight for the GPU and slow both; build sequentially.
