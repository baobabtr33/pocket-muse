"""Pack an AI for the trip: big Muse teaches a small on-device model what you'll need offline.

Usage:
  uv run python pack.py "Hiking in Yosemite Valley this weekend, no cell signal"
  uv run python pack.py "<plan>" --iters 120      # faster, less trained
  uv run python pack.py --retrain <pack-name>      # retrain an existing pack's dataset
"""

import argparse
import json
import os
import time

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from dotenv import load_dotenv
from rich.console import Console
from rich.progress import BarColumn, Progress, TextColumn, TimeElapsedColumn

from pocketmuse.builder import Builder
from pocketmuse.cloud import token_cost
from pocketmuse.pack import resolve
from pocketmuse.train import fuse, train

console = Console()


def run_training(pack_dir, iters: int, lr: float) -> float:
    t0 = time.perf_counter()
    with Progress(
        TextColumn("[bold]Training Pocket Muse[/]"), BarColumn(), TextColumn("{task.completed}/{task.total} steps"),
        TextColumn("loss {task.fields[loss]}"), TimeElapsedColumn(), console=console,
    ) as bar:
        task = bar.add_task("train", total=iters, loss="-")
        train(pack_dir, iters=iters, lr=lr, on_iter=lambda i, loss: bar.update(task, completed=i, loss=f"{loss:.3f}"))
    with console.status("Fusing adapter into the model..."):
        fuse(pack_dir)
    return time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan", nargs="?", help="what you're doing, in plain words")
    ap.add_argument("--retrain", metavar="PACK", help="retrain an existing pack instead of building a new one")
    ap.add_argument("--safety-cards", type=int, default=8)
    ap.add_argument("--other-cards", type=int, default=8)
    ap.add_argument("--per-card", type=int, default=20)
    ap.add_argument("--iters", type=int, default=120)
    ap.add_argument("--lr", type=float, default=5e-5)
    args = ap.parse_args()
    load_dotenv()

    if args.retrain:
        pack_dir = resolve(args.retrain) if args.retrain != "latest" else resolve(None)
        secs = run_training(pack_dir, args.iters, args.lr)
        console.print(f"Retrained [bold]{pack_dir.name}[/] in {secs:.0f}s")
        return
    if not args.plan:
        ap.error("give a plan, e.g. pack.py \"Hiking in Yosemite this weekend\"")

    t_start = time.perf_counter()
    builder = Builder(
        args.plan, n_safety=args.safety_cards, n_other=args.other_cards, per_card=args.per_card, log=console.print
    )

    with console.status("[bold]Muse is planning your pack...[/]"):
        spec = builder.plan_cards()
    console.print(f"[bold green]✓[/] Pack: [bold]{spec['title']}[/] ({len(spec['cards'])} note cards)")
    for c in spec["cards"]:
        tag = "[bold red]safety[/] " if c["kind"] == "safety" else "       "
        console.print(f"   {tag}[dim]·[/] {c['title']}")

    with console.status("Fetching weather forecast..."):
        try:
            fc = builder.add_forecast(spec)
        except Exception as e:
            fc = None
            console.print(f"[yellow]  forecast unavailable ({type(e).__name__}); pack will have no weather[/]")
    if fc:
        console.print(f"[bold green]✓[/] Forecast snapshot: {fc['facts'][1]}")

    with Progress(
        TextColumn("[bold]Muse is writing practice questions[/]"), BarColumn(),
        TextColumn("{task.completed}/{task.total} cards · {task.fields[pairs]} Q&A"), TimeElapsedColumn(),
        console=console,
    ) as bar:
        task = bar.add_task("teach", total=len(spec["cards"]) + 1, pairs=0)
        count = {"n": 0}

        def on_card(_title, n):
            count["n"] += n
            bar.update(task, advance=1, pairs=count["n"])

        pairs = builder.teach(spec, on_card=on_card)
    pack_dir = builder.write(spec, pairs)
    t_teach = time.perf_counter() - t_start
    u = builder.usage
    teach_cost = token_cost(builder.cloud.provider, u["input_tokens"], u["output_tokens"])
    console.print(
        f"[bold green]✓[/] {len(pairs)} Q&A pairs from {u['calls']} Muse calls in {t_teach:.0f}s "
        f"(est. ${teach_cost:.3f}: {u['input_tokens']:,} in + {u['output_tokens']:,} out tokens × list price)"
    )

    t_train = run_training(pack_dir, args.iters, args.lr)
    adapter_mb = sum(f.stat().st_size for f in (pack_dir / "adapters").glob("adapters.safetensors")) / 1e6

    meta = json.loads((pack_dir / "pack.json").read_text())
    meta["build"] = {
        "teach_seconds": round(t_teach, 1),
        "train_seconds": round(t_train, 1),
        "iters": args.iters,
        "pairs": len(pairs),
        "teach_cost_usd": round(teach_cost, 4),
        "adapter_mb": round(adapter_mb, 1),
    }
    (pack_dir / "pack.json").write_text(json.dumps(meta, indent=2))
    console.print(
        f"[bold green]✓ Pack ready[/] in {time.perf_counter() - t_start:.0f}s total "
        f"(training {t_train:.0f}s). Adapter: {adapter_mb:.0f} MB on top of the shared 0.5B base model."
    )
    console.print(f"  Go offline and run: [bold]uv run python demo.py --pack {pack_dir.name}[/]")


if __name__ == "__main__":
    main()
