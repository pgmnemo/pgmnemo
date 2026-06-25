-- recall_recency.sql
-- pg_regress tests for pgmnemo v0.9.5: recall-recency signals + mark_stale()
-- RFC-PGM-CURATE-260619
--
-- Coverage:
--   T1: After recall_hybrid(), last_recalled_at is stamped on returned lessons
--   T2: recall_count increments by 1 per call
--   T3: GUC OFF (pgmnemo.track_recall_recency=off) — no stamping occurs
--   T4: mark_stale() dry_run=TRUE returns candidates, no state change
--   T5: mark_stale() dry_run=FALSE deprecates eligible lessons
--   T6: mark_stale() safeguard — confidence >= 0.6 lesson NOT deprecated
--   T7: mark_stale() safeguard — importance=5 lesson NOT deprecated
--   T8: mark_stale() safeguard — commit_sha provenance NOT deprecated
--   T9: mark_stale() cap: candidates > cap → RAISE NOTICE, no action

-- Prerequisites: pgmnemo 0.9.4+ installed. gate_strict=off for raw INSERTs.
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

ALTER EXTENSION pgmnemo UPDATE TO '0.12.0';

-- Confirm new columns exist (boolean check avoids alignment-sensitive output)
SELECT
    SUM(CASE WHEN column_name = 'last_recalled_at' THEN 1 ELSE 0 END) = 1 AS has_last_recalled_at,
    SUM(CASE WHEN column_name = 'recall_count'     THEN 1 ELSE 0 END) = 1 AS has_recall_count
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name = 'agent_lesson'
  AND column_name IN ('last_recalled_at', 'recall_count');

-- =============================================================================
-- Setup: lessons for T1/T2/T3 (recall stamping)
-- Unique role 'tc_e_rr' isolates these rows from real corpus.
-- Three rows, identical query-matching text, distinct commit_sha to avoid
-- the bitemporality chain-close trigger (which deduplicates by content_hash).
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES
    ('tc_e_rr', 'recency_test', 'recall recency stamp lesson xylophone quasar nebula bravo foxtrot', 'rr-sha-1'),
    ('tc_e_rr', 'recency_test', 'recall recency stamp lesson xylophone quasar nebula bravo foxtrot', 'rr-sha-2'),
    ('tc_e_rr', 'recency_test', 'recall recency stamp lesson xylophone quasar nebula bravo foxtrot', 'rr-sha-3');

-- =============================================================================
-- T1: last_recalled_at is stamped on recalled lessons
-- =============================================================================

SET pgmnemo.track_recall_recency = 'on';

-- Recall all 3 lessons (text-only path, NULL embedding)
SELECT COUNT(*) AS rows_recalled
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'recall recency stamp lesson xylophone quasar nebula',
    10, 'tc_e_rr', NULL
);

-- All 3 should now have last_recalled_at stamped
SELECT COUNT(*) = 3 AS t1_all_stamped
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_rr'
  AND last_recalled_at IS NOT NULL;

-- =============================================================================
-- T2: recall_count increments by 1 per recall_hybrid call
-- =============================================================================

-- After first recall, count should be 1 for all rows
SELECT bool_and(recall_count = 1) AS t2_count_is_one
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_rr';

-- Second recall
SELECT COUNT(*) AS rows_recalled_second
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'recall recency stamp lesson xylophone quasar nebula',
    10, 'tc_e_rr', NULL
);

-- After second recall, count should be 2
SELECT bool_and(recall_count = 2) AS t2_count_incremented
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_rr';

-- =============================================================================
-- T3: GUC OFF — no stamping
-- Fresh lesson with its own role to ensure last_recalled_at starts NULL.
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES ('tc_e_rr_off', 'recency_test_off',
        'guc off recency test xylophone quasar nebula whiskey tango', 'rr-sha-off');

SET pgmnemo.track_recall_recency = 'off';

SELECT COUNT(*) AS rows_recalled_guc_off
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'guc off recency test xylophone quasar nebula',
    10, 'tc_e_rr_off', NULL
);

-- last_recalled_at should still be NULL (GUC=off suppresses the stamp)
SELECT
    last_recalled_at IS NULL AS t3_no_stamp,
    recall_count = 0         AS t3_count_unchanged
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_rr_off';

RESET pgmnemo.track_recall_recency;

-- =============================================================================
-- Setup: lessons for T4–T9 (mark_stale tests)
-- Insert with created_at = 46 days ago to satisfy the unused-days threshold.
-- All rows use gate_strict=off so no commit_sha is required (except T8).
-- =============================================================================

