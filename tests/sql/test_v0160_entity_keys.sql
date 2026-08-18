-- test_v0160_entity_keys.sql
-- pg_regress tests for pgmnemo v0.16.0-D — extract_entity_keys() (pruned) + recall_entity()
--
-- Coverage:
--   A1: extract_entity_keys exists — 1 param, text[], immutable, strict
--   B1: model keys — "model:claude-sonnet-4-6"
--   B2: file keys — source paths only (apps/..., src/...)
--   B3: failure keys — "failure:PHANTOM_DONE"
--   B4: schema keys — "schema:pgmnemo.agent_lesson"
--   B5: multiple keys in one text
--   B6: no keys → empty array
--   B7: NULL input → NULL (STRICT)
--   B8: project keys REMOVED — must NOT extract project:xxx
--   B9: file: .md files excluded — must NOT extract *.md paths
--   B10: file: spec/ and docs/ prefixes excluded — must NOT extract
--   C1: ingest() auto-populates metadata.entity_keys
--   C2: ingest() preserves existing metadata keys
--   C3: ingest() with no entity keys — no entity_keys key added
--   D1: recall_entity — signature check
--   D2: recall_entity — finds ingested lesson by failure key
--   D3: recall_entity — finds ingested lesson by model key
--   D4: recall_entity — empty result for non-existent key (silent)
--   D5: recall_entity — respects p_k limit
--   D6: recall_entity — returns entity_keys array in output
--
-- Test isolation: role 'tc_ek', project_id -1600.

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.19.0';

-- ─────────────────────────────────────────────────────────────────────────────
-- A: extract_entity_keys — signature
-- ─────────────────────────────────────────────────────────────────────────────

-- A1: 1 param, returns text[], IMMUTABLE, STRICT
SELECT
    p.pronargs                                            AS nargs,
    pg_catalog.format_type(p.prorettype, NULL)            AS rettype,
    CASE p.provolatile WHEN 'i' THEN 'immutable' END      AS volatility,
    p.proisstrict                                         AS strict
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'extract_entity_keys';

-- ─────────────────────────────────────────────────────────────────────────────
-- B: extract_entity_keys — correct extraction per category (pruned)
-- ─────────────────────────────────────────────────────────────────────────────

-- B1: model key
SELECT pgmnemo.extract_entity_keys(
    'The model claude-sonnet-4-6 is the default for dispatch in v3-next.'
) AS b1_model;

-- B2: file key (source path — should extract)
SELECT pgmnemo.extract_entity_keys(
    'The bug was in apps/v3-next/routes/tasks.py line 42 causing a 500 error.'
) AS b2_file;

-- B3: failure key
SELECT pgmnemo.extract_entity_keys(
    'The PHANTOM_DONE bug caused tasks to be marked complete without real commits.'
) AS b3_failure;

-- B4: schema key
SELECT pgmnemo.extract_entity_keys(
    'The table pgmnemo.agent_lesson stores all ingested lessons with embeddings.'
) AS b4_schema;

-- B5: multiple keys in one text
SELECT pgmnemo.extract_entity_keys(
    'When using claude-sonnet-4-6 on this codebase, the file apps/v3-next/workflows/w1_dispatch.py had a STALE_SESSION_ERROR that corrupted pgmnemo.agent_lesson records.'
) AS b5_multiple;

-- B6: no keys → empty array
SELECT pgmnemo.extract_entity_keys(
    'This is a simple lesson about coding best practices and nothing more.'
) AS b6_empty;

-- B7: NULL input → NULL (STRICT)
SELECT pgmnemo.extract_entity_keys(NULL) AS b7_null;

-- B8: project keys REMOVED — must NOT extract project:xxx
SELECT pgmnemo.extract_entity_keys(
    'When working on project:agency tasks, always use v3-next API endpoint.'
) AS b8_no_project;

-- B9: file: .md files excluded
SELECT pgmnemo.extract_entity_keys(
    'See the report at docs/reports/RETRO_260410.md for full analysis details and review.'
) AS b9_no_md;

-- B10: file: spec/ and docs/ prefixes excluded
SELECT pgmnemo.extract_entity_keys(
    'The spec at spec/v2/D1_ARCH_OVERVIEW.md describes the system architecture completely.'
) AS b10_no_spec;

-- ─────────────────────────────────────────────────────────────────────────────
-- C: ingest() — entity_keys metadata hook
-- ─────────────────────────────────────────────────────────────────────────────

-- C1: ingest with entity keys — metadata should contain entity_keys
DO $$
DECLARE
    _id BIGINT;
    _keys JSONB;
BEGIN
    _id := pgmnemo.ingest(
        'tc_ek'::TEXT, -1600, 'c1-entity-hook'::TEXT,
        'When deploying this system, check apps/v3-next/routes/tasks.py for broken imports.'::TEXT,
        3::SMALLINT, NULL::vector(1024), NULL::TEXT, NULL::TEXT, '{}'::jsonb, NULL::TEXT
    );
    SELECT metadata->'entity_keys' INTO _keys
    FROM pgmnemo.agent_lesson WHERE id = _id;
    RAISE NOTICE 'C1 entity_keys: %', _keys;
