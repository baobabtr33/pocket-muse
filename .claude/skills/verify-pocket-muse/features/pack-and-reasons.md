# Pack and reasons

The Pack tab shows the user's plan, Muse's reasoning, every card Muse wrote (safety first, with why), and the questions Llama learned. Each answer card on the Muse tab has "Why this answer" with how it was routed and the pack notes it used.

## Sub-features

- `reasoning` plan plus Muse's 2-4 sentence thinking.
- `cards` list with SAFETY FIRST / YOUR DAY / FORECAST tags and one-line why.
- `learned` searchable learned Q&A, including LEARNS TO REFUSE items.
- `why-answer` per-answer explanation and the exact notes given to the model.
- `how` How tab: four build steps with the pack's real numbers, self-test button.

## How to get to it (user POV)

- Pack tab; tap a card for its facts and Q&A.
- Muse tab, an answer card, "Why this answer".
- How tab.

## Driving it with pm.sh

Preconditions:

- Pack built with reasoning (`pack.json` has `reasoning` and per-card `why`; backfill with `uv run python pack.py --explain <pack>`).

- **Data present.** Check `ios/Bundle/packs/<id>/pack.json` has non-empty `reasoning`, `cards[].why`, `learned`. Run `python3 -c "import json;d=json.load(open('ios/Bundle/packs/school/pack.json'));print(d['reasoning']);print(sum(bool(c['why']) for c in d['cards']),len(d['cards']),len(d['learned']))"`.
- **Screens (manual).** Human opens Pack, How, and one "Why this answer"; all render with the same numbers.

## Gotchas

- Packs built before the explain step have empty reasons until `--explain` is run and the bundle re-exported.
