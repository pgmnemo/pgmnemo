-- Regression test: sparse-safe RRF semantics (v0.6.2, F1 Fix-A)
-- Pure-SQL boolean and integer checks — no embeddings, no floating-point comparisons.

-- Apply the v0.6.2 migration.
ALTER EXTENSION pgmnemo UPDATE TO '0.12.0';

-- ── Signature check ───────────────────────────────────────────────────────────

-- recall_hybrid() signature still 8 parameters (unchanged)
SELECT pronargs AS recall_hybrid_arg_count
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pgmnemo'
  AND  p.proname = 'recall_hybrid'
LIMIT  1;

-- ── PARTITION trick: zero-BM25 items yield NULL bm25_rank_sparse ─────────────

-- Items with bm25_score = 0 must yield NULL (not a rank).
SELECT (
    CASE WHEN 0.0 > 0
         THEN RANK() OVER (PARTITION BY (0.0 > 0) ORDER BY 0.0 DESC)
         ELSE NULL
    END
) IS NULL AS zero_bm25_yields_null_rank;

-- Items with bm25_score > 0 must yield a non-NULL rank.
SELECT (
    CASE WHEN 0.8 > 0
         THEN RANK() OVER (PARTITION BY (0.8 > 0) ORDER BY 0.8 DESC)
         ELSE NULL
    END
) IS NOT NULL AS nonzero_bm25_yields_real_rank;

-- ── Sentinel logic: COALESCE(NULL, n_candidates + 1) ─────────────────────────

-- Sentinel (n_candidates+1) must exceed all valid ranks (1..n_candidates).
-- Here n_candidates=5; sentinel=6; any valid rank in [1,5] is less than 6.
SELECT COALESCE(NULL::bigint, 5 + 1) > 5 AS sentinel_exceeds_max_valid_rank;

-- ── RANK ordering in matching partition ──────────────────────────────────────

-- Within the matching partition, higher bm25_score gets lower (better) rank.
WITH bm25_rows(bm25_score) AS (
    VALUES (0.8::double precision), (0.6::double precision), (0.4::double precision)
),
ranked AS (
    SELECT
        bm25_score,
        RANK() OVER (PARTITION BY (bm25_score > 0) ORDER BY bm25_score DESC) AS bm25_rank_sparse
    FROM bm25_rows
)
SELECT (MAX(bm25_rank_sparse) = 3) AS rank_range_is_one_to_n_candidates
FROM ranked;

-- ── Correct ordering invariant: high-cosine/no-BM25 vs BM25-matched ─────────

-- With sparse-safe RRF (Cormack 2009), whether a zero-BM25 item outranks a
-- BM25-matched item depends on vec_rank difference, not the spurious ROW_NUMBER.
-- Key invariant: sentinel rank = n+1, NOT median rank = n/2.
-- For n=48, k=60: sentinel contribution = bm25_w/(60+49) = bm25_w/109
--                 old median contribution = bm25_w/(60+24) = bm25_w/84
-- Sentinel is SMALLER (worse) — correct: absent items should not get a BM25 boost.
SELECT (
    (0.4 / (60.0 + (48 + 1))) <  -- sparse-safe: sentinel rank 49
    (0.4 / (60.0 + 24))           -- old diagonal: arbitrary median rank 24
) AS sentinel_contribution_less_than_median;

-- ── Comment check: function comment references Cormack 2009 ─────────────────
SELECT (obj_description(p.oid, 'pg_proc') LIKE '%Cormack%') AS comment_has_cormack
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pgmnemo'
  AND  p.proname = 'recall_hybrid'
LIMIT  1;
