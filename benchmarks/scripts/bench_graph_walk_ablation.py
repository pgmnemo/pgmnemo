"""bench_graph_walk_ablation.py — pgmnemo issue #88
Graph-walk ablation: measure recall@K ranking lift vs latency cost.

Methodology
-----------
Phase 1 — Live-corpus ranking overlap (no labels required):
  For N random queries drawn from the live corpus, run recall_hybrid
  twice: once with the graph-walk active (GUC default 0.2) and once
  with GUC set to 0.0 (graph CTEs still execute but scores are
  unaffected). Measure ranking overlap@K and whether graph re-ranks
  any results relative to pure RRF+aux.

Phase 2 — Edge-aware controlled recall test:
  Select anchor lessons that have outgoing causal/temporal edges.
  Use each anchor's embedding as a query and measure the rank of its
  edge-targets WITH vs WITHOUT graph-walk. A "recall hit" = edge target
  appears in top-K. Gives a direct measure of the rank lift graph_walk
  confers on known-related lessons.

Phase 3 — True latency cost (no-CTE path):
  Run an inline SQL that reproduces recall_hybrid WITHOUT the
  graph_walk and graph_proximity CTEs. Compares P50/P95 latency
  for the full hybrid vs the stripped version.

Significance test
-----------------
Produces two JSON files in the format expected by significance_test.py:
  - baseline: recall_hybrid WITHOUT graph (GUC=0)
  - candidate: recall_hybrid WITH graph (GUC=0.2)
  - metric: recall@K (Phase 2 hit rate) + latency ms

Decision rule (PGMNEMO #88 acceptance):
  p_corr < 0.05 + positive delta → significant lift → keep graph_walk
  otherwise                       → make graph_walk opt-in (GUC default off)

Usage
-----
  DATABASE_URL=postgresql://... python3 benchmarks/scripts/bench_graph_walk_ablation.py \\
      --n-queries 50 \\
      --n-edge-anchors 30 \\
      --output benchmarks/results/graph_walk_ablation_YYYYMMDD.json

  # or via env var only:
  DATABASE_URL=postgresql://execas:pw@postgres:5432/prod_corpus \\
      python3 benchmarks/scripts/bench_graph_walk_ablation.py
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    raise SystemExit("psycopg2-binary required: pip install psycopg2-binary")

# ─── Constants ────────────────────────────────────────────────────────────────

KS = [1, 5, 10, 20]
DEFAULT_N_QUERIES = 50
DEFAULT_N_EDGE_ANCHORS = 30
STMT_TIMEOUT = "8s"
GRAPH_WEIGHT_ON  = 0.2   # default (GUC off → uses this)
GRAPH_WEIGHT_OFF = 0.0   # ablation: graph_walk computed but score multiplier = 1

# ─── Inline SQL for no-CTE hybrid (Phase 3 latency baseline) ─────────────────

RECALL_HYBRID_NO_GRAPH_SQL = """
-- recall_hybrid WITHOUT graph_walk / graph_proximity CTEs
-- Used to measure true latency cost of the BFS graph traversal.
WITH
vec_candidates AS (
    SELECT al.id, al.role, al.project_id, al.topic, al.lesson_text,
           al.importance, al.metadata, al.commit_sha, al.artifact_hash,
           al.verified_at, al.created_at, al.confidence,
           (1.0 - (al.embedding <=> %(embedding)s::vector))::DOUBLE PRECISION AS raw_vec_score,
           0.0::DOUBLE PRECISION AS raw_bm25_score
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.embedding IS NOT NULL
      AND (al.verified_at IS NOT NULL OR current_setting('pgmnemo.include_unverified','true')::boolean)
      AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
    ORDER BY al.embedding <=> %(embedding)s::vector
    LIMIT GREATEST(%(k)s * 4, 100)
),
bm25_candidates AS (
    SELECT al.id, al.role, al.project_id, al.topic, al.lesson_text,
           al.importance, al.metadata, al.commit_sha, al.artifact_hash,
           al.verified_at, al.created_at, al.confidence,
           0.0::DOUBLE PRECISION AS raw_vec_score,
           ts_rank_cd(
               setweight(to_tsvector('english', COALESCE(al.topic,'')), 'A') || al.lesson_tsv,
               websearch_to_tsquery('english', %(query_text)s), 32
           )::DOUBLE PRECISION AS raw_bm25_score
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND (al.lesson_tsv @@ websearch_to_tsquery('english', %(query_text)s)
           OR to_tsvector('english', COALESCE(al.topic,'')) @@ websearch_to_tsquery('english', %(query_text)s))
      AND (al.verified_at IS NOT NULL OR current_setting('pgmnemo.include_unverified','true')::boolean)
      AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
    ORDER BY raw_bm25_score DESC
    LIMIT GREATEST(%(k)s * 4, 40)
),
all_candidates AS (
    SELECT v.id, v.role, v.project_id, v.topic, v.lesson_text,
           v.importance, v.metadata, v.commit_sha, v.artifact_hash,
           v.verified_at, v.created_at, v.confidence,
           v.raw_vec_score,
           COALESCE(b.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
    FROM vec_candidates v LEFT JOIN bm25_candidates b ON b.id = v.id
    UNION ALL
    SELECT b.id, b.role, b.project_id, b.topic, b.lesson_text,
           b.importance, b.metadata, b.commit_sha, b.artifact_hash,
           b.verified_at, b.created_at, b.confidence,
           0.0::DOUBLE PRECISION, b.raw_bm25_score
    FROM bm25_candidates b
    WHERE b.id NOT IN (SELECT id FROM vec_candidates)
),
rrf_ranked AS (
    SELECT *,
           COUNT(*) OVER ()                                            AS n_candidates,
           ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST) AS vec_rank,
           CASE WHEN raw_bm25_score > 0
                THEN RANK() OVER (PARTITION BY (raw_bm25_score>0) ORDER BY raw_bm25_score DESC NULLS LAST)
                ELSE NULL END                                          AS bm25_rank_sparse
    FROM all_candidates
),
scored AS (
    SELECT r.id,
           (0.4 / (60.0 + r.vec_rank::DOUBLE PRECISION)
          + 0.4 / (60.0 + COALESCE(r.bm25_rank_sparse, r.n_candidates+1)::DOUBLE PRECISION)
          + (0.8/61.0)/0.76 * (0.4*r.raw_vec_score + 0.4*r.raw_bm25_score))
          + (0.8/61.0)/0.76 * (
                0.025*(r.importance::DOUBLE PRECISION/5.0)
              + 0.025*r.confidence::DOUBLE PRECISION
              + 0.05*GREATEST(0.0, 1.0 - LEAST(
                    EXTRACT(EPOCH FROM (NOW()-r.created_at))/(90.0*86400.0), 1.0))
              + 0.05*(CASE WHEN r.commit_sha IS NOT NULL AND r.verified_at IS NOT NULL THEN 1.0
                           WHEN r.commit_sha IS NOT NULL THEN 0.4 ELSE 0.0 END))
            AS final_score,
           r.raw_vec_score AS v_score,
           r.raw_bm25_score AS b_score
    FROM rrf_ranked r
)
SELECT id AS lesson_id, final_score AS score
FROM scored
ORDER BY final_score DESC, id ASC
LIMIT %(k)s
"""


# ─── DB helpers ───────────────────────────────────────────────────────────────

def connect(dsn: str) -> psycopg2.extensions.connection:
    conn = psycopg2.connect(dsn, client_encoding="utf8")
    conn.autocommit = False
    return conn


def safe_rollback(conn: psycopg2.extensions.connection) -> None:
    """Rollback, silently ignore if connection is already closed."""
    try:
        conn.rollback()
    except Exception:
        pass


def is_conn_dead(conn: psycopg2.extensions.connection) -> bool:
    """Return True if connection is closed or in error state."""
    try:
        return conn.closed != 0
    except Exception:
        return True


def setup_session(cur, *, graph_weight: float, include_unverified: bool = True) -> None:
    cur.execute(f"SET statement_timeout = '{STMT_TIMEOUT}'")
    cur.execute(f"SET pgmnemo.graph_proximity_weight = {graph_weight:.4f}")
    cur.execute(f"SET pgmnemo.include_unverified = '{'on' if include_unverified else 'off'}'")
    cur.execute("SET pgmnemo.track_recall_recency = 'off'")   # suppress side-writes
    cur.execute("SET work_mem = '128MB'")   # cap recursive CTE memory


def call_recall_hybrid(
    cur, embedding_str: str, query_text: str, k: int
) -> tuple[list[int], float]:
    """Call pgmnemo.recall_hybrid; returns (ordered lesson_ids, latency_ms).

    Signature: recall_hybrid(embedding, text, k, role_filter, project_id_filter,
                             vec_weight, bm25_weight, rrf_k, exclude_dag_id)
    """
    t0 = time.perf_counter()
    cur.execute(
        "SELECT lesson_id FROM pgmnemo.recall_hybrid(%s::vector, %s, %s, NULL, NULL, 0.4, 0.4, 60, NULL)",
        (embedding_str, query_text, k),
    )
    rows = cur.fetchall()
    lat = (time.perf_counter() - t0) * 1000
    return [r[0] for r in rows], lat


def call_no_graph_sql(
    cur, embedding_str: str, query_text: str, k: int
) -> tuple[list[int], float]:
    """Run inline no-CTE hybrid SQL; returns (ordered lesson_ids, latency_ms)."""
    t0 = time.perf_counter()
    try:
        cur.execute(
            RECALL_HYBRID_NO_GRAPH_SQL,
            {"embedding": embedding_str, "query_text": query_text, "k": k},
        )
        rows = cur.fetchall()
    except Exception:
        cur.connection.rollback()
        return [], 0.0
    lat = (time.perf_counter() - t0) * 1000
    return [r[0] for r in rows], lat


# ─── Phase 1: Live-corpus ranking overlap ─────────────────────────────────────

def phase1_ranking_overlap(
    dsn: str, n_queries: int
) -> dict[str, Any]:
    """
    Sample N queries, compare ranking WITH vs WITHOUT graph_walk.
    Reports overlap@K (fraction of top-K identical) per K.
    """
    print(f"\n[Phase 1] Live-corpus ranking overlap: {n_queries} queries, K={KS}")
    conn = connect(dsn)
    cur = conn.cursor()

    # Sample query lessons.
    # Exclude bracket-prefixed structured texts (delivery report IDs like [WS-BE-2],
    # [SWDEV-...], [model:...]) which cause BM25 full-table scans → timeouts.
    # Also exclude Cyrillic-dominant texts (not English-tokenizable for BM25).
    # Require English letters at start + no Cyrillic → semantic lesson texts.
    cur.execute(
        """
        SELECT id, lesson_text, embedding::text
        FROM pgmnemo.agent_lesson
        WHERE embedding IS NOT NULL
          AND lesson_text IS NOT NULL
          AND length(lesson_text) BETWEEN 100 AND 1000
          AND lesson_text NOT LIKE '[%%'
          AND lesson_text ~ '^[A-Za-z]'
          AND lesson_text !~ U&'[Ѐ-ӿ]'
          AND verified_at IS NOT NULL
          AND is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
        ORDER BY random()
        LIMIT %s
        """,
        (n_queries,),
    )
    queries = [{"id": r[0], "text": r[1], "embedding": r[2]} for r in cur.fetchall()]
    print(f"  Sampled {len(queries)} queries from live corpus")

    overlaps: dict[int, list[float]] = {k: [] for k in KS}
    lat_with: dict[int, list[float]] = {k: [] for k in KS}
    lat_without: dict[int, list[float]] = {k: [] for k in KS}
    lat_nocte: dict[int, list[float]] = {k: [] for k in KS}

    for i, q in enumerate(queries):
        emb, text = q["embedding"], q["text"]
        print(f"  [{i+1}/{len(queries)}] id={q['id']} text={text[:55]!r}")
        for k in KS:
            # Reconnect if connection died from a previous iteration
            if is_conn_dead(conn):
                print(f"    [reconnect] connection dead, reconnecting...")
                try:
                    conn = connect(dsn)
                    cur = conn.cursor()
                except Exception as re:
                    print(f"    [reconnect] FAILED: {re}")
                    break

            # ── WITH graph ───
            try:
                cur.execute("BEGIN")
                setup_session(cur, graph_weight=GRAPH_WEIGHT_ON)
                ids_with, l_with = call_recall_hybrid(cur, emb, text, k)
                safe_rollback(conn)
            except Exception as e:
                safe_rollback(conn)
                print(f"    SKIP k={k} [with_graph]: {type(e).__name__}: {e}")
                if is_conn_dead(conn):
                    try:
                        conn = connect(dsn)
                        cur = conn.cursor()
                    except Exception:
                        break
                continue

            # ── WITHOUT graph (GUC=0, CTE still runs) ───
            try:
                cur.execute("BEGIN")
                setup_session(cur, graph_weight=GRAPH_WEIGHT_OFF)
                ids_without, l_without = call_recall_hybrid(cur, emb, text, k)
                safe_rollback(conn)
            except Exception as e:
                safe_rollback(conn)
                print(f"    SKIP k={k} [no_graph_guc]: {type(e).__name__}: {e}")
                if is_conn_dead(conn):
                    try:
                        conn = connect(dsn)
                        cur = conn.cursor()
                    except Exception:
                        break
                continue

            # ── WITHOUT graph (true no-CTE SQL, latency only) ───
            try:
                cur.execute("BEGIN")
                cur.execute(f"SET statement_timeout = '{STMT_TIMEOUT}'")
                cur.execute("SET pgmnemo.include_unverified = 'on'")
                _, l_nocte = call_no_graph_sql(cur, emb, text, k)
                safe_rollback(conn)
            except Exception as e:
                safe_rollback(conn)
                l_nocte = 0.0
                if is_conn_dead(conn):
                    try:
                        conn = connect(dsn)
                        cur = conn.cursor()
                    except Exception:
                        pass

            set_with    = set(ids_with)
            set_without = set(ids_without)
            overlap = len(set_with & set_without) / k if k > 0 else 0.0
            overlaps[k].append(overlap)
            lat_with[k].append(l_with)
            lat_without[k].append(l_without)
            if l_nocte > 0:
                lat_nocte[k].append(l_nocte)

            print(
                f"    k={k:2d}: overlap={overlap:.3f}  "
                f"lat_with={l_with:.1f}ms  lat_noguc={l_without:.1f}ms  lat_nocte={l_nocte:.1f}ms"
            )

    try:
        conn.close()
    except Exception:
        pass

    def med(lst: list) -> float:
        return statistics.median(lst) if lst else 0.0

    def pct(lst: list, p: float) -> float:
        if not lst:
            return 0.0
        s = sorted(lst)
        idx = max(0, min(len(s) - 1, int(len(s) * p)))
        return s[idx]

    results_by_k: dict[str, Any] = {}
    for k in KS:
        ov = overlaps[k]
        lw = lat_with[k]
        ln = lat_without[k]
        lc = lat_nocte[k]
        ranking_change_rate = 1.0 - med(ov) if ov else None
        results_by_k[f"k{k}"] = {
            "n_queries": len(ov),
            "overlap_median": round(med(ov), 4),
            "overlap_p10": round(pct(ov, 0.10), 4),
            "ranking_change_rate": round(ranking_change_rate, 4) if ranking_change_rate is not None else None,
            "lat_with_graph_p50_ms":  round(med(lw), 2),
            "lat_with_graph_p95_ms":  round(pct(lw, 0.95), 2),
            "lat_no_graph_guc_p50_ms": round(med(ln), 2),
            "lat_no_graph_guc_p95_ms": round(pct(ln, 0.95), 2),
            "lat_no_cte_p50_ms":       round(med(lc), 2) if lc else None,
            "lat_no_cte_p95_ms":       round(pct(lc, 0.95), 2) if lc else None,
            "latency_delta_cte_overhead_ms": round(med(lw) - med(lc), 2) if lc else None,
        }

    print(f"\n[Phase 1] Summary at k=10: "
          f"overlap={results_by_k.get('k10',{}).get('overlap_median','?')} "
          f"change_rate={results_by_k.get('k10',{}).get('ranking_change_rate','?')} "
          f"lat_with={results_by_k.get('k10',{}).get('lat_with_graph_p50_ms','?')}ms "
          f"lat_nocte={results_by_k.get('k10',{}).get('lat_no_cte_p50_ms','?')}ms")

    return {
        "phase": "live_corpus_ranking_overlap",
        "n_queries_attempted": n_queries,
        "n_queries_measured": len(overlaps[10]),
        "results_by_k": results_by_k,
    }


# ─── Phase 2: Edge-aware controlled recall test ───────────────────────────────

def phase2_edge_recall(
    dsn: str, n_anchors: int
) -> dict[str, Any]:
    """
    For anchor lessons with known causal/temporal edges, test whether
    graph_walk correctly promotes edge targets in recall@K.

    A 'recall hit' = edge target appears in top-K.
    Compare hit rate WITH vs WITHOUT graph_walk.
    """
    print(f"\n[Phase 2] Edge-aware controlled recall: {n_anchors} anchors")
    conn = connect(dsn)
    cur = conn.cursor()

    # Find anchor lessons that have outgoing causal/temporal edges
    # and whose targets are also active lessons with embeddings
    cur.execute(
        """
        SELECT DISTINCT ON (me.source_id)
            me.source_id              AS anchor_id,
            me.target_id              AS target_id,
            me.edge_kind,
            al_src.lesson_text        AS anchor_text,
            al_src.embedding::text    AS anchor_embedding,
            al_tgt.lesson_text        AS target_text
        FROM pgmnemo.mem_edge me
        JOIN pgmnemo.agent_lesson al_src ON al_src.id = me.source_id
            AND al_src.is_active AND al_src.verified_at IS NOT NULL
            AND al_src.embedding IS NOT NULL
            AND al_src.t_valid_to = 'infinity'::TIMESTAMPTZ
        JOIN pgmnemo.agent_lesson al_tgt ON al_tgt.id = me.target_id
            AND al_tgt.is_active AND al_tgt.verified_at IS NOT NULL
            AND al_tgt.t_valid_to = 'infinity'::TIMESTAMPTZ
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND me.source_id <> me.target_id
          AND length(al_src.lesson_text) BETWEEN 100 AND 1000
          AND al_src.lesson_text NOT LIKE '[%%'
          AND al_src.lesson_text ~ '^[A-Za-z]'
          AND al_src.lesson_text !~ U&'[Ѐ-ӿ]'
          AND length(al_tgt.lesson_text) > 30
        ORDER BY me.source_id, random()
        LIMIT %s
        """,
        (n_anchors,),
    )
    anchors = cur.fetchall()
    print(f"  Found {len(anchors)} anchor-target pairs with causal/temporal edges")

    if not anchors:
        print("  WARNING: No anchor-target pairs found — mem_edge empty or no active linked lessons")
        conn.close()
        return {
            "phase": "edge_aware_recall",
            "n_anchors_attempted": n_anchors,
            "n_anchors_measured": 0,
            "warning": "No anchor-target pairs found — mem_edge empty or unlinked to active verified lessons",
            "recall_lift_with_graph": {},
            "recall_lift_without_graph": {},
        }

    recall_with:    dict[int, list[int]] = {k: [] for k in KS}
    recall_without: dict[int, list[int]] = {k: [] for k in KS}
    rank_with:    list[int] = []
    rank_without: list[int] = []

    for i, row in enumerate(anchors):
        anchor_id, target_id, edge_kind, anchor_text, emb, target_text = row
        print(
            f"  [{i+1}/{len(anchors)}] anchor={anchor_id} "
            f"({edge_kind}) → target={target_id}"
        )

        for graph_w, recall_dict, rank_list in [
            (GRAPH_WEIGHT_ON,  recall_with,    rank_with),
            (GRAPH_WEIGHT_OFF, recall_without, rank_without),
        ]:
            label = "with_graph" if graph_w > 0 else "no_graph"
            for k in KS:
                # Reconnect if connection died
                if is_conn_dead(conn):
                    print(f"    [reconnect] connection dead, reconnecting...")
                    try:
                        conn = connect(dsn)
                        cur = conn.cursor()
                    except Exception as re:
                        print(f"    [reconnect] FAILED: {re}")
                        break
                try:
                    cur.execute("BEGIN")
                    setup_session(cur, graph_weight=graph_w)
                    ids, _ = call_recall_hybrid(cur, emb, anchor_text, k)
                    safe_rollback(conn)
                    hit = 1 if target_id in ids else 0
                    recall_dict[k].append(hit)
                    if k == 10 and graph_w > 0:
                        rank_list.append(ids.index(target_id) + 1 if target_id in ids else 999)
                    elif k == 10 and graph_w == 0:
                        rank_list.append(ids.index(target_id) + 1 if target_id in ids else 999)
                    print(
                        f"    {label} k={k:2d}: hit={hit}  "
                        f"target in top-{k}={bool(hit)}"
                    )
                except Exception as e:
                    safe_rollback(conn)
                    print(f"    SKIP {label} k={k}: {type(e).__name__}: {e}")
                    recall_dict[k].append(0)
                    if is_conn_dead(conn):
                        try:
                            conn = connect(dsn)
                            cur = conn.cursor()
                        except Exception:
                            pass

    try:
        conn.close()
    except Exception:
        pass

    results: dict[str, Any] = {
        "phase": "edge_aware_recall",
        "n_anchors_attempted": n_anchors,
        "n_anchors_measured": len(anchors),
        "with_graph": {},
        "without_graph": {},
        "recall_lift": {},
        "rank_improvement": {},
    }

    for k in KS:
        with_hits    = recall_with[k]
        without_hits = recall_without[k]
        n = len(with_hits)
        if n == 0:
            continue
        rate_with    = sum(with_hits) / n
        rate_without = sum(without_hits) / n
        lift = rate_with - rate_without
        results["with_graph"][f"recall@{k}"]    = round(rate_with, 4)
        results["without_graph"][f"recall@{k}"] = round(rate_without, 4)
        results["recall_lift"][f"recall@{k}"]   = round(lift, 4)
        results["recall_lift"]["n"]              = n
        print(
            f"  recall@{k:2d}: with_graph={rate_with:.3f}  "
            f"no_graph={rate_without:.3f}  lift={lift:+.3f}"
        )

    if rank_with and rank_without:
        def med_r(lst: list) -> float:
            return statistics.median(lst) if lst else 0

        results["rank_improvement"] = {
            "median_rank_with_graph":    med_r(rank_with),
            "median_rank_without_graph": med_r(rank_without),
            "rank_delta":                med_r(rank_without) - med_r(rank_with),
            "note": "negative rank_delta = with_graph ranks target HIGHER (lower rank number = better)",
        }
        print(
            f"\n  Median rank@10: with_graph={med_r(rank_with):.1f}  "
            f"no_graph={med_r(rank_without):.1f}  "
            f"delta={med_r(rank_without)-med_r(rank_with):+.1f} (neg = better)"
        )

    return results


# ─── Significance test helpers ────────────────────────────────────────────────

def wilson_ci(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    denom = 1 + z**2 / n
    centre = (p + z**2 / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z**2 / (4 * n**2))) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def two_prop_z(p1: float, n1: int, p2: float, n2: int) -> tuple[float, float]:
    p_pool = (p1 * n1 + p2 * n2) / (n1 + n2)
    if p_pool in (0.0, 1.0) or (n1 + n2) == 0:
        return (0.0, 1.0)
    se = math.sqrt(p_pool * (1 - p_pool) * (1 / n1 + 1 / n2))
    if se == 0:
        return (0.0, 1.0)
    z = (p2 - p1) / se
    p = 2 * (1 - _norm_cdf(abs(z)))
    return (z, p)


def cohens_h(p1: float, p2: float) -> float:
    phi1 = 2 * math.asin(math.sqrt(max(0.0, min(1.0, p1))))
    phi2 = 2 * math.asin(math.sqrt(max(0.0, min(1.0, p2))))
    return phi2 - phi1


def _norm_cdf(x: float) -> float:
    return (1 + math.erf(x / math.sqrt(2))) / 2


def holm_bonferroni(p_values: list[float]) -> list[float]:
    m = len(p_values)
    indexed = sorted(enumerate(p_values), key=lambda x: x[1])
    corrected = [0.0] * m
    running_max = 0.0
    for rank, (orig_idx, p) in enumerate(indexed):
        adjusted = (m - rank) * p
        running_max = max(running_max, adjusted)
        corrected[orig_idx] = min(1.0, running_max)
    return corrected


def significance_analysis(phase2: dict[str, Any]) -> dict[str, Any]:
    """Run significance tests on Phase 2 edge-aware recall results."""
    with_graph    = phase2.get("with_graph", {})
    without_graph = phase2.get("without_graph", {})
    n = phase2.get("recall_lift", {}).get("n", 0)

    if n == 0:
        return {"error": "no measurements for significance test"}

    sig_results = []
    for k in KS:
        key = f"recall@{k}"
        p_with    = with_graph.get(key, 0.0)
        p_without = without_graph.get(key, 0.0)
        z_stat, p_raw = two_prop_z(p_without, n, p_with, n)
        h = cohens_h(p_without, p_with)
        lo_with, hi_with = wilson_ci(round(p_with * n), n)
        lo_wo, hi_wo     = wilson_ci(round(p_without * n), n)
        sig_results.append({
            "metric": key,
            "p_baseline": round(p_without, 4),
            "n_baseline": n,
            "ci_baseline": [round(lo_wo, 4), round(hi_wo, 4)],
            "p_candidate": round(p_with, 4),
            "n_candidate": n,
            "ci_candidate": [round(lo_with, 4), round(hi_with, 4)],
            "delta": round(p_with - p_without, 4),
            "z_stat": round(z_stat, 3),
            "p_raw": round(p_raw, 4),
            "cohens_h": round(h, 3),
        })

    # Holm-Bonferroni correction
    raw_ps = [r["p_raw"] for r in sig_results]
    corr_ps = holm_bonferroni(raw_ps)
    for r, p_c in zip(sig_results, corr_ps):
        r["p_corrected"] = round(p_c, 4)
        r["significant"] = p_c < 0.05

    return {
        "method": "two-proportion z-test + Holm-Bonferroni correction",
        "alpha": 0.05,
        "n_tests": len(sig_results),
        "results": sig_results,
        "any_significant_improvement": any(
            r["significant"] and r["delta"] > 0 for r in sig_results
        ),
        "any_significant_regression": any(
            r["significant"] and r["delta"] < 0 for r in sig_results
        ),
    }


# ─── Decision logic ───────────────────────────────────────────────────────────

def make_decision(phase1: dict, phase2: dict, sig: dict) -> dict[str, Any]:
    """
    Apply PGMNEMO #88 decision rule:
      significant lift → KEEP (keep graph_walk at default GUC 0.2)
      no significant lift → OPT-IN (set GUC default to 0.0)
    """
    k10 = phase1.get("results_by_k", {}).get("k10", {})
    overlap     = k10.get("overlap_median", None)
    change_rate = k10.get("ranking_change_rate", None)
    lat_delta   = k10.get("latency_delta_cte_overhead_ms", None)
    lat_with    = k10.get("lat_with_graph_p50_ms", None)
    lat_nocte   = k10.get("lat_no_cte_p50_ms", None)

    sig_lift = sig.get("any_significant_improvement", False)
    sig_regr = sig.get("any_significant_regression", False)

    # Primary decision
    if sig_lift and not sig_regr:
        decision = "KEEP"
        rationale = (
            "graph_walk shows statistically significant recall lift on edge-linked lessons "
            "(p_corr < 0.05). Keep graph_proximity_weight = 0.2 as default."
        )
    elif sig_regr:
        decision = "REMOVE"
        rationale = (
            "graph_walk shows statistically significant REGRESSION on tested metrics "
            "(p_corr < 0.05). Remove or hard-disable graph_walk."
        )
    else:
        decision = "OPT-IN"
        rationale = (
            "graph_walk shows no statistically significant recall lift (p_corr >= 0.05). "
            "Decision rule: make graph_walk opt-in — set GUC default to 0.0 for free latency. "
            "Operators with rich mem_edge corpora can enable via SET pgmnemo.graph_proximity_weight = 0.2."
        )

    # Phase 1 overlay: if graph_walk changes nothing (overlap=1.0 for all queries)
    if overlap is not None and overlap >= 0.995:
        decision = "OPT-IN"
        rationale = (
            "Live-corpus ranking overlap = 1.000 — graph_walk reranks ZERO queries. "
            "No measurable recall effect. "
            + rationale
        )

    return {
        "decision": decision,
        "rationale": rationale,
        "signals": {
            "live_corpus_overlap_at_10": overlap,
            "ranking_change_rate_at_10": change_rate,
            "lat_with_graph_p50_ms": lat_with,
            "lat_no_cte_p50_ms": lat_nocte,
            "lat_cte_overhead_ms": lat_delta,
            "sig_significant_lift": sig_lift,
            "sig_significant_regression": sig_regr,
        },
        "recommended_action": (
            "No action — graph_walk is already the default."
            if decision == "KEEP"
            else (
                "Set GUC default pgmnemo.graph_proximity_weight = 0.0 in pgmnemo.control "
                "or document as opt-in in INSTALL.md."
                if decision == "OPT-IN"
                else "Remove graph_walk CTEs from recall_hybrid() and recall_lessons()."
            )
        ),
    }


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="pgmnemo #88 — graph_walk ablation benchmark"
    )
    parser.add_argument(
        "--dsn",
        default=os.environ.get(
            "DATABASE_URL",
            os.environ.get("PGMNEMO_DATABASE_URL", os.environ.get("PGMNEMO_DSN", "")),
        ),
    )
    parser.add_argument("--n-queries",       type=int, default=DEFAULT_N_QUERIES)
    parser.add_argument("--n-edge-anchors",  type=int, default=DEFAULT_N_EDGE_ANCHORS)
    parser.add_argument(
        "--output",
        default="benchmarks/results/graph_walk_ablation.json",
    )
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    if not args.dsn:
        raise SystemExit(
            "DATABASE_URL / PGMNEMO_DATABASE_URL / PGMNEMO_DSN required "
            "(or pass --dsn postgresql://...)"
        )

    random.seed(args.seed)

    print("=" * 72)
    print("pgmnemo #88 — graph_walk ablation benchmark")
    print(f"  DSN          : {args.dsn[:40]}...")
    print(f"  n_queries    : {args.n_queries}  (Phase 1 live corpus)")
    print(f"  n_edge_anchors: {args.n_edge_anchors}  (Phase 2 edge recall)")
    print(f"  output       : {args.output}")
    print("=" * 72)

    # ── Corpus stats ──────────────────────────────────────────────────────────
    conn = connect(args.dsn)
    cur  = conn.cursor()
    cur.execute(
        "SELECT COUNT(*) FROM pgmnemo.agent_lesson "
        "WHERE is_active AND verified_at IS NOT NULL AND t_valid_to = 'infinity'::TIMESTAMPTZ"
    )
    n_lessons = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM pgmnemo.mem_edge")
    n_edges_total = cur.fetchone()[0]
    cur.execute(
        "SELECT edge_kind, COUNT(*) FROM pgmnemo.mem_edge "
        "GROUP BY edge_kind ORDER BY 2 DESC"
    )
    edge_dist = {r[0]: r[1] for r in cur.fetchall()}
    cur.execute(
        "SELECT COUNT(*) FROM pgmnemo.mem_edge WHERE edge_kind IN ('causal','temporal')"
    )
    n_edges_traversed = cur.fetchone()[0]
    conn.close()

    print(f"\nCorpus: {n_lessons} active verified lessons, "
          f"{n_edges_total} mem_edges total "
          f"({n_edges_traversed} causal+temporal traversed by graph_walk)")
    print(f"Edge distribution: {edge_dist}")

    # ── Phase 1 ───────────────────────────────────────────────────────────────
    phase1 = phase1_ranking_overlap(args.dsn, args.n_queries)

    # ── Phase 2 ───────────────────────────────────────────────────────────────
    phase2 = phase2_edge_recall(args.dsn, args.n_edge_anchors)

    # ── Significance ─────────────────────────────────────────────────────────
    print("\n[Significance] Running two-proportion z-test + Holm-Bonferroni…")
    sig = significance_analysis(phase2)

    print("\n  Metric        Base    Cand    Δ       z       p_raw  p_corr  Sig?")
    print("  " + "-" * 70)
    for r in sig.get("results", []):
        print(
            f"  {r['metric']:<14} {r['p_baseline']:>6.4f}  {r['p_candidate']:>6.4f}  "
            f"{r['delta']:>+7.4f}  {r['z_stat']:>6.3f}  {r['p_raw']:>6.4f}  "
            f"{r['p_corrected']:>6.4f}  {'YES*' if r['significant'] else 'no':>4}"
        )

    # ── Decision ──────────────────────────────────────────────────────────────
    decision = make_decision(phase1, phase2, sig)
    print(f"\n[Decision] {decision['decision']}")
    print(f"  {decision['rationale']}")
    print(f"  Action: {decision['recommended_action']}")

    # ── Build output JSON ─────────────────────────────────────────────────────
    result = {
        "task": "pgmnemo #88 — graph_walk ablation",
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "version": "v0.10.0",
        "methodology": (
            "Phase 1: live-corpus ranking overlap — compare recall_hybrid with "
            "graph_proximity_weight=0.2 vs 0.0 on N random queries. "
            "Phase 2: edge-aware controlled recall — anchor lessons with outgoing "
            "causal/temporal edges; measure recall@K hit rate for edge targets "
            "WITH vs WITHOUT graph_walk boost. "
            "Significance: two-proportion z-test + Holm-Bonferroni correction (α=0.05)."
        ),
        "graph_walk_config": {
            "with_graph": {
                "guc": "pgmnemo.graph_proximity_weight",
                "value": GRAPH_WEIGHT_ON,
                "description": "default — graph_walk active, score *= (1 + 0.2 * proximity)",
            },
            "without_graph_guc": {
                "guc": "pgmnemo.graph_proximity_weight",
                "value": GRAPH_WEIGHT_OFF,
                "description": "GUC=0 — CTE still runs, score multiplier = 1.0 (no reranking)",
            },
            "without_graph_nocte": {
                "description": "inline SQL omitting graph_walk and graph_proximity CTEs entirely",
                "purpose": "true latency cost measurement",
            },
        },
        "corpus": {
            "database": "prod_corpus",
            "n_active_verified_lessons": n_lessons,
            "n_mem_edges_total": n_edges_total,
            "n_mem_edges_causal_temporal": n_edges_traversed,
            "edge_distribution": edge_dist,
        },
        "phase1_ranking_overlap": phase1,
        "phase2_edge_recall": phase2,
        "significance_test": sig,
        "decision": decision,
        # significance_test.py-compatible 'overall' section (Phase 2 metrics)
        "overall": {
            f"recall@{k}": {
                "mean": phase2.get("with_graph", {}).get(f"recall@{k}", 0.0),
                "n": phase2.get("recall_lift", {}).get("n", 0),
            }
            for k in KS
        },
        "overall_baseline": {
            f"recall@{k}": {
                "mean": phase2.get("without_graph", {}).get(f"recall@{k}", 0.0),
                "n": phase2.get("recall_lift", {}).get("n", 0),
            }
            for k in KS
        },
    }

    # ── Write output ──────────────────────────────────────────────────────────
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(result, indent=2))
    print(f"\n[bench] Results written to {out_path}")

    # Also write significance_test.py-compatible pair files
    base_path = out_path.parent / (out_path.stem + "_no_graph_sig.json")
    cand_path = out_path.parent / (out_path.stem + "_with_graph_sig.json")
    base_path.write_text(json.dumps({
        "version": f"{result['version']}_no_graph",
        "overall": result["overall_baseline"],
    }, indent=2))
    cand_path.write_text(json.dumps({
        "version": f"{result['version']}_with_graph",
        "overall": result["overall"],
    }, indent=2))
    print(f"[bench] Significance-test JSON pair: {base_path.name} vs {cand_path.name}")
    print(f"[bench] Run: python3 scripts/significance_test.py {base_path} {cand_path}")

    print(f"\n{'='*72}")
    print(f"RESULT: {decision['decision']}")
    print(f"  Rationale: {decision['rationale']}")
    print(f"{'='*72}")


if __name__ == "__main__":
    main()
