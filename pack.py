"""Muse thinks ahead: tell it what's coming up, and it teaches a small on-device model to answer
the questions you'll ask, safety first, so answers are instant and work with no signal.

Usage:
  uv run python pack.py "Saturday hiking on Mount Tam, then kayaking out of Sausalito"
  uv run python pack.py --demo                     # the stage plan in data/demo.json
  uv run python pack.py --demo --student 3b        # Llama 3.2 3B student (default 1B)
  uv run python pack.py "<plan>" --iters 120      # faster, less trained
  uv run python pack.py --retrain <pack-name>      # retrain an existing pack's dataset
"""

import argparse
import json
import os
import time
from datetime import date

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from dotenv import load_dotenv
from rich.console import Console
from rich.progress import BarColumn, Progress, TextColumn, TimeElapsedColumn

from pocketmuse.builder import Builder, forecast_pairs
from pocketmuse.cloud import token_cost
from pocketmuse.config import DEFAULT_STUDENT, DEMO_FILE, STUDENTS
from pocketmuse.pack import resolve
from pocketmuse.train import fuse, train

console = Console()


def run_training(pack_dir, iters: int, lr: float) -> float:
    base = json.loads((pack_dir / "pack.json").read_text()).get("student") or STUDENTS[DEFAULT_STUDENT]
    t0 = time.perf_counter()
    with Progress(
        TextColumn("[bold]Training Pocket Muse[/]"), BarColumn(), TextColumn("{task.completed}/{task.total} steps"),
        TextColumn("loss {task.fields[loss]}"), TimeElapsedColumn(), console=console,
    ) as bar:
        task = bar.add_task("train", total=iters, loss="-")
        train(pack_dir, base, iters=iters, lr=lr, on_iter=lambda i, loss: bar.update(task, completed=i, loss=f"{loss:.3f}"))
    with console.status("Fusing adapter into the model..."):
        fuse(pack_dir, base)
    return time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan", nargs="?", help="what's coming up, in plain words")
    ap.add_argument("--demo", action="store_true", help="use the stage plan from data/demo.json")
    ap.add_argument("--student", choices=sorted(STUDENTS), default=DEFAULT_STUDENT, help="Llama 3.2 size")
    ap.add_argument("--rebuild", metavar="PACK", help="rewrite an existing pack's dataset (no Muse calls) and retrain")
    ap.add_argument("--retrain", metavar="PACK", help="retrain an existing pack instead of building a new one")
    ap.add_argument("--safety-cards", type=int, default=8)
    ap.add_argument("--other-cards", type=int, default=8)
    ap.add_argument("--per-card", type=int, default=20)
    ap.add_argument("--iters", type=int, default=200)
    ap.add_argument("--lr", type=float, default=2e-5)
    args = ap.parse_args()
    load_dotenv()

    if args.rebuild:
        pack_dir = resolve(None if args.rebuild == "latest" else args.rebuild)
        meta = json.loads((pack_dir / "pack.json").read_text())
        pairs = json.loads((pack_dir / "pairs.json").read_text())
        student = next(k for k, v in STUDENTS.items() if v == meta["student"])
        builder = Builder(meta["plan"], student, log=console.print)
        builder.today = date.fromisoformat(meta["built"])
        # Regenerate the exact forecast Q&A (their format may have changed); keep Muse's pairs.
        weekdays = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Today", "Tomorrow")
        pairs = [p for p in pairs if not (p["kind"] == "qa" and p["a"].startswith(weekdays) and "it can't update offline." in p["a"])]
        for i, card in enumerate(meta["cards"]):
            if card["kind"] == "forecast":
                pairs += [dict(p, split="train") for p in forecast_pairs(card, builder.today, i)]
        with console.status("Rewriting dataset from the saved pack (no Muse calls)..."):
            builder.write({"title": meta["title"], "location": meta["location"], "cards": meta["cards"]}, pairs)
            fresh = json.loads((pack_dir / "pack.json").read_text())
            fresh.update({k: meta[k] for k in ("teacher", "build") if k in meta})  # keep the original build stats
            (pack_dir / "pack.json").write_text(json.dumps(fresh, indent=2))
        secs = run_training(pack_dir, args.iters, args.lr)
        console.print(f"Rebuilt [bold]{pack_dir.name}[/] in {secs:.0f}s")
        return
    if args.retrain:
        pack_dir = resolve(args.retrain) if args.retrain != "latest" else resolve(None)
        secs = run_training(pack_dir, args.iters, args.lr)
        console.print(f"Retrained [bold]{pack_dir.name}[/] in {secs:.0f}s")
        return
    if args.demo:
        args.plan = json.loads(DEMO_FILE.read_text())["plan"]
    if not args.plan:
        ap.error("say what's coming up, e.g. pack.py \"Saturday hiking on Mount Tam\"")

    t_start = time.perf_counter()
    builder = Builder(
        args.plan,
        args.student, n_safety=args.safety_cards, n_other=args.other_cards, per_card=args.per_card, log=console.print
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
        f"(training {t_train:.0f}s). Adapter: {adapter_mb:.0f} MB on Llama 3.2 {args.student.upper()}."
    )
    console.print(f"  Try it (Wi-Fi off works too): [bold]uv run python demo.py --pack {pack_dir.name}[/]")


if __name__ == "__main__":
    main()
