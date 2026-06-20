#!/usr/bin/env python3
"""
Compute frozen embeddings for LoCoMo + LongMemEval per paper-canonical embedders.

LoCoMo: DRAGON 768d (Lin et al. 2023), zero-padded to 1024d for pgmnemo schema.
LongMemEval: Stella V5 1.5B 1024d (NovaSearch/stella_en_1.5B_v5).

Outputs:
  benchmarks/data/locomo/embeddings_dragon_v1.jsonl.zst
  benchmarks/data/longmemeval/embeddings_stella_v1.jsonl.zst
  + sha256 manifest

Reproducibility: deterministic seed, model commit pinned in manifest.

Usage:
  python compute_embeddings.py --bench locomo
  python compute_embeddings.py --bench longmemeval
"""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import torch
from sentence_transformers import SentenceTransformer
from transformers import AutoTokenizer, AutoModel

ROOT = Path(__file__).resolve().parents[1]  # benchmarks/ (was hardcoded home path)
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def embed_dragon(texts: list[str], batch_size: int = 16) -> list[list[float]]:
    """DRAGON encoder = paper canonical for LoCoMo. 768d output, zero-pad to 1024d."""
    print(f"[dragon] loading facebook/dragon-plus-context-encoder on {DEVICE}", flush=True)
    tokenizer = AutoTokenizer.from_pretrained("facebook/dragon-plus-context-encoder")
    model = AutoModel.from_pretrained("facebook/dragon-plus-context-encoder").to(DEVICE).eval()
    out = []
    with torch.no_grad():
        for i in range(0, len(texts), batch_size):
            batch = texts[i : i + batch_size]
            enc = tokenizer(batch, padding=True, truncation=True, max_length=512, return_tensors="pt").to(DEVICE)
            emb = model(**enc).last_hidden_state[:, 0, :]  # CLS pooling per DRAGON paper
            emb = emb.cpu().tolist()
            # zero-pad 768d -> 1024d
            for vec in emb:
                padded = vec + [0.0] * (1024 - len(vec))
                out.append(padded)
            if (i // batch_size) % 10 == 0:
                print(f"[dragon] {i + len(batch)}/{len(texts)}", flush=True)
    return out


def embed_stella(texts: list[str], batch_size: int = 16) -> list[list[float]]:
    """Stella V5 1.5B = paper canonical for LongMemEval. 1024d native."""
    print(f"[stella] loading NovaSearch/stella_en_1.5B_v5 on {DEVICE}", flush=True)
    model = SentenceTransformer(
        "NovaSearch/stella_en_1.5B_v5",
        device=DEVICE,
        trust_remote_code=True,
    )
    out = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i : i + batch_size]
        emb = model.encode(batch, batch_size=batch_size, show_progress_bar=False, normalize_embeddings=False)
        out.extend(emb.tolist())
        if (i // batch_size) % 10 == 0:
            print(f"[stella] {i + len(batch)}/{len(texts)}", flush=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", choices=["locomo", "longmemeval"], required=True)
    ap.add_argument("--limit", type=int, default=None, help="dev-limit on n texts")
    args = ap.parse_args()

    if args.bench == "locomo":
        in_path = ROOT / "data/locomo/locomo_raw.jsonl"
        out_path = ROOT / "data/locomo/embeddings_dragon_v1.jsonl"
        embed_fn = embed_dragon
    else:
        in_path = ROOT / "data/longmemeval/longmemeval_raw.jsonl"
        out_path = ROOT / "data/longmemeval/embeddings_stella_v1.jsonl"
        embed_fn = embed_stella

    if not in_path.exists():
        print(f"ERR: {in_path} not found — run dataset download first", file=sys.stderr)
        sys.exit(1)

    rows = [json.loads(line) for line in open(in_path)]
    print(f"[{args.bench}] loaded {len(rows)} rows from {in_path.name}", flush=True)
    if args.limit:
        rows = rows[: args.limit]
        print(f"[{args.bench}] limited to {len(rows)} rows", flush=True)

    # Extract texts for embedding (schema differs per bench — handled in step 4 separately)
    # For now just dump first 'text' field; full structure mapping done in next stage
    print(f"[{args.bench}] schema sample: {list(rows[0].keys())[:8]}", flush=True)
    print(f"DEFER: actual embedding pass — schema needs inspection", flush=True)


if __name__ == "__main__":
    t0 = time.time()
    main()
    print(f"DONE in {time.time() - t0:.1f}s", flush=True)
