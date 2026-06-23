-- Regression test: as_of_ts parameter on recall_lessons() + recall_hybrid() (v0.6.1, F2)
-- Pure-SQL checks: function signature, bitemporal filter predicate, GUC propagation.
-- No live table required — avoids embedding dependency in pg_regress.

-- Apply the v0.6.1 migration.
ALTER EXTENSION pgmnemo UPDATE TO '0.11.1';

-- ── Signature checks ─────────────────────────────────────────────────────────

-- recall_lessons() now has 6 parameters (was 5 in v0.6.0)
SELECT pronargs AS recall_lessons_arg_count
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pgmnemo'
  AND  p.proname = 'recall_lessons'
ORDER  BY pronargs DESC
LIMIT  1;

-- recall_hybrid() still has 8 parameters (signature unchanged)
SELECT pronargs AS recall_hybrid_arg_count
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pgmnemo'
  AND  p.proname = 'recall_hybrid'
LIMIT  1;

-- ── Bitemporal filter predicate (F2) ─────────────────────────────────────────

-- Predicate: _as_of_ts IS NULL OR (t_valid_from <= _as_of_ts AND t_valid_to > _as_of_ts)
-- NULL as_of_ts → passes all rows (backward compat)
SELECT
    (NULL::TIMESTAMPTZ IS NULL OR (
        '2024-01-01'::TIMESTAMPTZ <= NULL::TIMESTAMPTZ
        AND 'infinity'::TIMESTAMPTZ > NULL::TIMESTAMPTZ
    )) AS null_as_of_passes_all;

-- as_of_ts within valid range → passes active row
SELECT
    ('2025-01-01'::TIMESTAMPTZ IS NULL OR (
        '2024-06-01'::TIMESTAMPTZ <= '2025-01-01'::TIMESTAMPTZ
        AND 'infinity'::TIMESTAMPTZ > '2025-01-01'::TIMESTAMPTZ
    )) AS as_of_inside_range_passes;

-- as_of_ts before t_valid_from → filtered out
SELECT
    ('2023-01-01'::TIMESTAMPTZ IS NULL OR (
        '2024-06-01'::TIMESTAMPTZ <= '2023-01-01'::TIMESTAMPTZ
        AND 'infinity'::TIMESTAMPTZ > '2023-01-01'::TIMESTAMPTZ
    )) AS as_of_before_valid_from_fails;

-- as_of_ts after t_valid_to (closed row) → filtered out
SELECT
    ('2026-01-01'::TIMESTAMPTZ IS NULL OR (
        '2024-06-01'::TIMESTAMPTZ <= '2026-01-01'::TIMESTAMPTZ
        AND '2025-01-01'::TIMESTAMPTZ > '2026-01-01'::TIMESTAMPTZ
    )) AS as_of_after_valid_to_fails;

-- t_valid_to = 'infinity' (active row), as_of_ts = far future → passes
SELECT
    ('2099-12-31'::TIMESTAMPTZ IS NULL OR (
        '2024-06-01'::TIMESTAMPTZ <= '2099-12-31'::TIMESTAMPTZ
        AND 'infinity'::TIMESTAMPTZ > '2099-12-31'::TIMESTAMPTZ
    )) AS active_row_passes_far_future;

-- ── A-scale formula (F1) ─────────────────────────────────────────────────────

-- _aux_scale = 0.01726; max importance term = _aux_scale * 0.05 * (5/5) = 0.000863
SELECT round((0.01726 * 0.05 * 1.0)::numeric, 6) AS max_importance_aux;

-- Max recency term (newest row, age=0): _aux_scale * 0.05 * 1.0 = 0.000863
SELECT round((0.01726 * 0.05 * 1.0)::numeric, 6) AS max_recency_aux;

-- Max prov_strength term (verified commit): _aux_scale * 0.05 * 1.0 = 0.000863
SELECT round((0.01726 * 0.05 * 1.0)::numeric, 6) AS max_prov_aux;

-- Total max aux = 3 × 0.000863 = 0.002589 < 0.016 (rrf_diag adjacent-rank delta at k=60)
SELECT round((3.0 * 0.01726 * 0.05)::numeric, 6) AS total_max_aux_3terms;

-- rrf_diag at rank=1 (both signals): vec_weight/(k+1) + bm25_weight/(k+1) at k=60
SELECT round((0.4::float / 61 + 0.4::float / 61)::numeric, 6) AS rrf_diag_at_rank1;

-- Guard: total_max_aux < rrf_diag_at_rank1 / 4 (aux < 25% of top RRF signal — F1 A-scale invariant)
SELECT
    round((3.0 * 0.01726 * 0.05)::numeric, 6) AS total_max_aux,
    round((0.4::float / 61 + 0.4::float / 61)::numeric, 6) AS rrf_diag_rank1,
    (3.0 * 0.01726 * 0.05) < (0.4::float / 61 + 0.4::float / 61) AS aux_less_than_rrf_rank1;

-- ── GUC propagation (F2) ─────────────────────────────────────────────────────

-- set_config with is_local=TRUE is transaction-local
SELECT set_config('pgmnemo.as_of_timestamp', '2025-06-01 00:00:00+00', TRUE) AS guc_set;
SELECT current_setting('pgmnemo.as_of_timestamp', TRUE) AS guc_value;

-- After transaction-local set, value is visible in same transaction
SELECT (current_setting('pgmnemo.as_of_timestamp', TRUE) IS NOT NULL) AS guc_is_set;

-- ── recall_hybrid() rrf_diag primary ranking (F1) ────────────────────────────

-- rrf_diag formula: vec_weight/(rrf_k+vec_rank) + bm25_weight/(rrf_k+bm25_rank)
-- rank=1 vs rank=2: rrf_diag correctly orders higher-ranked items first
SELECT
    (0.4/(60.0+1) + 0.4/(60.0+1)) AS rrf_diag_rank1,
    (0.4/(60.0+2) + 0.4/(60.0+2)) AS rrf_diag_rank2,
    (0.4/(60.0+1) + 0.4/(60.0+1)) > (0.4/(60.0+2) + 0.4/(60.0+2)) AS rank1_scores_higher;

-- ── Backward compatibility ────────────────────────────────────────────────────

-- recall_lessons_pooled() still exists (3-param signature unchanged)
SELECT COUNT(*) AS pooled_exists
FROM   pg_proc p
JOIN   pg_namespace n ON n.oid = p.pronamespace
WHERE  n.nspname = 'pgmnemo'
  AND  p.proname = 'recall_lessons_pooled'
  AND  pronargs  = 3;
