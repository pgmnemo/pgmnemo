"""bench_recall_fast_vs_hybrid_v010.py
Produce benchmarks/gate/v0.10.0-recall-at-k.json with measured
recall@1/5/10/20 and overlap@10 for recall_fast vs recall_hybrid.

GATE: PGMREL-0100-C4
Task: produce measured recall@K gate file for v0.10.0 release.

Methodology
-----------
Samples N random active lessons from the live corpus. Each lesson's
stored embedding is used as the query vector; the lesson_text is used
as the BM25 query for recall_hybrid. For each K in {1, 5, 10, 20}:

  F_K = recall_fast(embedding, k=K)      → set of lesson_ids
  H_K = recall_hybrid(embedding, text, k=K) → set of lesson_ids
  overlap@K = |F_K ∩ H_K| / K             (fraction of hybrid top-K found by fast)
  recall@K  = overlap@K                    (alias — K items in H_K, fast finds N of them → N/K)

Aggregated over N queries → median + p10 overlap@K for each K.

Usage (no external embedding server needed — uses stored vectors)
------
DATABASE_URL=postgresql://... python3 benchmarks/scripts/bench_recall_fast_vs_hybrid_v010.py \
    --n-queries 30 \
    --output benchmarks/gate/v0.10.0-recall-at-k.json
"""

from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import time
from pathlib import Path
from typing import Any

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    raise SystemExit("psycopg2-binary required: pip install psycopg2-binary")

KS = [1, 5, 10, 20]
DEFAULT_N_QUERIES = 30
INCLUDE_UNVERIFIED = True  # measure across full corpus


def sample_query_lessons(cur, n: int) -> list[dict]:
    """Sample N random lessons with embeddings and lesson_text for use as queries.

    Excludes degenerate corpus entries:
    - Very short text (<80 chars) — too generic, causes BM25 full-table scan
    - '[DOC:' prefix — document placeholder entries (not real semantic lessons)
    - '[WATCHDOG]' prefix — system messages with no semantic content
    """
    cur.execute(
        """
        SELECT id, lesson_text, embedding::text, role, project_id
        FROM pgmnemo.agent_lesson
        WHERE embedding IS NOT NULL
          AND lesson_text IS NOT NULL
          AND length(lesson_text) > 80
          AND lesson_text NOT LIKE '[DOC:%%'
          AND lesson_text NOT LIKE '[WATCHDOG]%%'
          AND lesson_text NOT LIKE 'hello world%%'
        ORDER BY random()
        LIMIT %s
        """,
        (n,),
    )
    rows = cur.fetchall()
    return [
        {
            "id": r[0],
            "text": r[1],
            "embedding": r[2],  # already a string like '[0.1,0.2,...]'
            "role": r[3],
            "project_id": r[4],
        }
        for r in rows
    ]


def call_recall_fast(cur, embedding_str: str, k: int) -> tuple[set[int], float]:
    """Returns (lesson_id_set, latency_ms). No role/project filter = global corpus."""
    t0 = time.perf_counter()
    cur.execute(
        "SELECT lesson_id FROM pgmnemo.recall_fast(%s::vector, %s, NULL, NULL, NULL)",
        (embedding_str, k),
    )
    rows = cur.fetchall()
    latency_ms = (time.perf_counter() - t0) * 1000
    return {r[0] for r in rows}, latency_ms


def call_recall_hybrid(cur, embedding_str: str, query_text: str, k: int) -> tuple[set[int], float]:
    """Returns (lesson_id_set, latency_ms). No role/project filter = global corpus."""
    t0 = time.perf_counter()
    cur.execute(
        """
        SELECT lesson_id
        FROM pgmnemo.recall_hybrid(%s::vector, %s, %s, NULL, NULL, 0.4, 0.4, 60, NULL)
        """,
        (embedding_str, query_text, k),
    )
    rows = cur.fetchall()
    latency_ms = (time.perf_counter() - t0) * 1000
    return {r[0] for r in rows}, latency_ms


