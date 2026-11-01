"""Export built packs for the iOS app.

  uv run python export_ios.py          # every scenario in data/scenarios.json that has a built pack

Writes ios/Bundle/ (gitignored), which the Xcode project ships inside the app:
  base/                 Llama 3.2 1B Instruct, 8-bit, shared by every pack
  embedder/             bge-small, for the same fact retrieval the student was trained with
  packs/<id>/adapter/   the pack's LoRA adapter (~23 MB): what Muse taught Llama for that day
  packs/<id>/pack.json  title, Muse's reasoning, cards, learned Q&A, retrieval units, scenes
  selftest/<id>/*.wav   spoken test questions (macOS `say`), for the app's real-user self-test
  index.json            the packs, in scenario order

One shared base plus small adapters keeps the app small: each extra day costs ~23 MB, not 1.2 GB.
An 8-bit base with the adapter scores the same on the strict stage check as the fused bf16 model.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

from pocketmuse.config import EMBED_MODEL, NOT_IN_PACK, ROOT, SCENARIOS_FILE
from pocketmuse.pack import Pack, list_packs, resolve_expect
from pocketmuse.router import load_encoder

OUT = ROOT / "ios" / "Bundle"


def export_base(student: str):
    base = OUT / "base"
    stamp = base / "source.txt"
    if stamp.exists() and stamp.read_text() == student:
        return
    shutil.rmtree(base, ignore_errors=True)
    print(f"Quantizing {student} to 8-bit ...")
    subprocess.run(
        [sys.executable, "-m", "mlx_lm", "convert", "--hf-path", student, "--mlx-path", str(base), "-q", "--q-bits", "8"],
        check=True,
    )
    stamp.write_text(student)


def export_embedder():
    emb = OUT / "embedder"
    if (emb / "model.safetensors").exists():
        return
    src = Path(snapshot_download(EMBED_MODEL))
    (emb / "1_Pooling").mkdir(parents=True, exist_ok=True)
    for name in ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
                 "special_tokens_map.json", "vocab.txt"]:
        shutil.copy(src / name, emb / name)
    shutil.copy(src / "1_Pooling" / "config.json", emb / "1_Pooling" / "config.json")


def export_pack(pack: Pack, scenario: dict) -> dict:
    out = OUT / "packs" / scenario["id"]
    shutil.rmtree(out, ignore_errors=True)
    (out / "adapter").mkdir(parents=True)
    shutil.copy(pack.adapter / "adapters.safetensors", out / "adapter" / "adapters.safetensors")
    cfg = json.loads((pack.adapter / "adapter_config.json").read_text())
    if cfg.get("num_layers", -1) < 0:  # mlx_lm writes -1 for "all layers"; MLX Swift needs the count
        cfg["num_layers"] = json.loads((OUT / "base" / "config.json").read_text())["num_hidden_layers"]
    (out / "adapter" / "adapter_config.json").write_text(json.dumps(cfg, indent=1))

    # Same retrieval as pocketmuse.pack.FactIndex. The phone embeds units and practice questions itself
    # (so query and fact vectors come from one embedder); the discrete parts are exported here.
    idx = pack.index
    data = {
        "id": scenario["id"],
        "name": scenario["name"],
        "plan": pack.meta.get("plan", ""),
        "title": pack.title,
        "reasoning": pack.meta.get("reasoning", ""),
        "student": pack.base_model,
        "not_in_pack": NOT_IN_PACK,
        "cards": [{"title": c["title"], "kind": c["kind"], "why": c.get("why", ""), "facts": c["facts"]}
                  for c in pack.cards],
        "facts": [{"card": ci, "text": pack.cards[ci]["facts"][fi]} for ci, fi in idx.facts],
        "units": [{"fact": idx.fact_pos[(ci, fi)], "text": f"{pack.cards[ci]['title']}: {s}"}
                  for ci, fi, s in idx.units],
        "practice": [{"q": q, "fact": int(f)} for q, f in zip(idx.practice_q, idx.practice_fact)],
        "learned": [{"q": p["q"], "a": p["a"], "card": p["card"], "kind": p["kind"]} for p in pack.pairs],
        "scenes": scenario.get("scenes", []),
        "build": pack.meta.get("build", {}),
    }
    (out / "pack.json").write_text(json.dumps(data, indent=1))

    # Spoken test questions, like a real user talking to the glasses.
    tests = [{**t, "expect": resolve_expect(t["expect"], pack.cards)} for t in scenario.get("tests", [])]
    st = OUT / "selftest" / scenario["id"]
    shutil.rmtree(st, ignore_errors=True)
    st.mkdir(parents=True)
    for i, t in enumerate(tests):
        subprocess.run(["say", "-v", "Samantha", "-r", "175", "-o", str(st / f"{i}.wav"),
                        "--data-format=LEI16@16000", t["q"]], check=True)
    (st / "tests.json").write_text(json.dumps(tests, indent=1))
    return {"id": scenario["id"], "name": scenario["name"], "title": pack.title,
            "pairs": len(pack.pairs), "tests": len(tests)}


def main():
    scenarios = json.loads(SCENARIOS_FILE.read_text())["scenarios"]
    encoder = load_encoder()
    built = {}
    for path in list_packs():  # newest first: the latest build of each scenario wins
        sid = json.loads((path / "pack.json").read_text()).get("scenario")
        if sid and sid not in built:
            built[sid] = path
    missing = [s["id"] for s in scenarios if s["id"] not in built]
    if missing:
        print(f"Not built yet (skipped): {', '.join(missing)}. Build with: uv run python pack.py --scenario ID")
    if not built:
        sys.exit("No scenario packs built.")

    OUT.mkdir(parents=True, exist_ok=True)
    for old in ["model", "pack.json"]:  # single-pack layout from earlier versions
        p = OUT / old
        shutil.rmtree(p) if p.is_dir() else p.unlink(missing_ok=True)
    shutil.rmtree(OUT / "packs", ignore_errors=True)
    shutil.rmtree(OUT / "selftest", ignore_errors=True)

    first = Pack(built[next(s["id"] for s in scenarios if s["id"] in built)], encoder)
    export_base(first.base_model)
    export_embedder()
    index = []
    for s in scenarios:
        if s["id"] in built:
            pack = Pack(built[s["id"]], encoder)
            if pack.base_model != first.base_model:
                print(f"  skipping {s['id']}: trained on {pack.base_model}, app ships {first.base_model}")
                continue
            entry = export_pack(pack, s)
            index.append(entry)
            print(f"✓ {s['name']}: {pack.title} ({entry['pairs']} learned Q&A, {entry['tests']} spoken tests)")
    (OUT / "index.json").write_text(json.dumps(index, indent=1))
    size = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file()) / 1e6
    print(f"✓ ios/Bundle ready: {len(index)} packs, {size:.0f} MB. Next: ios/run.sh")


if __name__ == "__main__":
    main()
