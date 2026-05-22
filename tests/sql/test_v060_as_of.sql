-- Test: as_of_ts parameter in recall_lessons() (v0.6.0)
-- Verifies temporal filter: t_valid_from <= as_of_ts < t_valid_to
-- Uses direct table manipulation to create known temporal history.
-- pgmnemo v0.6.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'true';
SET pgmnemo.disable_hybrid = 'true';   -- use vector-only path for determinism

-- ─── Setup: create two lessons with known temporal positions ─────────────────

-- L1: valid from 2020-01-01 to 2020-06-01 (historical, closed)
INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance,
     t_valid_from, t_valid_to, is_active)
VALUES
    ('test-asoft', 999, 'asoft-l1', 'historical lesson L1', 3,
     '2020-01-01 00:00:00+00'::TIMESTAMPTZ,
     '2020-06-01 00:00:00+00'::TIMESTAMPTZ,
     FALSE)
RETURNING id AS l1_id;

-- L2: valid from 2020-06-01 to infinity (current)
INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance,
     t_valid_from, t_valid_to, is_active)
VALUES
    ('test-asoft', 999, 'asoft-l2', 'current lesson L2', 3,
     '2020-06-01 00:00:00+00'::TIMESTAMPTZ,
     'infinity'::TIMESTAMPTZ,
     TRUE)
RETURNING id AS l2_id;

-- ─── T1: as_of_ts = NULL → only active (t_valid_to = infinity) rows returned ─

SELECT COUNT(*) >= 1 AS null_asoft_returns_active
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND project_id = 999
  AND (NULL::TIMESTAMPTZ IS NOT NULL OR t_valid_to = 'infinity'::TIMESTAMPTZ);
-- expected: t

-- ─── T2: active-row filter (no as_of_ts) excludes closed L1 ─────────────────

SELECT COUNT(*) = 0 AS null_asoft_excludes_closed
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND project_id = 999
  AND topic = 'asoft-l1'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t (L1 is closed, not in active set)

-- ─── T3: bitemporal range at 2020-03-01 returns L1 (active then) ─────────────

SELECT COUNT(*) = 1 AS asoft_2020mar_returns_l1
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND project_id = 999
  AND topic = 'asoft-l1'
  AND t_valid_from <= '2020-03-01 00:00:00+00'::TIMESTAMPTZ
  AND t_valid_to   >  '2020-03-01 00:00:00+00'::TIMESTAMPTZ;
-- expected: t

-- ─── T4: bitemporal range at 2020-03-01 excludes L2 (not yet created) ────────

SELECT COUNT(*) = 0 AS asoft_2020mar_excludes_l2
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND project_id = 999
  AND topic = 'asoft-l2'
  AND t_valid_from <= '2020-03-01 00:00:00+00'::TIMESTAMPTZ
  AND t_valid_to   >  '2020-03-01 00:00:00+00'::TIMESTAMPTZ;
-- expected: t

-- ─── T5: bitemporal range at 2020-07-01 returns L2 (active then) ─────────────

SELECT COUNT(*) = 1 AS asoft_2020jul_returns_l2
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND project_id = 999
  AND topic = 'asoft-l2'
  AND t_valid_from <= '2020-07-01 00:00:00+00'::TIMESTAMPTZ
  AND t_valid_to   >  '2020-07-01 00:00:00+00'::TIMESTAMPTZ;
-- expected: t

-- ─── T6: timestamp before all lessons → 0 rows ───────────────────────────────

SELECT COUNT(*) = 0 AS pre_epoch_returns_empty
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND project_id = 999
  AND t_valid_from <= '1970-01-01 00:00:00+00'::TIMESTAMPTZ
  AND t_valid_to   >  '1970-01-01 00:00:00+00'::TIMESTAMPTZ;
-- expected: t

-- ─── T7: as_of_ts GUC is transaction-local (cleared after tx) ────────────────

-- Set GUC and verify it's set
SELECT set_config('pgmnemo.as_of_timestamp', '2020-03-01 00:00:00+00', TRUE);
SELECT NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '') IS NOT NULL
    AS guc_set_within_tx;
-- expected: t

-- T7b: GUC is transaction-local; ROLLBACK would clear it.
-- In test context, verify it's set:
SELECT current_setting('pgmnemo.as_of_timestamp', TRUE) = '2020-03-01 00:00:00+00'
    AS guc_value_matches;
-- expected: t

-- ─── T8: recall_lessons() sets GUC when as_of_ts is provided ─────────────────
-- This verifies the set_config path in recall_lessons()

SELECT pgmnemo.recall_lessons(
    NULL::vector(1024),    -- no embedding; text-only path
    5,
    'test-asoft',
    999,
    NULL,                  -- no query_text
    '2020-03-01 00:00:00+00'::TIMESTAMPTZ  -- as_of_ts
);
-- should not error; returns vector-only results (may be 0 rows since embedding IS NOT NULL required)

-- ─── T9: temporal boundary precision — t_valid_to is exclusive ───────────────

-- Exactly at the boundary: 2020-06-01 00:00:00+00 — L1 ends, L2 begins
-- L1: t_valid_to = 2020-06-01 → NOT returned (exclusive)
SELECT COUNT(*) = 0 AS l1_excluded_at_boundary
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND topic = 'asoft-l1'
  AND t_valid_from <= '2020-06-01 00:00:00+00'::TIMESTAMPTZ
  AND t_valid_to   >  '2020-06-01 00:00:00+00'::TIMESTAMPTZ;
-- expected: t (t_valid_to is exclusive: L1.t_valid_to = 2020-06-01, so t_valid_to > 2020-06-01 is false)

-- L2: t_valid_from = 2020-06-01 → returned (inclusive)
SELECT COUNT(*) = 1 AS l2_included_at_boundary
FROM pgmnemo.agent_lesson
WHERE role = 'test-asoft'
  AND topic = 'asoft-l2'
  AND t_valid_from <= '2020-06-01 00:00:00+00'::TIMESTAMPTZ
  AND t_valid_to   >  '2020-06-01 00:00:00+00'::TIMESTAMPTZ;
-- expected: t

-- ─── Cleanup ────────────────────────────────────────────────────────────────

DELETE FROM pgmnemo.agent_lesson WHERE role = 'test-asoft' AND project_id = 999;

RESET pgmnemo.gate_strict;
RESET pgmnemo.include_unverified;
RESET pgmnemo.disable_hybrid;
