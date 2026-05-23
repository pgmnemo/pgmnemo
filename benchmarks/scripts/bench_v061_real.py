#!/usr/bin/env python3
"""
pgmnemo v0.6.1 real-DB LongMemEval benchmark — headline gate evaluation.

Uses pre-computed bge-m3 embeddings from .embed_cache/ (no sentence_transformers needed).
Compares v0.6.1 recall_hybrid() (ORDER BY rrf_diag) vs v0.4.0 baseline (ORDER BY fusion_score).

Gate criteria:
  1. recall@10_v061 >= recall@10_v051 + 0.01  (≥+1pp)
  2. paired t-test p < 0.05  (statistically significant)
  3. LoCoMo recall@10 >= 0.7994  (separate, checked via locomo bench)

Usage:
    python3 bench_v061_real.py [--limit N] [--out-dir PATH]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import psycopg2
import psycopg2.extras

ROOT = Path(__file__).resolve().parent.parent  # benchmarks/
CACHE_DIR = ROOT / ".embed_cache"
DATA_DIR  = ROOT / "data" / "longmemeval"


# ─── Embed cache (load-only, no re-compute) ──────────────────────────────────

def _cache_key(texts: list[str], cache_id: str) -> str:
    h = hashlib.sha256()
    h.update(cache_id.encode("utf-8"))
    h.update(b"\x00")
    h.update(f"n={len(texts)}".encode("utf-8"))
    h.update(b"\x00")
    for t in texts:
        h.update((t[:200] + "\x00" + t[-200:]).encode("utf-8", errors="ignore"))
        h.update(b"\x01")
    return h.hexdigest()[:16]


def load_cached_embeddings(texts: list[str], cache_id: str) -> np.ndarray | None:
    key   = _cache_key(texts, cache_id)
    fpath = CACHE_DIR / f"{cache_id}__{key}.npz"
    if not fpath.exists():
        print(f"[cache] MISS: {fpath.name}")
        return None
    data = np.load(fpath)
    embs = data["embeddings"]
    if embs.shape[0] != len(texts):
        print(f"[cache] STALE: {fpath.name} — {embs.shape[0]} rows vs {len(texts)} texts")
        return None
    print(f"[cache] HIT  {fpath.name}  shape={embs.shape}")
    return embs


# ─── Dataset ──────────────────────────────────────────────────────────────────

def load_dataset() -> tuple[list, str]:
    for candidate in ["longmemeval_s_cleaned.json", "longmemeval_oracle.json"]:
        p = DATA_DIR / candidate
        if p.exists():
            return json.load(open(p)), candidate
    raise FileNotFoundError(f"No LongMemEval dataset in {DATA_DIR}")


def extract_items(data: list) -> list[dict]:
    items = []
    for entry in data:
        haystack_sessions    = entry.get("haystack_sessions", [])
        haystack_session_ids = entry.get("haystack_session_ids", [])
        answer_session_ids   = entry.get("answer_session_ids", [])
        corpus = []
        for sid, session in zip(haystack_session_ids, haystack_sessions):
            if isinstance(session, list):
                txt = "\n".join(
                    f"{t.get('role','')}: {t.get('content','')}" if isinstance(t, dict) else str(t)
                    for t in session
                )
            else:
                txt = str(session)
            corpus.append({"sid": sid, "text": txt})
        items.append({
            "qid":          entry.get("question_id"),
            "qtype":        entry.get("question_type"),
            "question":     entry.get("question"),
            "corpus":       corpus,
            "ground_truth": set(answer_session_ids),
        })
    return items


# ─── Stats helpers ────────────────────────────────────────────────────────────

def _agg(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "mean": None, "ci95_lo": None, "ci95_hi": None}
    n    = len(values)
    mean = sum(values) / n
    if n > 1:
        var     = sum((v - mean) ** 2 for v in values) / (n - 1)
        ci_half = 1.96 * (var / n) ** 0.5
    else:
        ci_half = 0.0
    return {
        "n":      n,
        "mean":   round(mean, 4),
        "ci95_lo": round(max(0.0, mean - ci_half), 4),
        "ci95_hi": round(min(1.0, mean + ci_half), 4),
    }


def _normal_cdf(x: float) -> float:
    """Cumulative standard normal CDF via Abramowitz & Stegun approximation."""
    neg = x < 0
    x = abs(x)
    t   = 1.0 / (1.0 + 0.2316419 * x)
    poly = t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))))
    pdf  = math.exp(-0.5 * x * x) / math.sqrt(2 * math.pi)
    cdf  = 1.0 - pdf * poly
    return 1.0 - cdf if neg else cdf


def paired_ttest_p(a: list[float], b: list[float]) -> float:
    """Two-tailed p-value for paired t-test (a vs b). Large-sample normal approx."""
    diffs = [ai - bi for ai, bi in zip(a, b)]
    n     = len(diffs)
    if n < 2:
        return 1.0
    mean_d = sum(diffs) / n
    var_d  = sum((d - mean_d) ** 2 for d in diffs) / (n - 1)
    se     = math.sqrt(var_d / n)
    if se < 1e-12:
        return 0.0 if mean_d != 0 else 1.0
    t = mean_d / se
    # Large-sample: use normal approximation (n=500 >> 30)
    p_one_tail = 1.0 - _normal_cdf(abs(t))
    return 2.0 * p_one_tail


def vec_to_pgvector(vec: np.ndarray) -> str:
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"


# ─── Benchmark run ────────────────────────────────────────────────────────────

def run_benchmark(args) -> dict:
    t_start = time.time()

    # Load dataset ONCE (single load — full JSON is ~2.4 GB in memory)
    print("[lme] loading dataset (large JSON)...", flush=True)
    raw, dataset_file = load_dataset()
    all_items_list = extract_items(raw)
    del raw  # free raw JSON ASAP

    # Determine which items to bench (apply limit)
    bench_items = all_items_list[: args.limit] if args.limit else all_items_list
    bench_ii_set = {ii for ii, item in enumerate(bench_items)
                    if item["ground_truth"] and item["corpus"]}
    print(f"[lme] {len(bench_items)} items selected, qtypes: {Counter(i['qtype'] for i in bench_items)}")

    # Build flat text lists from FULL dataset (cache key covers all items)
    all_segs_full: list[tuple[int, int, str, str]] = []  # (item_idx, seg_idx, sid, text)
    queries_full:  list[tuple[int, str]] = []             # (item_idx, question)
    for ii, item in enumerate(all_items_list):
        if not item["ground_truth"] or not item["corpus"]:
            continue
        queries_full.append((ii, item["question"]))
        for si, seg in enumerate(item["corpus"]):
            all_segs_full.append((ii, si, seg["sid"], seg["text"][:8000]))

    print(f"[lme] full corpus: {len(queries_full)} queries, {len(all_segs_full)} segments")

    # Load full cached embeddings (shape matches full corpus text list)
    seg_texts_full = [s[3] for s in all_segs_full]
    qry_texts_full = [q[1] for q in queries_full]

    seg_embs_full = load_cached_embeddings(seg_texts_full, "lme_segs_bge-m3_max512_trunc8000")
    qry_embs_full = load_cached_embeddings(qry_texts_full, "lme_qry_bge-m3_max512")
    del seg_texts_full, qry_texts_full  # free text copies

    if seg_embs_full is None or qry_embs_full is None:
        print("[ERROR] Embedding cache miss — cannot proceed without sentence_transformers")
        sys.exit(2)

    # Build per-item embedding index (only bench_ii_set items)
    item_corpus: dict[int, list[tuple[int, str, np.ndarray]]] = defaultdict(list)
    for (ii, si, sid, _txt), emb in zip(all_segs_full, seg_embs_full):
        if ii in bench_ii_set:
            item_corpus[ii].append((si, sid, emb))
    item_qry: dict[int, np.ndarray] = {
        ii: emb for (ii, _q), emb in zip(queries_full, qry_embs_full)
        if ii in bench_ii_set
    }
    del all_segs_full, seg_embs_full, queries_full, qry_embs_full  # free large arrays

    items = bench_items  # rename for loop below
    print(f"[lme] using {len(item_corpus)} items (limit={args.limit or 'none'})")

    # DB connection
    db_url = os.environ.get("DATABASE_URL", "")
    if not db_url:
        sys.exit("DATABASE_URL not set")
    from urllib.parse import urlparse
    u = urlparse(db_url)

    def _connect():
        c = psycopg2.connect(
            host=u.hostname, port=u.port or 5432,
            user=u.username, password=u.password,
            dbname="pgmnemo_test",
        )
        c.autocommit = False  # explicit transactions for deadlock safety
        return c

    conn = _connect()
    cur = conn.cursor()

    # Verify function
    cur.execute("""
        SELECT pronargs FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
    """)
    row = cur.fetchone()
    if not row:
        conn.rollback(); conn.close()
        sys.exit("[ERROR] pgmnemo.recall_hybrid() not found in pgmnemo_test DB")
    print(f"[db] recall_hybrid({row[0]} args) OK")

    # Truncate bench table
    cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_lme_v061'")
    conn.commit()
    print("[db] bench rows cleared")

    K_VALUES = [1, 5, 10, 20]
    K_MAX    = max(K_VALUES)

    v061_per_item_r10: list[float] = []
    overall_recall    = {k: [] for k in K_VALUES}
    overall_mrr       = []
    per_qtype_recall  = {k: defaultdict(list) for k in K_VALUES}
    per_qtype_mrr     = defaultdict(list)
    raw_retrievals    = []

    print(f"[bench] running {len(items)} items through pgmnemo.recall_hybrid()...")
    t_bench = time.time()

    for ii, item in enumerate(items):
        if ii not in item_corpus:
            continue

        # Per-item: DELETE + INSERT + RECALL in single explicit transaction
        retrieved_rows = []
        for attempt in range(3):
            try:
                cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_lme_v061'")
                for (si, sid, emb) in item_corpus[ii]:
                    seg = item["corpus"][si]
                    cur.execute(
                        """INSERT INTO pgmnemo.agent_lesson
                           (role, project_id, topic, lesson_text, importance, embedding,
                            commit_sha, source_run_id, metadata, verified_at)
                           VALUES ('bench_lme_v061', 1, %s, %s, 3, %s::vector,
                                   'bench_v0.6.1', %s, %s::jsonb, NOW())""",
                        (
                            f"lme/{item['qtype']}",
                            seg["text"][:8000],
                            vec_to_pgvector(emb),
                            f"{item['qid']}_{sid}",
                            json.dumps({"sid": sid}),
                        ),
                    )
                qvec = item_qry[ii]
                cur.execute(
                    """SELECT lesson_id, metadata->>'sid' AS sid
                       FROM pgmnemo.recall_hybrid(
                           %s::vector, %s, %s, 'bench_lme_v061', 1, %s, %s, %s
                       )
                       ORDER BY score DESC LIMIT %s""",
                    (vec_to_pgvector(qvec), item["question"], K_MAX, 0.4, 0.4, 60, K_MAX),
                )
                retrieved_rows = cur.fetchall()
                conn.commit()
                break  # success
            except psycopg2.errors.DeadlockDetected:
                print(f"[bench] deadlock (item {ii}, attempt {attempt+1}), retrying...", flush=True)
                try:
                    conn.rollback()
                except Exception:
                    pass
                time.sleep(1.0 + attempt)
            except Exception as e:
                print(f"[bench] error item {ii} attempt {attempt+1}: {e}", flush=True)
                try:
                    conn.rollback()
                except Exception:
                    pass
                time.sleep(0.5)

        retrieved_sids = [r[1] for r in retrieved_rows]
        gt = item["ground_truth"]

        first_hit = None
        for r, sid in enumerate(retrieved_sids, start=1):
            if sid in gt and first_hit is None:
                first_hit = r
        mrr = 1.0 / first_hit if first_hit else 0.0

        for K in K_VALUES:
            top_k  = set(retrieved_sids[:K])
            hits   = len(top_k & gt)
            recall = hits / len(gt) if gt else 0.0
            overall_recall[K].append(recall)
            per_qtype_recall[K][item["qtype"]].append(recall)

        overall_mrr.append(mrr)
        per_qtype_mrr[item["qtype"]].append(mrr)

        r10 = (len(set(retrieved_sids[:10]) & gt) / len(gt)) if gt else 0.0
        v061_per_item_r10.append(r10)

        raw_retrievals.append({
            "qi": ii, "qid": item["qid"], "qtype": item["qtype"],
            "question": item["question"],
            "ground_truth": list(gt),
            "retrieved_top10": retrieved_sids[:10],
            "first_hit_rank": first_hit,
            "mrr": mrr,
            "recall10": r10,
        })

        if ii % 50 == 0 and ii > 0:
            elapsed = time.time() - t_bench
            rate = ii / elapsed * 60
            print(f"[bench] {ii}/{len(items)}  ({rate:.0f} items/min)", flush=True)

    # Final cleanup
    try:
        cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_lme_v061'")
        conn.commit()
    except Exception as e:
        print(f"[bench] cleanup warn: {e}")
        try:
            conn.rollback()
        except Exception:
            pass
    cur.close()
    conn.close()

    elapsed = time.time() - t_bench
    print(f"[bench] done {len(v061_per_item_r10)} items in {elapsed:.1f}s")

    # Load v0.4.0 baseline per-item recall@10 for comparison
    baseline_file = ROOT / "longmemeval/results/v0.4.0_hybrid_20260515/raw_retrievals.jsonl"
    v051_per_item_r10: list[float] = []
    v061_qi_set = {r["qi"] for r in raw_retrievals}

    if baseline_file.exists():
        with open(baseline_file) as f:
            for line in f:
                rec = json.loads(line)
                if rec["qi"] in v061_qi_set:
                    gt = set(rec["ground_truth"])
                    top10 = set(rec["retrieved_top10"])
                    r10 = len(top10 & gt) / len(gt) if gt else 0.0
                    v051_per_item_r10.append(r10)
        print(f"[baseline] loaded {len(v051_per_item_r10)} v0.4.0 per-item recall@10 values")
    else:
        print(f"[baseline] WARNING: baseline file not found at {baseline_file}")

    # Statistical test
    p_val = None
    mean_delta = None
    if len(v051_per_item_r10) == len(v061_per_item_r10) and len(v051_per_item_r10) > 1:
        p_val      = paired_ttest_p(v061_per_item_r10, v051_per_item_r10)
        mean_delta = sum(v061_per_item_r10) / len(v061_per_item_r10) - \
                     sum(v051_per_item_r10) / len(v051_per_item_r10)
        print(f"[gate] v0.6.1 recall@10 = {sum(v061_per_item_r10)/len(v061_per_item_r10):.4f}")
        print(f"[gate] v0.4.0 recall@10 = {sum(v051_per_item_r10)/len(v051_per_item_r10):.4f}")
        print(f"[gate] delta = {mean_delta:+.4f}  ({mean_delta*100:+.2f}pp)")
        print(f"[gate] paired t-test p = {p_val:.4f}")

    # Build result
    r10_agg = _agg(overall_recall[10])
    metrics = {
        "version":          "v0.6.1",
        "date":             time.strftime("%Y-%m-%d"),
        "mode":             "real",
        "retrieval_method": "pgmnemo.recall_hybrid() vec=0.4 bm25=0.4 rrf_k=60 ORDER BY rrf_diag (v0.6.1 F1)",
        "embedder":         "BAAI/bge-m3 (1024d) — pre-computed cache",
        "dataset":          f"xiaowu0162/longmemeval-cleaned ({dataset_file})",
        "dataset_sha256":   hashlib.sha256(open(DATA_DIR / dataset_file, "rb").read()).hexdigest(),
        "n_items":          len(items),
        "n_evaluated":      len(v061_per_item_r10),
        "qtype_distribution": dict(Counter(i["qtype"] for i in items)),
        "overall": {
            **{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
            "mrr": _agg(overall_mrr),
        },
        "by_qtype": {
            qt: {
                "n": len(per_qtype_mrr[qt]),
                **{f"recall@{K}": _agg(per_qtype_recall[K][qt]) for K in K_VALUES},
                "mrr": _agg(per_qtype_mrr[qt]),
            }
            for qt in sorted(per_qtype_mrr)
        },
        "gate": {
            "v061_recall10":  round(sum(v061_per_item_r10) / max(1, len(v061_per_item_r10)), 4),
            "v051_recall10":  round(sum(v051_per_item_r10) / max(1, len(v051_per_item_r10)), 4) if v051_per_item_r10 else None,
            "delta_pp":       round(mean_delta * 100, 2) if mean_delta is not None else None,
            "paired_ttest_p": round(p_val, 4) if p_val is not None else None,
            "gate_pass_delta": (mean_delta is not None and mean_delta >= 0.01),
            "gate_pass_pval":  (p_val is not None and p_val < 0.05),
            "gate_pass":       (mean_delta is not None and mean_delta >= 0.01 and p_val is not None and p_val < 0.05),
        },
        "wall_clock_sec": round(time.time() - t_start, 1),
    }

    return metrics, raw_retrievals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit",   type=int, default=None, help="Limit items for quick test")
    ap.add_argument("--out-dir", default=str(ROOT / "longmemeval/results/v0.6.1_real"), help="Output directory")
    args = ap.parse_args()

    metrics, raw_retrievals = run_benchmark(args)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    json.dump(metrics, open(out_dir / "metrics.json", "w"), indent=2)
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    gate = metrics["gate"]
    r10  = metrics["overall"]["recall@10"]

    report = f"""# pgmnemo v0.6.1 LongMemEval Real-DB Benchmark

