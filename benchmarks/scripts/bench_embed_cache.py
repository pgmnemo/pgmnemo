"""
Tiny embedding cache for benchmark scripts.

Embeddings are deterministic for (corpus_text, embedder, max_seq_length).
Re-embedding 23867 LongMemEval segments on MPS costs ~50 min every run.
This module caches results to .npz files so subsequent runs are ~3 min.

Cache key: SHA-256 of (concatenated text || model_id || max_seq_length).
Cache layout: benchmarks/.embed_cache/<key>.npz containing one array 'embeddings'.

Usage:
    from bench_embed_cache import embed_with_cache

    seg_embs = embed_with_cache(
        texts=[...],
        encode_fn=lambda t: model.encode(t, batch_size=16, show_progress_bar=True),
        cache_id="lme_segs_bge-m3_max512",
    )

Invalidate manually by deleting .npz files, or by changing cache_id.
"""
from __future__ import annotations
import hashlib
import os
import time
from pathlib import Path

import numpy as np


def _cache_root() -> Path:
    # benchmarks/.embed_cache/ next to scripts/, NOT inside scripts/
    here = Path(__file__).resolve().parent  # benchmarks/scripts
    root = here.parent / ".embed_cache"
    root.mkdir(exist_ok=True)
    return root


def _key(texts: list[str], cache_id: str) -> str:
    h = hashlib.sha256()
    h.update(cache_id.encode("utf-8"))
    h.update(b"\x00")
    h.update(f"n={len(texts)}".encode("utf-8"))
    h.update(b"\x00")
    # Sample first 200 + last 200 char prefixes per text — keeps key derivation
    # O(n) but fast for 25K texts; uniqueness preserved because cache_id includes
    # model + truncation settings
    for t in texts:
        h.update((t[:200] + "\x00" + t[-200:]).encode("utf-8", errors="ignore"))
        h.update(b"\x01")
    return h.hexdigest()[:16]


def embed_with_cache(texts: list[str], encode_fn, cache_id: str, *, force_recompute: bool = False) -> np.ndarray:
    """
    Embed `texts` via `encode_fn`, caching the result on disk.

    Args:
        texts: list of strings to embed
        encode_fn: callable taking list[str] → np.ndarray (N, D)
        cache_id: stable identifier including model + key params
                  (e.g. "lme_segs_bge-m3_max512")
        force_recompute: if True, bypass cache and overwrite

    Returns:
        np.ndarray (N, D), dtype float32
    """
    key = _key(texts, cache_id)
    cache_file = _cache_root() / f"{cache_id}__{key}.npz"

    if cache_file.exists() and not force_recompute:
        t0 = time.time()
        data = np.load(cache_file)
        embs = data["embeddings"]
        if embs.shape[0] != len(texts):
            print(f"[embed-cache] STALE: {cache_file.name} has {embs.shape[0]} rows but texts has {len(texts)} — recomputing")
        else:
            print(f"[embed-cache] HIT  {cache_file.name} ({embs.shape[0]} × {embs.shape[1]}d, loaded in {time.time()-t0:.2f}s)")
            return embs

    t0 = time.time()
    print(f"[embed-cache] MISS {cache_file.name} — computing {len(texts)} embeddings...")
    embs = encode_fn(texts)
    if not isinstance(embs, np.ndarray):
        embs = np.asarray(embs)
    if embs.dtype != np.float32:
        embs = embs.astype(np.float32)
    np.savez_compressed(cache_file, embeddings=embs)
    print(f"[embed-cache] SAVE {cache_file.name} ({embs.shape[0]} × {embs.shape[1]}d, computed+saved in {time.time()-t0:.1f}s, {cache_file.stat().st_size / 1024 / 1024:.1f} MB)")
    return embs


def clear_cache(cache_id: str | None = None) -> int:
    """Delete cache files. If cache_id given, only matching files. Returns count."""
    root = _cache_root()
    pattern = f"{cache_id}__*.npz" if cache_id else "*.npz"
    files = list(root.glob(pattern))
    for f in files:
        f.unlink()
    return len(files)


if __name__ == "__main__":
    # CLI: clear cache or list contents
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "clear":
        n = clear_cache(sys.argv[2] if len(sys.argv) > 2 else None)
        print(f"cleared {n} cache files")
    else:
        root = _cache_root()
        files = sorted(root.glob("*.npz"))
        total = sum(f.stat().st_size for f in files)
        print(f"Embed cache at {root}:")
        for f in files:
            print(f"  {f.stat().st_size / 1024 / 1024:6.1f} MB  {f.name}")
        print(f"Total: {len(files)} files, {total / 1024 / 1024:.1f} MB")
