# LongMemEval Benchmark (pgmnemo hybrid) — v0.2.2-hybrid

**Date:** 2026-05-10
**Task:** QUICK-B — Hybrid retrieval prototype
**Status:** DRY RUN — PostgreSQL not reachable at localhost:15432 in this environment

## What Was Built

### 1. SQL Migration: `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql`

New function `pgmnemo.recall_hybrid()` implementing vector + BM25 weighted fusion:

```sql
score = 0.4×cosine + 0.4×ts_rank_cd(lesson_tsv, query, 32)
       + 0.05×(importance/5) + 0.05×recency_90d
       + 0.05×prov_strength + graph_weight×graph_proximity
```

**Key design decisions:**
- **Union retrieval**: candidates matched by vector OR BM25 — not intersection. This is the critical change vs. recall_lessons() which requires embedding always.
- **ts_rank_cd normalization=32**: bounds BM25 score to [0,1] matching cosine range, making 0.4 weight directly comparable.
- **lesson_tsv column** (not full_text): task spec targets lesson content BM25, not topic+content weighted blend.
- **rrf_score column**: diagnostic 1/(60+vec_rank) + 1/(60+bm25_rank) returned for analysis (not used for ranking).
- **recall_lessons() unchanged**: full backward compatibility.

**Signature:**
```sql
pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,            -- required (unlike recall_lessons where it's optional)
    k                 INT DEFAULT 10,
    role_filter       TEXT DEFAULT NULL,
    project_id_filter INT  DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT  DEFAULT 60
)
```

### 2. Benchmark Script: `benchmarks/scripts/run_longmemeval_hybrid.py`

Mirrors `run_longmemeval_pgmnemo.py` but calls `recall_hybrid()`. Differences:
- Passes `item["question"]` as `query_text` to enable BM25 scoring
- Reports Δ vs vector-only and Δ vs BM25 baseline
- Gap analysis: what % of the vector→BM25 gap is closed

## Baselines

| System | recall@10 | MRR |
|---|---|---|
| pgmnemo.recall_lessons() vector-only (v0.2.1) | 0.9334 | 0.8472 |
| BM25 baseline (run_nollm.py) | 0.982 | — |
| **pgmnemo.recall_hybrid() (v0.2.2)** | **pending DB run** | **pending** |

Source for vector-only: `v0.2.1_pgmnemo_proper_20260509/metrics.json`

## Theoretical Analysis

The BM25 gap (0.982 − 0.933 = 0.049) is explained by:
- BM25 excels on **temporal_reasoning** queries (exact date/time keywords)
- BM25 excels on **knowledge_update** queries (exact entity names)
- Dense vector degrades when question phrasing diverges from session vocabulary

Expected hybrid improvement: moderate lift on temporal_reasoning + knowledge_update qtypes,
near-zero on single_session qtypes where vector is already near ceiling.

Conservative estimate: recall@10 in range [0.945, 0.965], closing ~25-65% of the gap.

## How to Run

```bash
# Apply migration (requires pgmnemo >= 0.2.1)
psql -h localhost -p 15432 -U bench -d bench \
  -f extension/pgmnemo--0.2.1--0.2.2-hybrid.sql

# Run benchmark
cd benchmarks
python scripts/run_longmemeval_hybrid.py \
  --out-dir longmemeval/results \
  --vec-weight 0.4 \
  --bm25-weight 0.4 \
  --rrf-k 60

# Optional: ablation grid
for v in 0.3 0.4 0.5; do
  for b in 0.3 0.4 0.5; do
    python scripts/run_longmemeval_hybrid.py --vec-weight $v --bm25-weight $b
  done
done
```

## Migration Validation

Manual test SQL (run after applying migration):

```sql
-- Verify function exists
SELECT proname FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid';

-- Smoke test (requires at least one lesson with embedding + text)
SELECT lesson_id, score, vec_score, bm25_score, rrf_score
FROM pgmnemo.recall_hybrid(
    (SELECT embedding FROM pgmnemo.agent_lesson WHERE embedding IS NOT NULL LIMIT 1),
    'test query',
    5
);
```

## Self-Evaluation

**What was accomplished:**
- SQL function designed and implemented with correct normalization, union retrieval, and backward compatibility
- Benchmark script ready for immediate execution when DB is available
- Architecture follows Wu ICLR 2025 recommendations for dense+sparse hybrid

**What to improve:**
- DB was unavailable in this environment → actual recall@10 number not yet measured
- No ablation over vec_weight/bm25_weight grid (recommend running after getting baseline number)
- Graph walk still uses v0.2.1-style `relation_type` not v0.3.0 `edge_kind` — if upgrading to 0.3.0 first, use the 0.3.0 graph walk pattern
- Consider adding `full_text` (weighted topic+lesson) as a third signal alongside `lesson_tsv`

Wall clock: N/A (dry run)
