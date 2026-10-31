"""Pocket Muse live demo: ask questions with or without internet.

Usage:
  uv run python demo.py                 # latest pack, online
  uv run python demo.py --offline       # start offline (cloud questions get queued)
  uv run python demo.py --pack <name>

Commands:
  /offline, /online   simulate losing / getting back signal (or really turn Wi-Fi off)
  /sync               send queued questions to Muse (needs internet)
  /script             run the stage questions from data/demo.json
  /compare <q>        untuned base model (no pack) vs Pocket Muse
  /pack               show what's in the pack
  /stats              session summary
  /quit
"""

import argparse
import json
import os
import time

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("TQDM_DISABLE", "1")

from dotenv import load_dotenv
from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from pocketmuse.cloud import CloudModel, api_key
from pocketmuse.config import CLOUD_PROVIDERS, DEFAULT_CLOUD_PROVIDER, DEMO_FILE, NOT_IN_PACK
from pocketmuse.edge import EdgeModel
from pocketmuse.pack import Pack, resolve
from pocketmuse.router import LOCAL, Router, load_encoder

console = Console()


class Session:
    def __init__(self, pack_name: str | None, offline: bool):
        with console.status("Loading Pocket Muse..."):
            encoder = load_encoder()
            self.pack = Pack(resolve(pack_name), encoder)
            self.router = Router(encoder, self.pack.local_examples())
            self.edge = EdgeModel(self.pack)
            self.cloud = CloudModel()
        self.online = not offline
        self.base = None  # loaded on first /compare
        self.queue: list[str] = []
        self.log = []  # (route, seconds, cost)
        loc = (self.pack.meta.get("location") or {}).get("name", "unknown")
        forecast = " ".join(f for c in self.pack.cards if c["kind"] == "forecast" for f in c["facts"])
        self.context = (
            f"Today is {time.strftime('%A, %B %-d')}. Their plans: {self.pack.meta['plan']} Location: {loc}. "
            f"Forecast you fetched for them: {forecast or 'none'}"
        )

    def status(self) -> str:
        return "[green]● online[/]" if self.online else "[red]● offline[/]"

    def ask(self, question: str):
        t0 = time.perf_counter()
        decision = self.router.route(question)
        route_ms = (time.perf_counter() - t0) * 1000

        if decision.route == LOCAL:
            text = self.edge.answer(question)
            seconds = time.perf_counter() - t0
            if NOT_IN_PACK.lower() in text.lower():
                self.queue.append(question)
                self.log.append(("QUEUED", seconds, 0.0))
                self._panel(Text(text), "yellow", "POCKET MUSE → queued for Muse", seconds, 0.0, decision, route_ms)
                return
            self.log.append((LOCAL, seconds, 0.0))
            self._panel(Text(text), "green", "POCKET MUSE · on-device", seconds, 0.0, decision, route_ms)
            return

        if not self.online:
            self.queue.append(question)
            seconds = time.perf_counter() - t0
            self.log.append(("QUEUED", seconds, 0.0))
            msg = "No signal, and this isn't in your pack. Queued: I'll ask Muse when you're back online."
            self._panel(Text(msg), "yellow", "QUEUED · needs big Muse", seconds, 0.0, decision, route_ms)
            return
        try:
            ans = self.cloud.answer(question, self.context)
            text, cost = ans.text, ans.cost
            label = f"CLOUD · {self.cloud.spec['label']}" + (" (cached)" if ans.cached else "")
        except Exception as e:  # network gone mid-demo: queue instead of crashing
            self.queue.append(question)
            text, cost, label = f"Couldn't reach Muse ({type(e).__name__}). Queued for later.", 0.0, "QUEUED"
        seconds = time.perf_counter() - t0
        self.log.append(("CLOUD" if cost else "QUEUED", seconds, cost))
        self._panel(Markdown(text), "magenta", label, seconds, cost, decision, route_ms)

    def _panel(self, body, style, label, seconds, cost, d, route_ms):
        header = f"[bold {style}]{label}[/] | {seconds:.2f}s | ${cost:.4f}"
        if console.width >= 110:
            header += f"  [dim](route {route_ms:.0f}ms · pack {d.local_score:.2f} vs general {d.cloud_score:.2f})[/]"
        console.print(Panel(body, title=header, title_align="left", border_style=style))

    def sync(self):
        if not self.online:
            console.print("[yellow]Still offline. /online first.[/]")
            return
        if not self.queue:
            console.print("Nothing queued.")
            return
        pending, self.queue = self.queue, []
        console.print(f"[bold]Back online: sending {len(pending)} queued question(s) to Muse[/]")
        for q in pending:
            console.print(f"[bold cyan]> [/]{q}")
            t0 = time.perf_counter()
            try:
                ans = self.cloud.answer(q, self.context)
            except Exception as e:
                self.queue.append(q)
                console.print(f"[red]failed ({type(e).__name__}), kept in queue[/]")
                continue
            secs = time.perf_counter() - t0
            self.log.append(("CLOUD", secs, ans.cost))
            title = f"[bold magenta]CLOUD · {self.cloud.spec['label']}[/] | {secs:.2f}s | ${ans.cost:.4f}"
            console.print(Panel(Markdown(ans.text), title=title, title_align="left", border_style="magenta"))

    def compare(self, question: str):
        if self.base is None:
            with console.status("Loading untuned base model..."):
                self.base = EdgeModel(self.pack, base=True)
        table = Table(show_lines=True, expand=True)
        table.add_column("Same small model, no pack", style="red")
        table.add_column("Pocket Muse", style="green")
        table.add_row(Text(self.base.answer(question, notes="")), Text(self.edge.answer(question)))
        console.print(table)

    def show_pack(self):
        b = self.pack.meta.get("build", {})
        console.print(f"[bold]{self.pack.title}[/]  ·  built {self.pack.meta['built']}  ·  plan: {self.pack.meta['plan']}")
        for c in self.pack.cards:
            tag = "[bold red]safety  [/]" if c["kind"] == "safety" else ("[cyan]forecast[/]" if c["kind"] == "forecast" else "        ")
            console.print(f"  {tag} {c['title']}")
        if b:
            console.print(
                f"[dim]{b['pairs']} Q&A · Muse teaching {b['teach_seconds']:.0f}s (est. ${b['teach_cost_usd']:.3f}) · "
                f"training {b['train_seconds']:.0f}s · adapter {b['adapter_mb']:.0f} MB[/]"
            )

    def stats(self):
        if not self.log:
            console.print("No questions yet.")
            return
        n = len(self.log)
        n_local = sum(r == LOCAL for r, _, _ in self.log)
        n_queued = sum(r == "QUEUED" for r, _, _ in self.log)
        cloud = [(s, c) for r, s, c in self.log if r == "CLOUD"]
        local_lat = [s for r, s, _ in self.log if r == LOCAL]
        t = Table(title="Session", show_header=False)
        t.add_row("Questions", str(n))
        t.add_row("Answered on-device, no internet needed", f"{n_local} ({n_local / n:.0%}) · $0")
        if local_lat:
            t.add_row("On-device latency (measured)", f"avg {sum(local_lat) / len(local_lat):.2f}s")
        t.add_row("Queued for Muse", f"{n_queued} still waiting: {len(self.queue)}")
        if cloud:
            t.add_row("Cloud answers (measured)", f"{len(cloud)} · ${sum(c for _, c in cloud):.4f} · avg {sum(s for s, _ in cloud) / len(cloud):.2f}s")
        b = self.pack.meta.get("build")
        if b:
            t.add_row("One-time pack cost (estimate)", f"${b['teach_cost_usd']:.3f} of Muse tokens + {b['train_seconds']:.0f}s on this laptop")
        console.print(t)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack")
    ap.add_argument("--offline", action="store_true", help="start with no signal")
    args = ap.parse_args()
    load_dotenv()
    provider = os.environ.get("CLOUD_PROVIDER", DEFAULT_CLOUD_PROVIDER)
    if not api_key(provider):
        console.print(f"[yellow]{' or '.join(CLOUD_PROVIDERS[provider]['key_env'])} not set: cloud answers come from cache only.[/]")

    s = Session(args.pack, args.offline)
    console.print(f"[bold]Pocket Muse[/] · {s.pack.title}  {s.status()}")
    console.print("[dim]/offline /online /sync /script /compare /pack /stats /quit[/]\n")
    while True:
        try:
            line = console.input(f"{s.status()} [bold cyan]> [/]").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line:
            continue
        if line in ("/quit", "/exit"):
            break
        elif line == "/offline":
            s.online = False
            console.print("[red]Signal lost.[/] Pocket Muse keeps working on-device.")
        elif line == "/online":
            s.online = True
            console.print(f"[green]Back online.[/] {len(s.queue)} question(s) queued. /sync to send them.")
        elif line == "/sync":
            s.sync()
        elif line == "/stats":
            s.stats()
        elif line == "/pack":
            s.show_pack()
        elif line == "/script":
            for item in json.loads(DEMO_FILE.read_text())["script"]:
                console.print(f"{s.status()} [bold cyan]> [/]{item['q']}")
                s.ask(item["q"])
        elif line.startswith("/compare"):
            s.compare(line.removeprefix("/compare").strip() or "There's a coyote right in front of me, what do I do?")
        else:
            s.ask(line)
    s.stats()


if __name__ == "__main__":
    main()
