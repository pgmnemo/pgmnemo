"""bench_recall_fast_vs_hybrid.py
Measure recall@K overlap between recall_fast() and recall_hybrid() on a live corpus.

GATE: PGMREL-0100-IMPLEMENT-RECALL-FAST-HNSW
Required before making recall_fast the MCP default:
  "measure recall@K cost of dropping graph_walk before making it MCP default"

Methodology
-----------
For each query in a query set:
  1. Run recall_fast(query_embedding, k, ...)  → set F
  2. Run recall_hybrid(query_embedding, query_text, k, ...) → set H
  3. overlap@K   = |F ∩ H| / K         (fraction of hybrid top-K found by fast)
  4. jaccard@K   = |F ∩ H| / |F ∪ H|   (symmetric similarity)
  5. latency_fast, latency_hybrid        (wall-clock per call)

Aggregated over N queries → median + p95 overlap@K, median latency.

Usage
-----
export PGMNEMO_DSN="postgresql://user:pass@localhost/mydb"
export EMBEDDING_SERVER="http://localhost:8080"  # optional
python bench_recall_fast_vs_hybrid.py \
    --role my_role \
    --project-id 1 \
    --queries queries.txt \
    --k 10 \
    --repeats 3 \
    --output benchmarks/gate/v0.9.8-recall-at-k.json

queries.txt: one query string per line.

Output JSON schema
------------------
{
  "version": "v0.9.8",
  "gate_type": "recall_at_k_fast_vs_hybrid",
  "k": 10,
  "n_queries": N,
  "results": {
    "overlap_at_k_median": 0.XX,     # median |F ∩ H| / K
    "overlap_at_k_p10":   0.XX,      # 10th pct (worst queries)
    "jaccard_at_k_median": 0.XX,
    "fast_latency_p50_ms": XX,
    "fast_latency_p95_ms": XX,
    "hybrid_latency_p50_ms": XX,
    "hybrid_latency_p95_ms": XX,
    "speedup_p50": X.X                # hybrid_p50 / fast_p50
  },
  "gate_criteria": "overlap_at_k_median >= 0.70 AND fast_latency_p50_ms < 200",
  "gate_status": "PASS|FAIL"
}
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import time
from pathlib import Path
from typing import Any

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    raise SystemExit("psycopg2-binary required: pip install psycopg2-binary")

try:
    import httpx
except ImportError:
    httpx = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# Embedding helpers
# ---------------------------------------------------------------------------

def embed(text: str, server: str, model: str = "BAAI/bge-m3", dim: int = 1024) -> list[float]:
    """Call OpenAI-compatible embedding endpoint."""
    if httpx is None:
        raise SystemExit("httpx required for embedding: pip install httpx")
    resp = httpx.post(
        f"{server}/v1/embeddings",
        json={"input": text, "model": model},
        timeout=30.0,
    )
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]


def to_pgvector(vec: list[float]) -> str:
    return "[" + ",".join(str(x) for x in vec) + "]"


# ---------------------------------------------------------------------------
# Recall functions
# ---------------------------------------------------------------------------

def call_recall_fast(
    cur,
    embedding: list[float],
    k: int,
    role_filter: str | None,
    project_id_filter: int | None,
) -> tuple[set[int], float]:
    """Returns (lesson_id_set, latency_ms)."""
    vec = to_pgvector(embedding)
    t0 = time.perf_counter()
    cur.execute(
        """
        SELECT lesson_id
        FROM pgmnemo.recall_fast(%s::vector(1024), %s, %s, %s, NULL)
        """,
        (vec, k, role_filter, project_id_filter),
    )
    rows = cur.fetchall()
    latency_ms = (time.perf_counter() - t0) * 1000
    return {r[0] for r in rows}, latency_ms


def call_recall_hybrid(
    cur,
    embedding: list[float],
    query_text: str,
    k: int,
    role_filter: str | None,
    project_id_filter: int | None,
) -> tuple[set[int], float]:
    """Returns (lesson_id_set, latency_ms)."""
    vec = to_pgvector(embedding)
    t0 = time.perf_counter()
    cur.execute(
        """
        SELECT lesson_id
        FROM pgmnemo.recall_hybrid(
            %s::vector(1024), %s, %s, %s, %s, 0.4, 0.4, 60, NULL
        )
        """,
        (vec, query_text, k, role_filter, project_id_filter),
    )
    rows = cur.fetchall()
    latency_ms = (time.perf_counter() - t0) * 1000
    return {r[0] for r in rows}, latency_ms


# ---------------------------------------------------------------------------
# Main benchmark
# ---------------------------------------------------------------------------

def run_benchmark(
    dsn: str,
    queries: list[str],
    k: int,
    role_filter: str | None,
    project_id_filter: int | None,
    embedding_server: str,
    repeats: int,
) -> dict[str, Any]:
    conn = psycopg2.connect(dsn)
    conn.set_session(readonly=True, autocommit=True)

    overlaps: list[float] = []
    jaccards: list[float] = []
    fast_lats: list[float] = []
    hybrid_lats: list[float] = []

    with conn.cursor() as cur:
        # Warm-up
        cur.execute("SET pgmnemo.include_unverified = 'on'")
        cur.execute("SET pgmnemo.track_recall_recency = 'off'")

        for query in queries:
            print(f"  query: {query[:60]!r}…")
            vec = embed(query, embedding_server)

            for rep in range(repeats):
                f_ids, f_lat = call_recall_fast(cur, vec, k, role_filter, project_id_filter)
                h_ids, h_lat = call_recall_hybrid(cur, vec, query, k, role_filter, project_id_filter)

                if rep == 0:  # record only first repeat (cold-ish)
                    if not h_ids:
                        # Hybrid returned nothing — skip (empty corpus for this role/project)
                        continue
                    overlap = len(f_ids & h_ids) / k
                    union = f_ids | h_ids
                    jaccard = len(f_ids & h_ids) / len(union) if union else 1.0
                    overlaps.append(overlap)
                    jaccards.append(jaccard)

                fast_lats.append(f_lat)
                hybrid_lats.append(h_lat)

    conn.close()

    def pct(lst: list[float], p: float) -> float:
        if not lst:
            return 0.0
        lst_sorted = sorted(lst)
        idx = int(len(lst_sorted) * p)
        return round(lst_sorted[min(idx, len(lst_sorted) - 1)], 3)

    def median(lst: list[float]) -> float:
        return round(statistics.median(lst), 3) if lst else 0.0

    overlap_median = median(overlaps)
    fast_p50 = median(fast_lats)
    fast_p95 = pct(fast_lats, 0.95)
    hybrid_p50 = median(hybrid_lats)
    hybrid_p95 = pct(hybrid_lats, 0.95)
    speedup = round(hybrid_p50 / fast_p50, 2) if fast_p50 > 0 else 0.0

    results = {
        "overlap_at_k_median": overlap_median,
        "overlap_at_k_p10": pct(overlaps, 0.10),
        "jaccard_at_k_median": median(jaccards),
        "fast_latency_p50_ms": fast_p50,
        "fast_latency_p95_ms": fast_p95,
        "hybrid_latency_p50_ms": hybrid_p50,
        "hybrid_latency_p95_ms": hybrid_p95,
        "speedup_p50": speedup,
    }

    gate_pass = (overlap_median >= 0.70) and (fast_p50 < 200)
    gate_status = "PASS" if gate_pass else "FAIL"

    return {
        "version": "v0.9.8",
        "gate_type": "recall_at_k_fast_vs_hybrid",
        "k": k,
        "n_queries": len(queries),
        "n_overlaps_measured": len(overlaps),
        "role_filter": role_filter,
        "project_id_filter": project_id_filter,
        "results": results,
        "gate_criteria": "overlap_at_k_median >= 0.70 AND fast_latency_p50_ms < 200",
        "gate_status": gate_status,
        "note": (
            "overlap_at_k = |recall_fast top-K ∩ recall_hybrid top-K| / K. "
            "Measures recall@K cost of dropping graph_walk + BM25 RRF (fast path). "
            "Threshold 0.70 = acceptable quality for interactive/MCP use-case. "
            "fast_latency < 200ms = interactive latency target for MCP default path."
        ),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark recall_fast vs recall_hybrid")
    parser.add_argument("--dsn", default=os.environ.get("PGMNEMO_DSN", ""))
    parser.add_argument("--embedding-server", default=os.environ.get("EMBEDDING_SERVER", "http://localhost:8080"))
    parser.add_argument("--queries", required=True, help="Path to queries file (one per line)")
    parser.add_argument("--k", type=int, default=10)
    parser.add_argument("--role", default=None)
    parser.add_argument("--project-id", type=int, default=None)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", default=None, help="Write gate JSON to this path")
    args = parser.parse_args()

    if not args.dsn:
        raise SystemExit("PGMNEMO_DSN env var or --dsn required")

    queries = Path(args.queries).read_text().splitlines()
    queries = [q.strip() for q in queries if q.strip()]
    if not queries:
        raise SystemExit("No queries found in file")

    print(f"Benchmarking recall_fast vs recall_hybrid: k={args.k}, n_queries={len(queries)}, repeats={args.repeats}")

    result = run_benchmark(
        dsn=args.dsn,
        queries=queries,
        k=args.k,
        role_filter=args.role,
        project_id_filter=args.project_id,
        embedding_server=args.embedding_server,
        repeats=args.repeats,
    )

    print(json.dumps(result, indent=2))

    if args.output:
        Path(args.output).write_text(json.dumps(result, indent=4))
        print(f"\nGate JSON written to {args.output}")

    if result["gate_status"] == "FAIL":
        raise SystemExit(f"GATE FAIL: {result['results']}")


if __name__ == "__main__":
    main()
