-- selective_embedding.sql
-- pg_regress tests for pgmnemo v0.10.0: apply_selective_embedding_policy()
--
-- Coverage:
--   T1: apply_selective_embedding_policy exists with 1-arg signature (boolean)
--   T2: dry_run=TRUE returns count >= 3 and dry_run flag = TRUE
--   T3: dry_run=TRUE by_content_type JSONB contains entity, fact, temporal keys
--   T4: embeddings still non-NULL after dry_run (no modification)
--   T5: dry_run=FALSE clears embeddings for non-semantic types
--   T6: non-semantic embeddings are NULL post-apply
--   T7: Idempotent — second dry_run=FALSE returns affected_count = 0
--   T8: Lesson-type row embedding preserved (semantic type, not cleared)
--   T9: Boundary — relation content_type cleared; NULL content_type preserved

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

ALTER EXTENSION pgmnemo UPDATE TO '0.11.1';

-- ============================================================================
-- T1: Function exists with 1-arg signature
-- ============================================================================

SELECT COUNT(*) = 1 AS t1_policy_fn_exists
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname = 'apply_selective_embedding_policy'
  AND pronargs = 1;

-- ============================================================================
-- Setup: 4 embedded rows — entity, fact, temporal (non-semantic) + lesson (semantic)
-- project_id=9992, unique role 'tc_se' for isolation
-- ============================================================================

INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, content_type, embedding, commit_sha)
SELECT 'tc_se', 9992, 'policy_test',
       lesson_text, content_type,
       array_fill(1.0::float4, ARRAY[1024])::vector(1024),
       commit_sha
FROM (VALUES
    ('selective embedding entity row alpha bravo xylophone',   'entity',   'se-sha-entity-1'),
    ('selective embedding fact row alpha bravo xylophone',     'fact',     'se-sha-fact-1'),
    ('selective embedding temporal row alpha bravo xylophone', 'temporal', 'se-sha-temporal-1'),
    ('selective embedding lesson row alpha bravo xylophone',   'lesson',   'se-sha-lesson-1')
) AS t(lesson_text, content_type, commit_sha);

-- ============================================================================
-- T2: dry_run=TRUE returns count >= 3 and dry_run flag = TRUE
-- ============================================================================

SELECT affected_count >= 3 AS t2_dry_run_reports_candidates,
       dry_run = TRUE       AS t2_dry_run_flag_correct
FROM pgmnemo.apply_selective_embedding_policy(TRUE);

-- ============================================================================
-- T3: dry_run=TRUE by_content_type JSONB contains entity, fact, temporal keys
-- ============================================================================

SELECT (by_content_type ? 'entity')   AS t3_entity_key_present,
       (by_content_type ? 'fact')     AS t3_fact_key_present,
       (by_content_type ? 'temporal') AS t3_temporal_key_present
FROM pgmnemo.apply_selective_embedding_policy(TRUE);

-- ============================================================================
-- T4: Embeddings still non-NULL after dry_run (no modification occurred)
-- ============================================================================

SELECT COUNT(*) = 3 AS t4_embeddings_intact_after_dry_run
FROM pgmnemo.agent_lesson
WHERE role = 'tc_se'
  AND content_type IN ('entity', 'fact', 'temporal')
  AND embedding IS NOT NULL;

-- ============================================================================
-- T5: dry_run=FALSE clears embeddings for non-semantic types
-- ============================================================================

SELECT affected_count >= 3 AS t5_rows_cleared,
       dry_run = FALSE      AS t5_dry_run_false
FROM pgmnemo.apply_selective_embedding_policy(FALSE);

-- ============================================================================
-- T6: Non-semantic embeddings are NULL after apply (post-T5 verification)
-- ============================================================================

SELECT COUNT(*) = 3 AS t6_non_semantic_embeddings_cleared
FROM pgmnemo.agent_lesson
WHERE role = 'tc_se'
  AND content_type IN ('entity', 'fact', 'temporal')
  AND embedding IS NULL;

-- ============================================================================
-- T7: Idempotent — second dry_run=FALSE returns 0 (already cleared)
-- ============================================================================

SELECT affected_count = 0 AS t7_idempotent_zero_on_second_run
FROM pgmnemo.apply_selective_embedding_policy(FALSE);

-- ============================================================================
-- T8: Lesson-type row embedding preserved (semantic type, not cleared)
-- ============================================================================

SELECT COUNT(*) = 1 AS t8_lesson_embedding_preserved
FROM pgmnemo.agent_lesson
WHERE role = 'tc_se'
  AND content_type = 'lesson'
  AND embedding IS NOT NULL;

-- ============================================================================
-- Cleanup
-- ============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_se';

-- ============================================================================
-- T9: Boundary — relation content_type cleared; NULL content_type preserved
-- New isolated role 'tc_se2'; tc_se rows already NULL after T5 (idempotency confirmed).
-- apply_selective_embedding_policy clears 'relation'; must NOT clear NULL content_type.
-- ============================================================================

INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, content_type, embedding, commit_sha)
VALUES
    ('tc_se2', 9992, 'boundary_test',
     'selective embedding relation boundary row alpha bravo xylophone',
     'relation',
     array_fill(1.0::float4, ARRAY[1024])::vector(1024),
     'se-sha-relation-b'),
    ('tc_se2', 9992, 'boundary_test',
     'selective embedding null content type boundary row alpha bravo xylophone',
     NULL,
     array_fill(1.0::float4, ARRAY[1024])::vector(1024),
     'se-sha-null-b');

-- Apply policy — relation row should be cleared; NULL content_type row untouched
SELECT (dry_run = FALSE) AS t9_applied
FROM pgmnemo.apply_selective_embedding_policy(FALSE);

-- relation row: embedding cleared by policy
SELECT COUNT(*) = 1 AS t9_relation_embedding_cleared
FROM pgmnemo.agent_lesson
WHERE role = 'tc_se2'
  AND content_type = 'relation'
  AND embedding IS NULL;

-- NULL content_type row: embedding preserved (not a non-semantic type)
SELECT COUNT(*) = 1 AS t9_null_content_type_preserved
FROM pgmnemo.agent_lesson
WHERE role = 'tc_se2'
  AND content_type IS NULL
  AND embedding IS NOT NULL;

DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_se2';