END $$;

-- C2: ingest preserves existing metadata
DO $$
DECLARE
    _id BIGINT;
    _val JSONB;
BEGIN
    _id := pgmnemo.ingest(
        'tc_ek'::TEXT, -1600, 'c2-preserve-meta'::TEXT,
        'The model claude-sonnet-4-6 is preferred for all dispatch tasks in production.'::TEXT,
        3::SMALLINT, NULL::vector(1024), NULL::TEXT, NULL::TEXT,
        '{"custom_field": "preserved"}'::jsonb, NULL::TEXT
    );
    SELECT metadata->'custom_field' INTO _val
    FROM pgmnemo.agent_lesson WHERE id = _id;
    RAISE NOTICE 'C2 custom_field preserved: %', _val;
END $$;

-- C3: ingest with no entity keys — no entity_keys key added
DO $$
DECLARE
    _id BIGINT;
    _has BOOLEAN;
BEGIN
    _id := pgmnemo.ingest(
        'tc_ek'::TEXT, -1600, 'c3-no-keys'::TEXT,
        'Simple lesson with no identifiable entity references whatsoever.'::TEXT,
        3::SMALLINT, NULL::vector(1024), NULL::TEXT, NULL::TEXT, '{}'::jsonb, NULL::TEXT
    );
    SELECT metadata ? 'entity_keys' INTO _has
    FROM pgmnemo.agent_lesson WHERE id = _id;
    RAISE NOTICE 'C3 has entity_keys key: %', _has;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D: recall_entity() — entity-keyed recall
-- ─────────────────────────────────────────────────────────────────────────────

-- D1: recall_entity — signature check (2 params, returns setof record)
SELECT
    p.pronargs                                       AS nargs,
    -- v0.19.0 (R-U1): recall_entity no longer stamps recency on the read
    -- path, so it is STABLE now — 'volatile' was the cost of the stamp.
    CASE p.provolatile WHEN 's' THEN 'stable' END     AS volatility,
    p.proretset                                      AS returns_set
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_entity';

-- Insert test data for recall_entity tests (no NOTICE — lesson_ids are dynamic)
DO $$
DECLARE _id BIGINT;
BEGIN
    -- Lesson with failure key (importance 4)
    _id := pgmnemo.ingest(
        'tc_ek'::TEXT, -1600, 'd2-failure-recall'::TEXT,
        'When INFRA_FAILURE occurs during dispatch, check the agent health endpoint first always.'::TEXT,
        4::SMALLINT, NULL::vector(1024), NULL::TEXT, NULL::TEXT, '{}'::jsonb, NULL::TEXT
    );

    -- Lesson with model key (importance 5)
    _id := pgmnemo.ingest(
        'tc_ek'::TEXT, -1600, 'd3-model-recall'::TEXT,
        'When using claude-sonnet-4-6 for code review, set max_turns to sixty for best results.'::TEXT,
        5::SMALLINT, NULL::vector(1024), NULL::TEXT, NULL::TEXT, '{}'::jsonb, NULL::TEXT
    );

    -- Another lesson with same failure key (importance 3, for limit test)
    _id := pgmnemo.ingest(
        'tc_ek'::TEXT, -1600, 'd5-failure-recall-2'::TEXT,
        'When INFRA_FAILURE happens at night, the retry loop should wait longer between attempts.'::TEXT,
        3::SMALLINT, NULL::vector(1024), NULL::TEXT, NULL::TEXT, '{}'::jsonb, NULL::TEXT
    );
END $$;

-- D2: recall_entity finds lesson by failure key
SELECT lesson_id IS NOT NULL AS d2_found, topic, importance
FROM pgmnemo.recall_entity('failure:INFRA_FAILURE')
WHERE role = 'tc_ek' AND project_id = -1600
ORDER BY importance DESC, created_at DESC;

-- D3: recall_entity finds lesson by model key
SELECT lesson_id IS NOT NULL AS d3_found, topic, importance
FROM pgmnemo.recall_entity('model:claude-sonnet-4-6')
WHERE role = 'tc_ek' AND project_id = -1600
ORDER BY importance DESC, created_at DESC;

-- D4: recall_entity — empty result for non-existent key (silent, no error)
SELECT count(*) AS d4_count
FROM pgmnemo.recall_entity('failure:NONEXISTENT_KEY_XYZZY');

-- D5: recall_entity — respects p_k limit
SELECT count(*) AS d5_count
FROM pgmnemo.recall_entity('failure:INFRA_FAILURE', 1)
WHERE role = 'tc_ek' AND project_id = -1600;

-- D6: recall_entity — returns entity_keys array in output
SELECT entity_keys IS NOT NULL AS d6_has_keys,
       array_length(entity_keys, 1) > 0 AS d6_keys_not_empty
FROM pgmnemo.recall_entity('failure:INFRA_FAILURE')
WHERE role = 'tc_ek' AND project_id = -1600
LIMIT 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleanup test data
-- ─────────────────────────────────────────────────────────────────────────────
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_ek' AND project_id = -1600;