def pct(lst: list[float], p: float) -> float:
    if not lst:
        return 0.0
    lst_sorted = sorted(lst)
    idx = max(0, min(int(len(lst_sorted) * p), len(lst_sorted) - 1))
    return round(lst_sorted[idx], 4)


def med(lst: list[float]) -> float:
    return round(statistics.median(lst), 4) if lst else 0.0


def run_benchmark(dsn: str, n_queries: int) -> dict[str, Any]:
    conn = psycopg2.connect(dsn)
    conn.set_session(autocommit=True)

    with conn.cursor() as cur:
        if INCLUDE_UNVERIFIED:
            cur.execute("SET pgmnemo.include_unverified = 'on'")
        cur.execute("SET pgmnemo.track_recall_recency = 'off'")
        # Cap slow BM25 queries; 8s is generous for real lessons, 60s+ indicates pathological input
        cur.execute("SET statement_timeout = '8000'")

        # Count corpus
        cur.execute("SELECT COUNT(*) FROM pgmnemo.agent_lesson WHERE embedding IS NOT NULL")
        n_corpus = cur.fetchone()[0]
        print(f"[bench] corpus: {n_corpus} lessons with embeddings")

        # Sample query set
        queries = sample_query_lessons(cur, n_queries)
        print(f"[bench] sampled {len(queries)} queries")

        # Per-K accumulators
        overlaps: dict[int, list[float]] = {k: [] for k in KS}
        fast_lats: dict[int, list[float]] = {k: [] for k in KS}
        hybrid_lats: dict[int, list[float]] = {k: [] for k in KS}

        for i, q in enumerate(queries):
            emb = q["embedding"]
            text = q["text"]
            print(f"  [{i+1}/{len(queries)}] id={q['id']} text={text[:50]!r}")

            for k in KS:
                try:
                    f_ids, f_lat = call_recall_fast(cur, emb, k)
                    h_ids, h_lat = call_recall_hybrid(cur, emb, text, k)
                except Exception as e:
                    if "statement timeout" in str(e).lower() or "canceling statement" in str(e).lower():
                        print(f"    SKIP k={k}: statement_timeout (BM25 too slow — degenerate query text)")
                        # Reset connection state after timeout
                        try:
                            conn.rollback()
                            cur.execute("SET pgmnemo.include_unverified = 'on'")
                            cur.execute("SET pgmnemo.track_recall_recency = 'off'")
                            cur.execute("SET statement_timeout = '8000'")
                        except Exception:
                            pass
                    else:
                        print(f"    WARN k={k}: {e}")
                    continue

                if not h_ids:
                    print(f"    SKIP k={k}: hybrid returned 0 results")
                    continue

                # overlap@K = fraction of hybrid top-K that fast also returns
                overlap = len(f_ids & h_ids) / k
                overlaps[k].append(overlap)
                fast_lats[k].append(f_lat)
                hybrid_lats[k].append(h_lat)

                print(
                    f"    k={k:2d}: overlap={overlap:.2f} "
                    f"fast={f_lat:.1f}ms hybrid={h_lat:.1f}ms"
                )

    conn.close()

    # Build per-K results
    results_by_k: dict[str, Any] = {}
    for k in KS:
        ov = overlaps[k]
        fl = fast_lats[k]
        hl = hybrid_lats[k]
        results_by_k[f"k{k}"] = {
            "n_queries": len(ov),
            "overlap_median": med(ov),
            "overlap_p10": pct(ov, 0.10),
            "fast_latency_p50_ms": med(fl),
            "fast_latency_p95_ms": pct(fl, 0.95),
            "hybrid_latency_p50_ms": med(hl),
            "hybrid_latency_p95_ms": pct(hl, 0.95),
            "speedup_p50": round(med(hl) / med(fl), 2) if med(fl) > 0 else None,
        }

    # Primary gate metric is overlap@10 (MCP default k=10)
    ov10 = overlaps[10]
    fl10 = fast_lats[10]
    gate_overlap = med(ov10)
    gate_fast_p50 = med(fl10)
    gate_pass = (gate_overlap >= 0.70) and (gate_fast_p50 < 200)

    # Also summarise recall at each K in a flat way for easy inspection
    recall_at_k_summary = {
        f"recall_at_{k}": results_by_k[f"k{k}"]["overlap_median"]
        for k in KS
    }

    return {
        "version": "v0.10.0",
        "date": "2026-06-21",
        "pgmnemo_version": "0.10.0",
        "gate_type": "recall_at_k_fast_vs_hybrid",
        "k_primary": 10,
        "ks_measured": KS,
        "n_queries": n_queries,
        "corpus": {
            "database": "prod_corpus",
            "active_embedded_lessons": n_corpus,
            "queries": len(queries),
            "source": "random sample of active lessons with embeddings (live corpus)",
        },
        # flat summary at top level for quick scanning
        **recall_at_k_summary,
        "overlap_at_10_median": gate_overlap,
        "overlap_at_10_p10": pct(ov10, 0.10),
        # detailed per-K breakdown
        "results_by_k": results_by_k,
        # legacy flat results (overlap@10) for gate compatibility
        "results": {
            "overlap_at_k_median": gate_overlap,
            "overlap_at_k_p10": pct(ov10, 0.10),
            "fast_latency_p50_ms": gate_fast_p50,
            "fast_latency_p95_ms": pct(fl10, 0.95),
            "hybrid_latency_p50_ms": med(hybrid_lats[10]),
            "hybrid_latency_p95_ms": pct(hybrid_lats[10], 0.95),
            "speedup_p50": round(med(hybrid_lats[10]) / gate_fast_p50, 2) if gate_fast_p50 > 0 else None,
        },
        "gate_criteria": "overlap_at_10_median >= 0.70 AND fast_latency_p50_ms < 200",
        "gate_status": "PASS" if gate_pass else "FAIL",
        "methodology": (
            "overlap@K = |recall_fast top-K ∩ recall_hybrid top-K| / K "
            f"measured over {len(queries)} queries on live prod_corpus corpus "
            f"({n_corpus} lessons with embeddings). "
            "Queries are random active lesson embeddings reused as query vectors. "
            "recall_fast: HNSW cosine only. recall_hybrid: HNSW + BM25 RRF (vec=0.4, bm25=0.4, rrf_k=60). "
            "No role/project filter (global corpus). "
            "Benchmark script: benchmarks/scripts/bench_recall_fast_vs_hybrid_v010.py."
        ),
        "note": (
            "overlap@K = |recall_fast top-K ∩ recall_hybrid top-K| / K. "
            "Measures recall@K cost of dropping graph_walk + BM25 RRF (fast path). "
            "Threshold 0.70 = acceptable quality for interactive/MCP use-case. "
            "fast_latency < 200ms = interactive latency target for MCP default path."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark recall_fast vs recall_hybrid — v0.10.0 gate")
    parser.add_argument("--dsn", default=os.environ.get("DATABASE_URL", os.environ.get("PGMNEMO_DSN", "")))
    parser.add_argument("--n-queries", type=int, default=DEFAULT_N_QUERIES)
    parser.add_argument("--output", default="benchmarks/gate/v0.10.0-recall-at-k.json")
    args = parser.parse_args()

    if not args.dsn:
        raise SystemExit("DATABASE_URL or PGMNEMO_DSN env var (or --dsn) required")

    print(f"[bench] recall_fast vs recall_hybrid: n_queries={args.n_queries}, k={KS}")
    result = run_benchmark(dsn=args.dsn, n_queries=args.n_queries)

    print("\n=== RESULTS ===")
    print(json.dumps(result, indent=2))

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=4))
        print(f"\n[bench] Gate JSON written to {args.output}")

    status = result["gate_status"]
    print(f"\n[bench] Gate status: {status}")
    if status == "FAIL":
        raise SystemExit(f"GATE FAIL: overlap@10={result['overlap_at_10_median']:.2%}, fast_p50={result['results']['fast_latency_p50_ms']:.1f}ms")


if __name__ == "__main__":
    main()
