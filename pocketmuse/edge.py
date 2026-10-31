"""Pocket Muse: the small student model plus a pack's LoRA adapter, running on-device with MLX."""

from datetime import date

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

from .config import STUDENT_BASE_MODEL, student_system_prompt


class EdgeModel:
    def __init__(self, pack=None, base: bool = False):
        """base=True loads the untuned student without the pack adapter, for comparison."""
        self.pack = pack
        if base or pack is None:
            self.model, self.tokenizer = load(STUDENT_BASE_MODEL)
        elif (pack.path / "fused").exists():  # adapter merged into the weights: ~2x faster generation
            self.model, self.tokenizer = load(str(pack.path / "fused"))
        else:
            self.model, self.tokenizer = load(STUDENT_BASE_MODEL, adapter_path=str(pack.adapter))
        self.sampler = make_sampler(temp=0.0)  # greedy: same answer every run
        self.answer("hello")  # warm up so the first demo question is fast

    def answer(self, question: str, notes: str | None = None, max_tokens: int = 120) -> str:
        """notes=None retrieves from the pack; notes="" gives the model no notes at all."""
        title = self.pack.title if self.pack else "your trip"
        if notes is None:
            notes = self.pack.notes_for(question) if self.pack else ""
        system = student_system_prompt(title, date.today().strftime("%A, %B %-d"), notes or "(none)")
        chat = self.tokenizer.apply_chat_template(
            [{"role": "system", "content": system}, {"role": "user", "content": question}],
            add_generation_prompt=True,
            tokenize=False,
        )
        return generate(self.model, self.tokenizer, chat, max_tokens=max_tokens, sampler=self.sampler).strip()
