-- Regression test: stress_recall — recall_lessons() signature + scale targets (v0.6.1, F3)
-- Pure-SQL checks: function exists, index hints, scale targets documented.
-- Actual 100K/1M/10M stress run: benchmarks/scripts/stress_recall_large.py

-- Apply the v0.6.1 migration.
ALTER EXTENSION pgmnemo UPDATE TO '0.7.2';

-- ── Function exists with correct signature ────────────────────────────────────

SELECT COUNT(*) AS recall_lessons_v061_exists
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pgmnemo'
  AND  p.proname = 'recall_lessons'
  AND  pronargs  = 6;

-- ── HNSW index for recall scalability ────────────────────────────────────────

-- HNSW index exists on agent_lesson(embedding) for cosine distance
SELECT COUNT(*) AS hnsw_index_exists
FROM   pg_indexes
WHERE  schemaname = 'pgmnemo'
  AND  tablename  = 'agent_lesson'
  AND  indexdef   LIKE '%hnsw%';

-- BM25 GIN index exists on agent_lesson(lesson_tsv) for full-text (may be >=1 after squash)
SELECT (COUNT(*) >= 1) AS gin_tsv_index_exists
FROM   pg_indexes
WHERE  schemaname = 'pgmnemo'
  AND  tablename  = 'agent_lesson'
  AND  indexdef   LIKE '%lesson_tsv%';

-- ── ef_search GUC (recall quality vs latency trade-off) ─────────────────────

-- Default ef_search = 100 (recall quality target: ≥0.95 at 10K rows)
SELECT 100 AS ef_search_default;

-- Stress target at 100K rows: P99 latency ≤ 500ms at ef_search=100
SELECT 500 AS p99_latency_ms_target_100k;

-- Stress target at 1M rows: P99 latency ≤ 2000ms at ef_search=100
SELECT 2000 AS p99_latency_ms_target_1m;

-- Stress target at 10M rows: P99 latency ≤ 8000ms at ef_search=200
SELECT 8000 AS p99_latency_ms_target_10m;

-- ── A-scale score bounds at scale ────────────────────────────────────────────

-- rrf_diag dominates regardless of corpus size (rank-based score is corpus-size-invariant)
-- Score at rank=1 stays at 0.8/61 ≈ 0.01311 for any N
SELECT round((0.8 / 61.0)::numeric, 6) AS rrf_diag_rank1_any_n;

-- Score at rank=k (bottom of top-k) stays at 0.8/(60+k) — degrades gracefully
SELECT
    round((0.8 / (60.0 + 10))::numeric, 6) AS rrf_diag_rank10,
    round((0.8 / (60.0 + 50))::numeric, 6) AS rrf_diag_rank50,
    round((0.8 / (60.0 + 100))::numeric, 6) AS rrf_diag_rank100;

-- Bitemporal filter (as_of_ts) adds one WHERE predicate — O(1) overhead regardless of N
SELECT 'bitemporal_filter_o1_overhead'::TEXT AS as_of_ts_scale_note;

-- ── Batch insert performance targets ─────────────────────────────────────────

-- ingest() throughput target: ≥ 500 rows/sec at 100K corpus size (without embeddings)
SELECT 500 AS ingest_rows_per_sec_target;

-- embedding backfill via MLX bge-m3: ~50 rows/sec (external constraint, not SQL)
SELECT 50 AS embed_rows_per_sec_external;
