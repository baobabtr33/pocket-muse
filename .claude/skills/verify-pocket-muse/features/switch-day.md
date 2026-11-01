# Switch day

The user picks which day they're prepared for (School day, Trip day, City weekend). The app swaps the day's LoRA adapter onto the shared Llama and re-indexes that pack's facts.

## Sub-features

- `picker` header menu under "Pocket Muse" and the Pack tab toolbar list the days.
- `swap` adapter unload and load without reloading the base model.
- `persist` the chosen day is remembered across launches.

## How to get to it (user POV)

- Tap the day name under "Pocket Muse" on the Muse tab, choose a day.
- Pack tab, top-right menu.

## Driving it with pm.sh

Preconditions:

- `ios/Bundle/index.json` lists more than one pack.

- **All days.** `pm.sh selftest RUN` switches to each pack in turn; every pack's tests appear with its name in `[pack]`. A pack missing from the output did not load.
- **Persist (manual).** Human picks Trip day, force-quits, relaunches; the header still reads "Trip day".

## Gotchas

- A pack trained on a different base model than the shipped one is skipped at export (message from `export_ios.py`).
- `num_layers: -1` in an mlx_lm adapter config crashes MLX Swift; `export_ios.py` rewrites it to the layer count.
