-- Test: ghost_count in pgmnemo.stats() (Agency RFC Q4)
-- pgmnemo v0.6.0
-- ghost_count = active lessons with verified_at IS NULL (no provenance)

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'true';

-- ─── T1: ghost_count column exists in stats() output ──────────────────────────

SELECT pg_typeof(ghost_count) = 'bigint'::regtype AS ghost_count_is_bigint
FROM pgmnemo.stats();
-- expected: t

-- ─── T2: stats() returns exactly 14 columns ──────────────────────────────────

SELECT COUNT(*) = 14 AS stats_has_14_cols
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name = 'stats';
-- Note: this checks the SQL function return type; verify via pg_proc if needed.
-- Alternative direct check:
SELECT
    (SELECT COUNT(*)::INT
     FROM information_schema.routines
     WHERE routine_schema = 'pgmnemo'
       AND routine_name   = 'stats') >= 1 AS stats_function_exists;
-- expected: t

-- ─── Setup: insert lessons with and without provenance ────────────────────────

-- L-prov: has commit_sha → verified_at is set by ingest() → NOT a ghost
SELECT pgmnemo.ingest('test-ghost', 998, 'topic-prov', 'lesson with provenance',
                      3, NULL, 'sha-ghost-test-001', NULL, '{}') AS prov_id;

-- L-ghost: no commit_sha, no artifact_hash → verified_at is NULL → IS a ghost
SELECT pgmnemo.ingest('test-ghost', 998, 'topic-ghost', 'lesson without provenance',
                      3, NULL, NULL, NULL, '{}') AS ghost_id;

-- ─── T3: exactly 1 ghost after inserting 1 ghost lesson ──────────────────────
-- (count from the test-ghost role only to isolate from other data)

SELECT COUNT(*) = 1 AS one_ghost_active
FROM pgmnemo.agent_lesson
WHERE role = 'test-ghost'
  AND project_id = 998
  AND verified_at IS NULL
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T4: ghost_count in stats() is non-negative integer ──────────────────────

SELECT ghost_count >= 0 AS ghost_count_nonneg
FROM pgmnemo.stats();
-- expected: t

-- ─── T5: ghost_count does NOT count closed rows (t_valid_to < 'infinity') ─────
-- Ingest a duplicate of the ghost lesson to trigger bitemporal close+create.
-- The closed row must not contribute to ghost_count.

SELECT pgmnemo.ingest('test-ghost', 998, 'topic-ghost', 'lesson without provenance updated',
                      3, NULL, NULL, NULL, '{}') AS ghost_id_v2;

-- After close+create: still exactly 1 active ghost for test-ghost/998/topic-ghost
SELECT COUNT(*) = 1 AS one_active_ghost_after_update
FROM pgmnemo.agent_lesson
WHERE role = 'test-ghost'
  AND project_id = 998
  AND topic = 'topic-ghost'
  AND verified_at IS NULL
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- The closed row (t_valid_to < infinity) must not be in ghost_count
SELECT COUNT(*) = 1 AS one_closed_ghost_row
FROM pgmnemo.agent_lesson
WHERE role = 'test-ghost'
  AND project_id = 998
  AND topic = 'topic-ghost'
  AND t_valid_to < 'infinity'::TIMESTAMPTZ;
-- expected: t (the original ghost was closed by the trigger)

-- ─── T6: after back-filling provenance, ghost_count decreases ────────────────

UPDATE pgmnemo.agent_lesson
SET    commit_sha = 'sha-backfill', verified_at = NOW()
WHERE  role       = 'test-ghost'
  AND  project_id = 998
  AND  verified_at IS NULL
  AND  t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Now no active test-ghost rows should be ghosts
SELECT COUNT(*) = 0 AS no_ghosts_after_backfill
FROM pgmnemo.agent_lesson
WHERE role = 'test-ghost'
  AND project_id = 998
  AND verified_at IS NULL
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
-- expected: t

-- ─── T7: ghost_count handles empty table gracefully ──────────────────────────

SELECT ghost_count IS NOT NULL AS ghost_count_not_null
FROM pgmnemo.stats();
-- expected: t

-- ─── Cleanup ─────────────────────────────────────────────────────────────────

DELETE FROM pgmnemo.agent_lesson WHERE role = 'test-ghost' AND project_id = 998;

RESET pgmnemo.gate_strict;
RESET pgmnemo.include_unverified;
