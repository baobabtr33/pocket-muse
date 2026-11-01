"""Check a pack before going on stage.

1. Routing: held-out pack questions should go local; general/live questions should go to the cloud;
   the stage script must take its expected routes.
2. Answers on held-out pack questions, for three setups:
     pocket   - student + pack adapter + retrieved notes (what the demo runs)
     base+rag - untuned base model + the same retrieved notes
     base     - untuned base model, no notes
   Scored by key terms (numbers and names from the reference answer) found in the answer, and
   invented numbers (numbers in the answer that appear nowhere in the pack's notes).

3. --scenarios: every day in data/scenarios.json, its spoken-test questions answered the way the phone
   answers them (8-bit base from ios/Bundle + the pack adapter), with the phone's pass rule.
   --setup picks what answers them, to test whether distillation earns its place:
     student - pack adapter + retrieved notes (what the phone runs; the default)
     rag     - untuned base + the same retrieved notes
     full    - untuned base + the whole pack in the prompt, no training

Usage: uv run python eval.py [--pack NAME] [-n 40] [--no-base]
       uv run python eval.py --scenarios [--setup student|rag|full]
"""

import argparse
import json
import os
import re
import time

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from pocketmuse.config import DEMO_FILE, NOT_IN_PACK, ROOT, SCENARIOS_FILE, format_card
from pocketmuse.edge import EdgeModel
from pocketmuse.pack import Pack, list_packs, resolve, resolve_expect
from pocketmuse.router import CLOUD, LOCAL, Router, load_encoder

NUM = re.compile(r"\d+(?:[.:]\d+)?")
STOP = {"The", "A", "An", "It", "Yes", "No", "You", "Your", "If", "In", "On", "At", "For", "This", "That", "There", "I"}


def key_terms(answer: str) -> set[str]:
    nums = set(NUM.findall(answer))
    names = {w.strip(".,!?;:()'\"") for w in answer.split()[1:] if w[:1].isupper()} - STOP
    return {t for t in nums | names if t}


def score(answer: str, terms: set[str]) -> float:
    if not terms:
        return 1.0
    low = answer.lower()
    return sum(t.lower() in low for t in terms) / len(terms)


def scenarios(setup: str = "student"):
    """Same check as the app's self-test (AppModel.check), minus speech recognition."""
    from mlx_lm import load

    encoder = load_encoder()
    built = {}
    for path in list_packs():
        sid = json.loads((path / "pack.json").read_text()).get("scenario")
        built.setdefault(sid, path)
    phone_base = ROOT / "ios" / "Bundle" / "base"
    total = passed = 0
    for sc in json.loads(SCENARIOS_FILE.read_text())["scenarios"]:
        if sc["id"] not in built:
            print(f"-- {sc['name']}: not built")
            continue
        pack = Pack(built[sc["id"]], encoder)
        model = EdgeModel(pack)
        if phone_base.exists():
            adapter = str(pack.adapter) if setup == "student" else None
            model.model, model.tokenizer = load(str(phone_base), adapter_path=adapter)
        whole_pack = "\n\n".join(format_card(c) for c in pack.cards) if setup == "full" else None
        print(f"-- {sc['name']}: {pack.title} [{setup}]")
        for t in sc.get("tests", []):
            t0 = time.perf_counter()
            a = model.answer(t["q"], notes=whole_pack)
            secs = time.perf_counter() - t0
            refused = NOT_IN_PACK.lower() in a.lower()
            t = {**t, "expect": resolve_expect(t["expect"], pack.cards)}
            ok = refused if t["expect"] == "REFUSE" else (
                not refused and any(k in a.lower() for k in t["expect"].lower().split("|")))
            total += 1
            passed += ok
            print(f"   {'PASS' if ok else 'FAIL'} {secs:.2f}s  {t['q']}\n        {a}")
    print(f"\n{passed}/{total} passed")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenarios", action="store_true", help="check every day in data/scenarios.json")
    ap.add_argument("--setup", choices=["student", "rag", "full"], default="student",
                    help="with --scenarios: trained student, untuned base + retrieval, or untuned base + whole pack")
    ap.add_argument("--pack")
    ap.add_argument("-n", type=int, default=40, help="held-out questions to answer")
    ap.add_argument("--no-base", action="store_true")
    ap.add_argument("--routing-only", action="store_true")
    args = ap.parse_args()
    if args.scenarios:
        return scenarios(args.setup)

    encoder = load_encoder()
    pack = Pack(resolve(args.pack), encoder)
    router = Router(encoder, pack.local_examples())
    demo = json.loads(DEMO_FILE.read_text())
    valid = [p for p in pack.pairs if p["split"] == "valid"]
    print(f"Pack: {pack.title} ({pack.path.name})\n")

    # Routing
    checks = [(p["q"], LOCAL, "pack") for p in valid if p["kind"] == "qa"]
    checks += [(p["q"], CLOUD, "gap") for p in valid if p["kind"] == "gap"]
    checks += [(q, CLOUD, "general") for q in demo["cloud_holdout"]]
    checks += [(i["q"], i["route"], "script") for i in demo["script"]]
    by_set: dict[str, list[int]] = {}
    for q, want, group in checks:
        d = router.route(q)
        ok = d.route == want
        by_set.setdefault(group, []).append(ok)
        if not ok or group == "script":
            print(f"[{'OK ' if ok else 'BAD'}] {group:7} {d.route:10} L={d.local_score:.2f} C={d.cloud_score:.2f} | {q}")
    print()
    for group, oks in by_set.items():
        note = "  (local is fine here: the model should say it's not in the pack)" if group == "gap" else ""
        print(f"Routing {group:8} {sum(oks)}/{len(oks)}{note}")

    if args.routing_only:
        return

    # Answers
    pack_text = " ".join(format_card(c) for c in pack.cards)
    pack_nums = set(NUM.findall(pack_text))
    qa = [p for p in valid if p["kind"] == "qa"][: args.n]
    gaps = [p for p in valid if p["kind"] == "gap"][:10]
    setups = {"pocket": EdgeModel(pack)}
    if not args.no_base:
        base = EdgeModel(pack, base=True)
        setups["base+rag"] = base
        setups["base"] = base

    print()
    results = {}
    for name, model in setups.items():
        scores, invented, latency = [], 0, []
        for p in qa:
            notes = "" if name == "base" else None
            t0 = time.perf_counter()
            ans = model.answer(p["q"], notes=notes)
            latency.append(time.perf_counter() - t0)
            s = score(ans, key_terms(p["a"]))
            scores.append(s)
            made_up = set(NUM.findall(ans)) - pack_nums
            invented += bool(made_up)
            if name == "pocket" and (s < 0.5 or made_up):
                print(f"  low  {s:.2f} | {p['q']}\n       ref: {p['a']}\n       got: {ans}" + (f"\n       invented: {made_up}" if made_up else ""))
        refused = sum(NOT_IN_PACK.lower() in model.answer(p["q"], notes=None if name != "base" else "").lower() for p in gaps)
        results[name] = (sum(scores) / len(scores), invented, refused, sum(latency) / len(latency))

    print(f"\n{'setup':10} {'key terms':>10} {'invented #s':>12} {'says not-in-pack':>17} {'latency':>8}")
    for name, (s, inv, ref, lat) in results.items():
        print(f"{name:10} {s:>9.0%} {inv:>8}/{len(qa)} {ref:>13}/{len(gaps)} {lat:>7.2f}s")


if __name__ == "__main__":
    main()
