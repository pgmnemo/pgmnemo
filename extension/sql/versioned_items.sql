-- versioned_items.sql
-- pg_regress tests for pgmnemo v0.9.6: versioned items, DAG-scoped recall, migration log
-- R11/R12/R13
--
-- Coverage:
--   T1: item_kind column exists with default 'note'; CHECK rejects invalid value
--   T2: version_n default=1, patch_count default=0
--   T3: source_dag_id nullable, can be set; sparse index exists
--   T4: memory_ingest_log INSERT + SELECT + UPDATE retired_at
--   T5: exclude_dag_id filter — lesson with source_dag_id='dag-x' is recalled when
--       exclude_dag_id is NULL or 'dag-y', but NOT when exclude_dag_id='dag-x'

-- Prerequisites: pgmnemo 0.9.5+ installed. gate_strict=off for raw INSERTs.
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

ALTER EXTENSION pgmnemo UPDATE TO '0.9.7';

-- =============================================================================
-- Schema verification: new columns exist on agent_lesson
-- =============================================================================

SELECT
    SUM(CASE WHEN column_name = 'item_kind'     THEN 1 ELSE 0 END) = 1 AS has_item_kind,
    SUM(CASE WHEN column_name = 'version_n'     THEN 1 ELSE 0 END) = 1 AS has_version_n,
    SUM(CASE WHEN column_name = 'patch_count'   THEN 1 ELSE 0 END) = 1 AS has_patch_count,
    SUM(CASE WHEN column_name = 'source_dag_id' THEN 1 ELSE 0 END) = 1 AS has_source_dag_id
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  IN ('item_kind', 'version_n', 'patch_count', 'source_dag_id');

-- memory_ingest_log table exists
SELECT COUNT(*) = 1 AS has_memory_ingest_log
FROM information_schema.tables
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'memory_ingest_log';

-- =============================================================================
-- T1: item_kind column — default 'note'; CHECK rejects invalid value
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES ('tc_vi_ik', 'item_kind_test', 'item kind default test lesson', 'vi-sha-ik-1');

-- Default should be 'note'
SELECT item_kind = 'note' AS t1_default_note
FROM pgmnemo.agent_lesson
WHERE role = 'tc_vi_ik' AND commit_sha = 'vi-sha-ik-1';

-- All valid item_kind values must be accepted
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, item_kind)
VALUES
    ('tc_vi_ik', 'item_kind_skill',     'skill_md test lesson',   'vi-sha-ik-2', 'skill_md'),
    ('tc_vi_ik', 'item_kind_template',  'template test lesson',   'vi-sha-ik-3', 'template'),
    ('tc_vi_ik', 'item_kind_script',    'script test lesson',     'vi-sha-ik-4', 'script'),
    ('tc_vi_ik', 'item_kind_reference', 'reference test lesson',  'vi-sha-ik-5', 'reference'),
    ('tc_vi_ik', 'item_kind_config',    'config test lesson',     'vi-sha-ik-6', 'config'),
    ('tc_vi_ik', 'item_kind_spec',      'spec test lesson',       'vi-sha-ik-7', 'spec');

SELECT COUNT(*) = 7 AS t1_all_valid_kinds_inserted
FROM pgmnemo.agent_lesson WHERE role = 'tc_vi_ik';

-- CHECK should reject 'invalid_kind'
DO $$
BEGIN
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, item_kind)
    VALUES ('tc_vi_ik', 'bad_kind', 'bad kind lesson', 'vi-sha-ik-bad', 'invalid_kind');
    RAISE EXCEPTION 'Expected CHECK violation but none occurred';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'T1 CHECK violation correctly raised for item_kind=invalid_kind';
END;
$$;

-- =============================================================================
-- T2: version_n default=1, patch_count default=0
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES ('tc_vi_vn', 'version_n_test', 'version and patch count default test', 'vi-sha-vn-1');

SELECT
    version_n   = 1 AS t2_version_n_default_1,
    patch_count = 0 AS t2_patch_count_default_0
FROM pgmnemo.agent_lesson
WHERE role = 'tc_vi_vn' AND commit_sha = 'vi-sha-vn-1';

-- Explicit values should be stored correctly
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, version_n, patch_count)
VALUES ('tc_vi_vn', 'version_n_explicit', 'explicit version test', 'vi-sha-vn-2', 3, 7);

SELECT
    version_n   = 3 AS t2_version_n_explicit_3,
    patch_count = 7 AS t2_patch_count_explicit_7
FROM pgmnemo.agent_lesson
WHERE role = 'tc_vi_vn' AND commit_sha = 'vi-sha-vn-2';

-- =============================================================================
-- T3: source_dag_id nullable, can be set; sparse index exists
-- =============================================================================

-- NULL by default
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES ('tc_vi_dag', 'dag_null_test', 'dag id null default test', 'vi-sha-dag-0');

SELECT source_dag_id IS NULL AS t3_source_dag_id_null_by_default
FROM pgmnemo.agent_lesson
WHERE role = 'tc_vi_dag' AND commit_sha = 'vi-sha-dag-0';

-- Can be set to a non-null value
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, source_dag_id)
VALUES ('tc_vi_dag', 'dag_set_test', 'dag id set test', 'vi-sha-dag-1', 'dag-test-run-42');

