"""LoRA-train the student on a pack's dataset with mlx-lm. The adapter is the pack.

Lessons (Qwen2.5-0.5B, first student): lr 1e-4 (batch 8) and 5e-5 (batch 4) diverged around step 100 into
garbage; 2e-5 was stable.
"""

import re
import subprocess
import sys
from pathlib import Path



def train(pack_dir: Path, base: str, iters: int = 200, lr: float = 2e-5, on_iter=None) -> None:
    cmd = [
        sys.executable, "-m", "mlx_lm", "lora",
        "--model", base,
        "--train",
        "--data", str(pack_dir / "dataset"),
        "--fine-tune-type", "lora",
        "--num-layers", "-1",
        "--batch-size", "4",  # batch 8 was ~2x slower per step with these long prompts
        "--iters", str(iters),
        "--learning-rate", str(lr),
        "--mask-prompt",
        "--max-seq-length", "1024",
        "--steps-per-report", "5",
        "--steps-per-eval", str(iters),
        "--save-every", str(iters),
        "--adapter-path", str(pack_dir / "adapters"),
        "--seed", "0",
    ]
    log = open(pack_dir / "train.log", "w")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    for line in proc.stdout:
        log.write(line)
        plain = re.sub(r"\x1b\[[0-9;]*m", "", line)
        m = re.match(r"\s*(\d+)\s+([\d.]+)\s", plain)
        if m and on_iter:
            on_iter(int(m.group(1)), float(m.group(2)))
    log.close()
    if proc.wait() != 0:
        raise RuntimeError(f"training failed, see {pack_dir / 'train.log'}")


def fuse(pack_dir: Path, base: str) -> None:
    """Merge the adapter into a standalone model; generation is about 2x faster than adapter-on-the-fly."""
    cmd = [
        sys.executable, "-m", "mlx_lm", "fuse",
        "--model", base,
        "--adapter-path", str(pack_dir / "adapters"),
        "--save-path", str(pack_dir / "fused"),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