-- Eligible for deprecation (low confidence, low importance, no provenance)
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence, importance, created_at)
VALUES ('tc_e_ms', 'mark_stale_eligible',
        'mark stale eligible lesson placeholder', 0.3, 2,
        NOW() - INTERVAL '46 days');

-- Protected by confidence >= 0.6 (T6)
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence, importance, created_at)
VALUES ('tc_e_ms', 'mark_stale_high_conf',
        'mark stale high confidence protected lesson placeholder', 0.8, 2,
        NOW() - INTERVAL '46 days');

-- Protected by importance = 5 (T7)
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence, importance, created_at)
VALUES ('tc_e_ms', 'mark_stale_high_imp',
        'mark stale high importance protected lesson placeholder', 0.3, 5,
        NOW() - INTERVAL '46 days');

-- Protected by commit_sha provenance (T8)
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence, importance, commit_sha, created_at)
VALUES ('tc_e_ms', 'mark_stale_provenance',
        'mark stale provenance protected lesson placeholder', 0.3, 2, 'ms-prov-sha',
        NOW() - INTERVAL '46 days');

-- =============================================================================
-- T4: mark_stale() dry_run=TRUE — returns candidates, no state change
-- =============================================================================

-- dry_run returns rows; eligible lesson should have would_deprecate=TRUE
SELECT COUNT(*) AS t4_candidate_count,
       bool_or(would_deprecate)  AS t4_has_deprecatable,
       bool_or(NOT would_deprecate) AS t4_has_safeguarded
FROM pgmnemo.mark_stale(
    p_unused_days=>45,
    p_dry_run=>TRUE
) WHERE role = 'tc_e_ms';

-- State unchanged after dry_run
SELECT COUNT(*) AS t4_state_unchanged
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_ms'
  AND state = 'draft';

-- =============================================================================
-- T5: mark_stale() dry_run=FALSE — eligible lesson becomes deprecated
-- =============================================================================

SELECT COUNT(*) AS t5_deprecated_count
FROM pgmnemo.mark_stale(
    p_unused_days=>45,
    p_dry_run=>FALSE
) WHERE role = 'tc_e_ms' AND would_deprecate;

-- Eligible lesson should now be in 'deprecated' state
SELECT COUNT(*) AS t5_lesson_deprecated
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_ms'
  AND topic = 'mark_stale_eligible'
  AND state = 'deprecated';

-- =============================================================================
-- T6: Safeguard — confidence >= 0.6 NOT deprecated
-- =============================================================================

SELECT COUNT(*) AS t6_high_conf_still_active
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_ms'
  AND topic = 'mark_stale_high_conf'
  AND state != 'deprecated';

-- =============================================================================
-- T7: Safeguard — importance=5 NOT deprecated
-- =============================================================================

SELECT COUNT(*) AS t7_high_imp_still_active
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_ms'
  AND topic = 'mark_stale_high_imp'
  AND state != 'deprecated';

-- =============================================================================
-- T8: Safeguard — commit_sha provenance NOT deprecated
-- =============================================================================

SELECT COUNT(*) AS t8_provenance_still_active
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_ms'
  AND topic = 'mark_stale_provenance'
  AND state != 'deprecated';

-- =============================================================================
-- T9: Cap guard — candidates > cap → NOTICE, no action
-- Insert two MORE eligible lessons to exceed cap=1
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence, importance, created_at)
VALUES ('tc_e_ms_cap', 'mark_stale_cap_a',
        'cap test lesson a placeholder xylophone', 0.3, 2,
        NOW() - INTERVAL '46 days'),
       ('tc_e_ms_cap', 'mark_stale_cap_b',
        'cap test lesson b placeholder xylophone', 0.3, 2,
        NOW() - INTERVAL '46 days');

-- Attempt deprecation with cap=1 (2 candidates > cap=1 → NOTICE + no action)
SELECT COUNT(*) AS t9_returned_count
FROM pgmnemo.mark_stale(
    p_unused_days=>45,
    p_dry_run=>FALSE,
    p_cap=>1
) WHERE role = 'tc_e_ms_cap';

-- Verify no lessons were deprecated (still in 'draft' state)
SELECT COUNT(*) AS t9_all_still_draft
FROM pgmnemo.agent_lesson
WHERE role = 'tc_e_ms_cap'
  AND state = 'draft';

-- =============================================================================
-- Cleanup
-- =============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role IN ('tc_e_rr', 'tc_e_rr_off', 'tc_e_ms', 'tc_e_ms_cap');
