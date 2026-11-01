"""Export a built pack for the iOS app.

  uv run python export_ios.py              # latest pack
  uv run python export_ios.py --pack NAME
  uv run python export_ios.py --bits 4     # smaller download, slightly less accurate (default 8)

Writes ios/Bundle/ (gitignored), which the Xcode project ships inside the app:
  model/     the pack's fused Llama student, quantized for the phone
  embedder/  bge-small, for the same fact retrieval the student was trained with
  pack.json  title, cards, retrieval units, practice-question votes, demo scenes
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

from pocketmuse.config import DEMO_FILE, EMBED_MODEL, NOT_IN_PACK, ROOT
from pocketmuse.pack import SENTENCE, Pack, resolve
from pocketmuse.router import load_encoder

OUT = ROOT / "ios" / "Bundle"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack")
    ap.add_argument("--bits", type=int, default=8, choices=[4, 8])
    args = ap.parse_args()

    pack = Pack(resolve(args.pack), load_encoder())
    fused = pack.path / "fused"
    if not fused.exists():
        sys.exit(f"{pack.path.name} has no fused model. Run: uv run python pack.py --retrain {pack.path.name}")
    OUT.mkdir(parents=True, exist_ok=True)

    model_dir = OUT / "model"
    shutil.rmtree(model_dir, ignore_errors=True)
    print(f"Quantizing {pack.path.name} to {args.bits}-bit ...")
    subprocess.run(
        [sys.executable, "-m", "mlx_lm", "convert", "--hf-path", str(fused), "--mlx-path", str(model_dir),
         "-q", "--q-bits", str(args.bits)],
        check=True,
    )

    emb_dir = OUT / "embedder"
    shutil.rmtree(emb_dir, ignore_errors=True)
    src = Path(snapshot_download(EMBED_MODEL))
    emb_dir.mkdir()
    for name in ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
                 "special_tokens_map.json", "vocab.txt"]:
        shutil.copy(src / name, emb_dir / name)
    (emb_dir / "1_Pooling").mkdir()
    shutil.copy(src / "1_Pooling" / "config.json", emb_dir / "1_Pooling" / "config.json")

    # Same retrieval as pocketmuse.pack.FactIndex. The phone embeds the units and practice questions itself
    # at launch (so query and fact vectors come from the same embedder); the discrete parts are exported here.
    idx = pack.index
    facts = [
        {"card": ci, "text": pack.cards[ci]["facts"][fi]} for ci, fi in idx.facts
    ]
    units = [
        {"fact": idx.fact_pos[(ci, fi)], "text": f"{pack.cards[ci]['title']}: {sent}"} for ci, fi, sent in idx.units
    ]
    practice = [{"q": q, "fact": int(f)} for q, f in zip(idx.practice_q, idx.practice_fact)] if idx.practice_q else []
    demo = json.loads(DEMO_FILE.read_text())
    data = {
        "name": pack.path.name,
        "title": pack.title,
        "student": pack.base_model,
        "bits": args.bits,
        "not_in_pack": NOT_IN_PACK,
        "sentence_split": SENTENCE.pattern,
        "cards": [{"title": c["title"], "kind": c["kind"]} for c in pack.cards],
        "facts": facts,
        "units": units,
        "practice": practice,
        "scenes": demo.get("scenes", []),
        "build": pack.meta.get("build", {}),
    }
    (OUT / "pack.json").write_text(json.dumps(data, indent=1))
    size = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file()) / 1e6
    print(f"✓ ios/Bundle ready: {len(facts)} facts, {len(units)} units, {len(practice)} practice votes, {size:.0f} MB")
    print("  Next: open ios/PocketMuse.xcodeproj (or run ios/run.sh) and build to your iPhone.")


if __name__ == "__main__":
    main()
