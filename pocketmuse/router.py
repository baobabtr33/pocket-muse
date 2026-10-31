"""Semantic router: embed the prompt, compare to example phrases, pick a route.

LOCAL_EDGE examples are the pack's own practice questions plus small talk; CLOUD examples are
general and live-data questions from data/routes.json. Fails safe toward the cloud: a prompt
only goes local when it is clearly closer to the pack than to the cloud examples.
"""

import json
from dataclasses import dataclass

from sentence_transformers import SentenceTransformer

from .config import EMBED_MODEL, ROUTES_FILE, strip_wake

LOCAL, CLOUD = "LOCAL_EDGE", "CLOUD"


def load_encoder() -> SentenceTransformer:
    return SentenceTransformer(EMBED_MODEL, device="cpu")


@dataclass
class Decision:
    route: str
    local_score: float
    cloud_score: float
    nearest: str


class Router:
    def __init__(self, encoder, local_examples: list[str], threshold: float = 0.70, margin: float = 0.08):
        self.threshold, self.margin, self.encoder = threshold, margin, encoder
        routes = json.loads(ROUTES_FILE.read_text())
        self.examples = {LOCAL: routes[LOCAL] + local_examples, CLOUD: routes[CLOUD]}
        self.vectors = {k: encoder.encode(v, normalize_embeddings=True) for k, v in self.examples.items()}

    def route(self, prompt: str) -> Decision:
        q = self.encoder.encode([strip_wake(prompt)], normalize_embeddings=True)[0]
        local_sims, cloud_sims = self.vectors[LOCAL] @ q, self.vectors[CLOUD] @ q
        local_score, cloud_score = float(local_sims.max()), float(cloud_sims.max())
        if local_score >= self.threshold and local_score >= cloud_score + self.margin:
            return Decision(LOCAL, local_score, cloud_score, self.examples[LOCAL][int(local_sims.argmax())])
        return Decision(CLOUD, local_score, cloud_score, self.examples[CLOUD][int(cloud_sims.argmax())])
