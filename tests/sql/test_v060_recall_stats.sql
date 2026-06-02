-- Test: pgmnemo.recall_stats view (RFC R9, v0.6.0)
-- Verifies view exists and expected columns are present.
-- NOTE: calls/total_time/self_time may be 0 if track_functions='none';
--       this test only checks structural presence, not live counter values.

-- ─── T1: view exists ──────────────────────────────────────────────────────────

SELECT COUNT(*) = 1 AS recall_stats_view_exists
FROM information_schema.views
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'recall_stats';
-- expected: t

-- ─── T2: expected columns present ────────────────────────────────────────────

SELECT
    bool_and(col IN ('schema','function_name','calls','total_time','self_time','observed_at'))
    AS all_expected_cols_present
FROM (
    SELECT column_name AS col
    FROM information_schema.columns
    WHERE table_schema = 'pgmnemo'
      AND table_name   = 'recall_stats'
) t;
-- expected: t

-- ─── T3: column count is exactly 6 ───────────────────────────────────────────

SELECT COUNT(*) = 6 AS recall_stats_has_6_cols
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'recall_stats';
-- expected: t

-- ─── T4: view is queryable and filters to pgmnemo schema ─────────────────────

SELECT COUNT(*) >= 0 AS recall_stats_queryable
FROM pgmnemo.recall_stats;
-- expected: t (0 rows is fine when track_functions='none')

SELECT COALESCE(bool_and(schema = 'pgmnemo'), true) AS all_rows_are_pgmnemo_schema
FROM pgmnemo.recall_stats;
-- expected: t