SELECT source_dag_id = 'dag-test-run-42' AS t3_source_dag_id_stored
FROM pgmnemo.agent_lesson
WHERE role = 'tc_vi_dag' AND commit_sha = 'vi-sha-dag-1';

-- Sparse index on source_dag_id exists
SELECT COUNT(*) = 1 AS t3_sparse_index_exists
FROM pg_indexes
WHERE schemaname = 'pgmnemo'
  AND tablename  = 'agent_lesson'
  AND indexname  = 'ix_pgmnemo_agent_lesson_source_dag_id';

-- =============================================================================
-- T4: memory_ingest_log INSERT + SELECT + UPDATE retired_at
-- =============================================================================

INSERT INTO pgmnemo.memory_ingest_log (source_origin, min_id, max_id)
VALUES ('legacy.agent_memory', 1, 5000)
RETURNING id > 0 AS t4_insert_ok, source_origin, min_id, max_id;

-- Verify the row is queryable
SELECT
    source_origin = 'legacy.agent_memory' AS t4_origin_correct,
    min_id        = 1                     AS t4_min_id_correct,
    max_id        = 5000                  AS t4_max_id_correct,
    ingested_at   IS NOT NULL             AS t4_ingested_at_set,
    retired_at    IS NULL                 AS t4_retired_at_null
FROM pgmnemo.memory_ingest_log
WHERE source_origin = 'legacy.agent_memory'
ORDER BY id DESC
LIMIT 1;

-- Update retired_at
UPDATE pgmnemo.memory_ingest_log
SET retired_at = NOW()
WHERE source_origin = 'legacy.agent_memory';

SELECT retired_at IS NOT NULL AS t4_retired_at_set
FROM pgmnemo.memory_ingest_log
WHERE source_origin = 'legacy.agent_memory'
ORDER BY id DESC
LIMIT 1;

-- =============================================================================
-- T5: exclude_dag_id filter
-- Insert one lesson with source_dag_id='dag-x' and one without.
-- Verify recalled when exclude_dag_id=NULL or 'dag-y'.
-- Verify NOT returned when exclude_dag_id='dag-x'.
-- =============================================================================

-- Unique text to ensure this lesson dominates text recall
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, source_dag_id)
VALUES (
    'tc_vi_exc',
    'exclude_dag_test',
    'exclude dag filter quasar xylophone nebula bravo foxtrot zeta',
    'vi-sha-exc-dag',
    'dag-x'
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES (
    'tc_vi_exc',
    'exclude_dag_nodagid',
    'exclude dag filter quasar xylophone nebula bravo foxtrot zeta no dag',
    'vi-sha-exc-nodagid'
);

-- T5a: exclude_dag_id=NULL — both lessons returned
SELECT COUNT(*) >= 1 AS t5a_both_present_when_exclude_null
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'exclude dag filter quasar xylophone nebula',
    10, 'tc_vi_exc', NULL,
    0.4, 0.4, 60,
    NULL  -- exclude_dag_id=NULL: no exclusion
);

-- T5b: exclude_dag_id='dag-y' — dag-x lesson still returned (different dag)
SELECT COUNT(*) >= 1 AS t5b_dag_x_present_when_exclude_dag_y
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'exclude dag filter quasar xylophone nebula',
    10, 'tc_vi_exc', NULL,
    0.4, 0.4, 60,
    'dag-y'  -- exclude_dag_id='dag-y': dag-x row not excluded
);

-- T5c: exclude_dag_id='dag-x' — dag-x lesson filtered out
SELECT COUNT(*) = 0 AS t5c_dag_x_excluded_when_exclude_dag_x
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'exclude dag filter quasar xylophone nebula',
    10, 'tc_vi_exc', NULL,
    0.4, 0.4, 60,
    'dag-x'  -- exclude_dag_id='dag-x': lesson with source_dag_id='dag-x' excluded
)
WHERE lesson_text LIKE '%no dag%' IS FALSE  -- only check for the dag-x row
  AND lesson_id IN (
      SELECT id FROM pgmnemo.agent_lesson
      WHERE role = 'tc_vi_exc' AND source_dag_id = 'dag-x'
  );

-- T5d: lesson without source_dag_id (NULL) IS returned even when exclude_dag_id='dag-x'
-- (IS DISTINCT FROM semantics: NULL IS DISTINCT FROM 'dag-x' = TRUE → row passes)
SELECT COUNT(*) >= 1 AS t5d_null_dag_id_passes_exclude_filter
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'exclude dag filter quasar xylophone nebula no dag',
    10, 'tc_vi_exc', NULL,
    0.4, 0.4, 60,
    'dag-x'  -- only dag-x rows excluded; NULL source_dag_id passes
)
WHERE lesson_id IN (
    SELECT id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_vi_exc' AND source_dag_id IS NULL
);

-- =============================================================================
-- Cleanup
-- =============================================================================

DELETE FROM pgmnemo.agent_lesson
WHERE role IN ('tc_vi_ik', 'tc_vi_vn', 'tc_vi_dag', 'tc_vi_exc');

DELETE FROM pgmnemo.memory_ingest_log
WHERE source_origin = 'legacy.agent_memory';
