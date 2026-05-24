#!/usr/bin/env python3
"""
run_v062_sparse_safe_bench.py — LongMemEval bench for v0.6.2 sparse-safe RRF.

Compares:
  - baseline: ORDER BY fusion_score (vec_w * cosine + bm25_w * bm25_score) — v0.5.1/v0.6.0
  - v062_fix_a: ORDER BY rrf_sparse (sparse-safe RRF, Cormack 2009)

Sparse-safe RRF:
  Items with bm25_score > 0 get RANK() among BM25-matching items.
  Items with bm25_score = 0 get sentinel = n_candidates + 1 (excluded from BM25 list).
  This eliminates the arbitrary ROW_NUMBER() tie-break on tied zero-scores that
  caused -22.44pp regression in v0.6.1 A-scale.

Uses pre-computed bge-m3 embeddings (1024d, same cache as v0.6.1 bench).
Gate: recall@10(fix_a) >= recall@10(baseline) + 0.01  AND  p_corr < 0.05

Usage:
    python3 benchmarks/scripts/run_v062_sparse_safe_bench.py
    python3 benchmarks/scripts/run_v062_sparse_safe_bench.py --out-dir benchmarks/longmemeval/results/v062_sparse_safe
    python3 benchmarks/scripts/run_v062_sparse_safe_bench.py --limit 100  # quick smoke
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import re
import sys
import time
from pathlib import Path

import numpy as np

try:
    import ijson
except ImportError:
    print("ERROR: pip install ijson")
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = ROOT / ".embed_cache"
DATA_DIR = ROOT / "data" / "longmemeval"

VEC_WEIGHT   = 0.4
BM25_WEIGHT  = 0.4
RRF_K        = 60.0
AUX_SCALE    = (0.8 / 61.0) / 0.76   # 0.01726 — same as v0.6.1

BM25_K1, BM25_B = 1.5, 0.75
K_VALUES = [1, 5, 10, 20]
TRUNCATE_CHARS = 8000


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", str(text).lower())


class BM25:
    def __init__(self, docs: list[list[str]]):
        self.n = len(docs)
        self.avgdl = sum(len(d) for d in docs) / max(1, self.n)
        self.df: dict[str, int] = collections.Counter()
        self.tf: list[dict[str, int]] = []
        for doc in docs:
            f = collections.Counter(doc)
            self.tf.append(f)
            for t in set(doc):
                self.df[t] += 1

    def score(self, qtoks: list[str], di: int) -> float:
        dl = sum(self.tf[di].values())
        sc = 0.0
        for t in qtoks:
            if t not in self.df:
                continue
            idf = math.log((self.n - self.df[t] + 0.5) / (self.df[t] + 0.5) + 1)
            tf = self.tf[di].get(t, 0)
            sc += idf * tf * (BM25_K1 + 1) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / self.avgdl))
        return sc

    def scores_all(self, qtoks: list[str]) -> list[float]:
        return [self.score(qtoks, di) for di in range(self.n)]


def sess2text(s) -> str:
    if isinstance(s, str):
        return s
    if isinstance(s, list):
        return "\n".join(
            (f"{t.get('role','')}: {t.get('content','')}" if isinstance(t, dict) else str(t))
            for t in s
        )
    return json.dumps(s)


def cosine_sim(q_vec: np.ndarray, corpus_mat: np.ndarray) -> np.ndarray:
    q_norm = np.linalg.norm(q_vec)
    if q_norm < 1e-9:
        return np.zeros(len(corpus_mat))
    norms = np.linalg.norm(corpus_mat, axis=1)
    norms = np.where(norms < 1e-9, 1e-9, norms)
    return (corpus_mat @ q_vec) / (norms * q_norm)


def _agg(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "mean": None, "ci95_lo": None, "ci95_hi": None}
    n = len(values)
    mean = sum(values) / n
    if n > 1:
        var = sum((v - mean) ** 2 for v in values) / (n - 1)
        ci_half = 1.96 * (var / n) ** 0.5
    else:
        ci_half = 0.0
    return {
        "n": n,
        "mean": round(mean, 4),
        "ci95_lo": round(max(0.0, mean - ci_half), 4),
        "ci95_hi": round(min(1.0, mean + ci_half), 4),
    }


def paired_ttest(a: list[float], b: list[float]) -> float:
    """Two-tailed paired t-test on (a - b). Returns p-value."""
    diffs = [x - y for x, y in zip(a, b)]
    n = len(diffs)
    if n < 2:
        return 1.0
    mean_d = sum(diffs) / n
    var_d = sum((d - mean_d) ** 2 for d in diffs) / (n - 1)
    se = (var_d / n) ** 0.5
    if se < 1e-15:
        return 1.0 if abs(mean_d) < 1e-15 else 0.0
    t_stat = mean_d / se
    z = abs(t_stat)
    p_two_tailed = math.erfc(z / math.sqrt(2.0))
    return p_two_tailed


def compute_bm25_rank_sparse(bm25_norm: np.ndarray) -> np.ndarray:
    """
    Compute sparse-safe BM25 ranks (v0.6.2 Fix-A).

    Items with bm25_norm > 0: RANK() among BM25-matching items (1-indexed, ties same rank).
    Items with bm25_norm = 0: sentinel = n_candidates + 1.

    Mirrors SQL:
        CASE WHEN raw_bm25_score > 0
             THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0) ORDER BY raw_bm25_score DESC)
             ELSE NULL
        END  → COALESCE(NULL, n_candidates + 1)
    """
    n = len(bm25_norm)
    sentinel = float(n + 1)
    result = np.full(n, sentinel, dtype=np.float64)

    has_bm25 = bm25_norm > 0.0
    if not has_bm25.any():
        return result  # all sentinel

    matching_idx = np.where(has_bm25)[0]
    matching_scores = bm25_norm[matching_idx]

    # RANK() DESC with ties: compute via unique sorted values
    # RANK() assigns the same rank to tied values (lowest position in sorted order)
    unique_sorted_desc = np.sort(np.unique(matching_scores))[::-1]
    score_to_rank = {float(s): i + 1 for i, s in enumerate(unique_sorted_desc)}

    for local_i, global_i in enumerate(matching_idx):
        result[global_i] = float(score_to_rank[float(matching_scores[local_i])])

    return result


def compute_vec_rank(vec_scores: np.ndarray) -> np.ndarray:
    """ROW_NUMBER() OVER (ORDER BY vec_score DESC) — 1-indexed."""
    order = np.argsort(-vec_scores, kind="stable")
    rank = np.empty(len(vec_scores), dtype=np.float64)
    rank[order] = np.arange(1, len(vec_scores) + 1, dtype=np.float64)
    return rank


def load_seg_embeddings() -> np.ndarray:
    cache_file = CACHE_DIR / "lme_segs_bge-m3_max512_trunc8000__fe6c6f0d670bfd85.npz"
    if not cache_file.exists():
        raise FileNotFoundError(f"Cache file not found: {cache_file}")
    data = np.load(cache_file)
    embs = data["embeddings"]
    print(f"[cache] loaded seg embeddings: {embs.shape}", flush=True)
    return embs


def load_qry_embeddings() -> np.ndarray:
    cache_file = CACHE_DIR / "lme_qry_bge-m3_max512__6169edeaf24009f7.npz"
    if not cache_file.exists():
        raise FileNotFoundError(f"Cache file not found: {cache_file}")
    data = np.load(cache_file)
    embs = data["embeddings"]
    print(f"[cache] loaded qry embeddings: {embs.shape}", flush=True)
    return embs


def topk_hits(scores: np.ndarray, sids: list, ans_ids: set, k: int) -> float:
    top_idx = np.argsort(-scores)[:k]
    top_sids = {sids[i] if i < len(sids) else f"idx_{i}" for i in top_idx}
    return len(top_sids & ans_ids) / len(ans_ids)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()

    t0 = time.time()

    data_path = DATA_DIR / "longmemeval_s_cleaned.json"
    if not data_path.exists():
        print(f"ERROR: {data_path} not found", file=sys.stderr)
        sys.exit(1)

    seg_embs = load_seg_embeddings()
    qry_embs = load_qry_embeddings()

    print(f"[bench] v0.6.2 sparse-safe RRF bench — {data_path.name}", flush=True)
    print(f"[bench] VEC_WEIGHT={VEC_WEIGHT} BM25_WEIGHT={BM25_WEIGHT} RRF_K={RRF_K}", flush=True)

    # Per-instance recall@10 for paired t-test
    recall10_baseline: list[float] = []
    recall10_fix_a:    list[float] = []

    overall_baseline = {k: [] for k in K_VALUES}
    overall_fix_a    = {k: [] for k in K_VALUES}

    seg_offset = 0
    qi = 0

    with open(data_path, "rb") as f:
        for inst in ijson.items(f, "item"):
            if args.limit and qi >= args.limit:
                break

            sessions = inst.get("haystack_sessions", [])
            sids     = inst.get("haystack_session_ids", [])
            ans_ids  = set(inst.get("answer_session_ids", []))
            question = inst.get("question", "")

            n_segs = len(sessions)
            if not sessions or not ans_ids:
                seg_offset += n_segs
                qi += 1
                continue

            # Texts + BM25
            texts = [sess2text(s)[:TRUNCATE_CHARS] for s in sessions]
            dtoks = [tokenize(t) for t in texts]
            qtoks = tokenize(question)

            bm25_obj = BM25(dtoks)
            bm25_raw = np.array(bm25_obj.scores_all(qtoks), dtype=np.float64)
            max_bm25 = float(bm25_raw.max()) if bm25_raw.max() > 0 else 1.0
            bm25_norm = bm25_raw / max_bm25  # normalize to [0, 1]

            # Vector cosine from cached bge-m3
            q_vec = qry_embs[qi].astype(np.float64)
            c_mat = seg_embs[seg_offset:seg_offset + n_segs].astype(np.float64)
            vec_scores = cosine_sim(q_vec, c_mat)

            # ── Baseline: fusion_score = vec_w * cosine + bm25_w * bm25_norm ──
            baseline_scores = VEC_WEIGHT * vec_scores + BM25_WEIGHT * bm25_norm

            # ── v0.6.2 Fix-A: sparse-safe RRF ──
            vec_rank = compute_vec_rank(vec_scores)
            bm25_rank_sparse = compute_bm25_rank_sparse(bm25_norm)

            rrf_sparse = (
                VEC_WEIGHT  / (RRF_K + vec_rank) +
                BM25_WEIGHT / (RRF_K + bm25_rank_sparse)
            )

            # Add aux tiebreaker (AUX_SCALE × uniform proxies; adds constant to all → no ordering effect)
            # Included for completeness — does not change ordering when metadata is uniform.
            # (all bench items have same recency/importance/provenance)

            # Evaluate
            for K in K_VALUES:
                overall_baseline[K].append(topk_hits(baseline_scores, sids, ans_ids, K))
                overall_fix_a[K].append(topk_hits(rrf_sparse, sids, ans_ids, K))

            recall10_baseline.append(overall_baseline[10][-1])
            recall10_fix_a.append(overall_fix_a[10][-1])

            seg_offset += n_segs
            qi += 1

            if qi % 100 == 0:
                rb = sum(recall10_baseline) / len(recall10_baseline)
                rf = sum(recall10_fix_a) / len(recall10_fix_a)
                print(f"[bench] {qi}/{args.limit or 500} | R@10 baseline={rb:.4f} fix_a={rf:.4f}", flush=True)

    elapsed = time.time() - t0
    n_eval = len(recall10_baseline)
    print(f"\n[bench] done: {n_eval} instances in {elapsed:.1f}s", flush=True)

    metrics_baseline = {f"recall@{k}": _agg(overall_baseline[k]) for k in K_VALUES}
    metrics_fix_a    = {f"recall@{k}": _agg(overall_fix_a[k]) for k in K_VALUES}

    r10_base = metrics_baseline["recall@10"]["mean"] or 0.0
    r10_fixa = metrics_fix_a["recall@10"]["mean"] or 0.0
    delta    = r10_fixa - r10_base
    p_val    = paired_ttest(recall10_fix_a, recall10_baseline)

    gate_delta  = delta >= 0.01
    gate_pval   = p_val < 0.05
    gate_passed = gate_delta and gate_pval

    print(f"\n{'='*60}")
    print(f"BASELINE   recall@10 = {r10_base:.4f}")
    print(f"v0.6.2 F-A recall@10 = {r10_fixa:.4f}")
    print(f"Delta      recall@10 = {delta:+.4f}  (gate: ≥+0.01)")
    print(f"p-value  (paired t)  = {p_val:.6f}  (gate: < 0.05)")
    print(f"GATE: {'PASS ✓' if gate_passed else 'FAIL ✗'}")
    print(f"{'='*60}")

    out_dir = Path(args.out_dir) if args.out_dir else (
        ROOT / "longmemeval" / "results" / "v062_sparse_safe"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    dataset_sha = hashlib.sha256(
        open(data_path, "rb").read(65536)
    ).hexdigest()[:16]

    result = {
        "version": "v0.6.2",
        "run_label": "v062_sparse_safe_rrf",
        "date": time.strftime("%Y-%m-%d"),
        "mode": "cached_embeddings",
        "simulation": False,
        "embedder": "bge-m3 (1024d, pre-computed cache, same as v0.6.1 bench)",
        "dataset": "longmemeval_s_cleaned.json",
        "dataset_sha256_partial": dataset_sha,
        "n_instances": n_eval,
        "wall_clock_sec": round(elapsed, 1),
        "vec_weight": VEC_WEIGHT,
        "bm25_weight": BM25_WEIGHT,
        "rrf_k": RRF_K,
        "fix_a_description": "sparse-safe RRF (Cormack 2009): PARTITION BY (bm25>0), sentinel=n+1",
        "baseline": {
            "order_by": "fusion_score = vec_w*cosine + bm25_w*bm25_score",
            "metrics": metrics_baseline,
            "recall@10": r10_base,
        },
        "fix_a": {
            "order_by": "rrf_sparse = vec_w/(k+vec_rank) + bm25_w/(k+bm25_rank_sparse_or_sentinel)",
            "metrics": metrics_fix_a,
            "recall@10": r10_fixa,
        },
        "delta_recall@10": round(delta, 4),
        "p_value_paired_t": round(p_val, 6),
        "gate": {
            "delta_ge_1pp": gate_delta,
            "pval_lt_005": gate_pval,
            "passed": gate_passed,
        },
    }

    out_file = out_dir / "metrics.json"
    out_file.write_text(json.dumps(result, indent=2))
    print(f"\n[bench] results written to {out_file}", flush=True)

    if not gate_passed:
        print("\n⚠  GATE FAILED — do not ship v0.6.2 Fix-A, try fallback", flush=True)
        sys.exit(1)
    else:
        print("\n✓  GATE PASSED — v0.6.2 sparse-safe RRF validated", flush=True)
        sys.exit(0)


if __name__ == "__main__":
    main()
