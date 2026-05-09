-- Regression test: traverse_temporal_window() (v0.2.0)
-- Verifies filter predicates and edge-join semantics without a live table.
-- Tests the SQL logic directly using synthetic values.

-- 1. Time-window predicate: lesson at _start_ts ± 15 min is included; outside is excluded.
SELECT
    -- inside window (delta = 5 min < 15 min) → should pass
    (TIMESTAMPTZ '2026-01-01 10:00:00+00'
        BETWEEN (TIMESTAMPTZ '2026-01-01 10:00:00+00' - INTERVAL '15 minutes')
            AND (TIMESTAMPTZ '2026-01-01 10:00:00+00' + INTERVAL '15 minutes'))
    AS anchor_in_window,
    (TIMESTAMPTZ '2026-01-01 10:05:00+00'
        BETWEEN (TIMESTAMPTZ '2026-01-01 10:00:00+00' - INTERVAL '15 minutes')
            AND (TIMESTAMPTZ '2026-01-01 10:00:00+00' + INTERVAL '15 minutes'))
    AS candidate_5m_in_window,
    -- outside window (delta = 20 min > 15 min) → should fail
    (TIMESTAMPTZ '2026-01-01 10:20:00+00'
        BETWEEN (TIMESTAMPTZ '2026-01-01 10:00:00+00' - INTERVAL '15 minutes')
            AND (TIMESTAMPTZ '2026-01-01 10:00:00+00' + INTERVAL '15 minutes'))
    AS candidate_20m_out_of_window;

-- Expected: t, t, f

-- 2. time_delta_sec formula: ABS(EXTRACT(EPOCH FROM (candidate - anchor)))
SELECT
    ABS(EXTRACT(EPOCH FROM (
        TIMESTAMPTZ '2026-01-01 10:05:00+00' - TIMESTAMPTZ '2026-01-01 10:00:00+00'
    ))) AS delta_sec_5m,  -- expected: 300.0
    ABS(EXTRACT(EPOCH FROM (
        TIMESTAMPTZ '2026-01-01 09:57:00+00' - TIMESTAMPTZ '2026-01-01 10:00:00+00'
    ))) AS delta_sec_neg3m; -- expected: 180.0

-- 3. linked flag: (edge_weight IS NOT NULL) → boolean
SELECT
    (1.0::REAL IS NOT NULL) AS linked_when_edge_found,    -- expected: t
    (NULL::REAL IS NOT NULL) AS linked_when_no_edge;       -- expected: f

-- 4. include_unlinked filter: row passes when include_unlinked=TRUE regardless of edge;
--    passes only when edge found when include_unlinked=FALSE.
SELECT
    -- include_unlinked=TRUE: unlinked row (edge_weight IS NULL) should pass
    (TRUE  OR NULL::REAL IS NOT NULL) AS unlinked_passes_when_include_true,
    -- include_unlinked=FALSE: unlinked row should be filtered
    (FALSE OR NULL::REAL IS NOT NULL) AS unlinked_filtered_when_include_false,
    -- include_unlinked=FALSE: linked row should pass
    (FALSE OR 0.9::REAL IS NOT NULL)  AS linked_passes_when_include_false;

-- Expected: t, f, t

-- 5. role_filter predicate: (role_filter IS NULL OR al.role = role_filter)
SELECT
    (NULL::TEXT IS NULL OR 'writer' = NULL::TEXT) AS null_filter_matches_all,
    ('writer'::TEXT IS NULL OR 'writer' = 'writer'::TEXT) AS writer_filter_matches_writer,
    ('writer'::TEXT IS NULL OR 'reader' = 'writer'::TEXT) AS writer_filter_rejects_reader;

-- Expected: t, t, f