Date: {metrics['date']}
Mode: real-DB, bge-m3 pre-computed embeddings
n_items: {metrics['n_evaluated']}

## Overall recall@10: {r10['mean']}  [CI95: {r10['ci95_lo']}–{r10['ci95_hi']}]

## Gate evaluation

| Criterion              | Value         | Pass? |
|------------------------|---------------|-------|
| v0.6.1 recall@10       | {gate['v061_recall10']} | — |
| v0.4.0 (v0.5.1) recall@10 | {gate['v051_recall10']} | — |
| Delta (pp)             | {gate['delta_pp']} | {'✓' if gate['gate_pass_delta'] else '✗'} (need ≥+1pp) |
| Paired t-test p        | {gate['paired_ttest_p']} | {'✓' if gate['gate_pass_pval'] else '✗'} (need <0.05) |
| **GATE OVERALL**       |               | **{'PASS ✓' if gate['gate_pass'] else 'FAIL ✗'}** |

## By qtype

| qtype | n | recall@10 |
|---|---|---|
"""
    for qt in sorted(metrics["by_qtype"]):
        row = metrics["by_qtype"][qt]
        r   = row["recall@10"]
        report += f"| {qt} | {row['n']} | {r['mean']} |\n"

    report += f"\n## Wall clock: {metrics['wall_clock_sec']}s\n"

    with open(out_dir / "report.md", "w") as f:
        f.write(report)

    print(report)

    g = gate["gate_pass"]
    print(f"\n{'='*60}")
    print(f"GATE: {'PASS ✓ — v0.6.1 is shippable' if g else 'FAIL ✗ — DO NOT SHIP'}")
    print(f"{'='*60}")
    sys.exit(0 if g else 1)


if __name__ == "__main__":
    main()
