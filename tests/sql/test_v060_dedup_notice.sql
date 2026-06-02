-- Test: RAISE NOTICE on bitemporal close+create (RFC Q5)
-- pgmnemo v0.6.0
-- NOTICE content: "bitemporal close+create fired — closed N prior version(s) (content_hash=...). New lesson_id=..."
--
-- pgregress does not capture RAISE NOTICE content in .out files by default.
-- These tests verify the NOTICE mechanism indirectly via row state transitions.
-- For direct NOTICE capture, use: psql --set ON_ERROR_STOP=1 2>&1 | grep "bitemporal close"
--
-- Pattern: psql -v VERBOSITY=default <test.sql> 2>&1 | grep "NOTICE.*bitemporal"

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'true';

-- ─── T1: initial ingest — no prior row → no NOTICE fires ─────────────────────

SELECT pgmnemo.ingest('test-notice', 997, 'topic-dedup', 'original content v1',
                      3, NULL, 'sha-notice-001', NULL, '{}') AS first_id;

-- Exactly 1 active row after first ingest
SELECT COUNT(*) = 1 AS initial_lesson_active
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- No closed rows yet
SELECT COUNT(*) = 0 AS no_closed_rows_initially
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to < 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T2: second ingest with same role+topic+commit_sha → triggers close+create ─
-- NOTICE fires: "bitemporal close+create fired — closed 1 prior version(s)"
-- (content_hash = MD5('test-notice|topic-dedup|sha-notice-001'))

SELECT pgmnemo.ingest('test-notice', 997, 'topic-dedup', 'updated content v2',
                      3, NULL, 'sha-notice-001', NULL, '{}') AS second_id;

-- After dedup: exactly 1 active row (the new v2)
SELECT COUNT(*) = 1 AS one_active_after_dedup
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- The original v1 was closed (t_valid_to = trigger's now())
SELECT COUNT(*) = 1 AS closed_row_exists
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to < 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T3: closed row has lesson_text from original ingest ─────────────────────

SELECT lesson_text = 'original content v1' AS closed_row_has_original_text
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to < 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T4: active row has updated lesson_text ───────────────────────────────────

SELECT lesson_text = 'updated content v2' AS active_row_has_updated_text
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T5: idempotent re-run (same content_hash) → NOTICE fires again ──────────
-- Triggers close of v2, creates v3.

SELECT pgmnemo.ingest('test-notice', 997, 'topic-dedup', 'updated content v3 idempotent',
                      3, NULL, 'sha-notice-001', NULL, '{}') AS third_id;

-- Still exactly 1 active row
SELECT COUNT(*) = 1 AS still_one_active_after_idempotent
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- Now 2 closed rows (v1 and v2)
SELECT COUNT(*) = 2 AS two_closed_rows_after_idempotent
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-dedup'
  AND t_valid_to < 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T6: content_hash formula verification ────────────────────────────────────
-- Verify our content_hash computation matches the GENERATED ALWAYS AS formula:
--   MD5(COALESCE(role,'') || '|' || COALESCE(topic,'') || '|' || COALESCE(commit_sha, artifact_hash, ''))

SELECT
    MD5('test-notice' || '|' || 'topic-dedup' || '|' || 'sha-notice-001')
        = (SELECT DISTINCT content_hash
           FROM pgmnemo.agent_lesson
           WHERE role = 'test-notice' AND topic = 'topic-dedup'
           LIMIT 1) AS content_hash_matches_formula;
-- expected: t

-- ─── T7: no-provenance ingest — no NOTICE fires (content_hash dedup by commit_sha) ─
-- Without commit_sha/artifact_hash, content_hash = MD5('role|topic|')
-- Two ingests with same role+topic but no provenance → same content_hash → NOTICE fires

SELECT pgmnemo.ingest('test-notice', 997, 'topic-noprov', 'no-prov v1',
                      3, NULL, NULL, NULL, '{}') AS noprov_v1;

SELECT pgmnemo.ingest('test-notice', 997, 'topic-noprov', 'no-prov v2',
                      3, NULL, NULL, NULL, '{}') AS noprov_v2;

-- After second no-prov ingest: 1 active, 1 closed
SELECT COUNT(*) = 1 AS one_active_noprov
FROM pgmnemo.agent_lesson
WHERE role = 'test-notice'
  AND project_id = 997
  AND topic = 'topic-noprov'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T8: direct NOTICE verification (manual; not run by pgregress) ───────────
-- pgregress does not capture RAISE NOTICE in .out comparison by default.
-- To assert NOTICE fires and token matches, run manually:
--
--   psql "$DSN" -v ON_ERROR_STOP=1 -f tests/sql/test_v060_dedup_notice.sql 2>&1 \
--     | grep -c "bitemporal close+create fired"
--
-- Expected count: ≥ 2  (fires for T2 second ingest + T5 idempotent re-run + T7 noprov).
-- This is the parseable signal documented in RFC Q5.

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

DELETE FROM pgmnemo.agent_lesson WHERE role = 'test-notice' AND project_id = 997;

RESET pgmnemo.gate_strict;
RESET pgmnemo.include_unverified;
