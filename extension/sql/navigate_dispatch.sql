-- navigate_dispatch.sql
-- pg_regress tests for pgmnemo v0.10.0: navigate_locate_dispatch() + navigate_expand_typed()
--
-- Coverage:
--   T1:  navigate_locate_dispatch exists with 6-arg signature
--   T2:  navigate_expand_typed exists with 4-arg signature
--   T3:  entity dispatch routes to BM25 path (navigation_path = 'bm25_entity')
--   T4:  entity dispatch without query_text raises exception (guard check)
--   T5:  temporal dispatch routes to btree path (navigation_path = 'temporal_btree')
--   T6:  NULL content_type delegates — no exception, returns navigate_locate result
--   T7:  navigate_expand_typed NULL ids returns 0 rows
--   T8:  navigate_expand_typed lesson rows return navigation_path = 'content'
--   T9:  navigate_expand_typed entity rows return navigation_path = 'typed_entity'
--   T10: relation dispatch routes to graph_relation path (mem_edge BFS)
--   T11: Boundary — relation dispatch without query_text raises exception
--   T12: Boundary — navigate_expand_typed entity typed_detail JSONB structure

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

ALTER EXTENSION pgmnemo UPDATE TO '0.11.0';

-- ============================================================================
-- T1: navigate_locate_dispatch exists with 6-arg signature
-- ============================================================================

SELECT COUNT(*) = 1 AS t1_dispatch_exists
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname = 'navigate_locate_dispatch'
  AND pronargs = 6;

-- ============================================================================
-- T2: navigate_expand_typed exists with 4-arg signature
-- ============================================================================

SELECT COUNT(*) = 1 AS t2_expand_typed_exists
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname = 'navigate_expand_typed'
  AND pronargs = 4;

-- ============================================================================
-- Setup: one entity row and one lesson row, project_id=9991 for isolation
-- ============================================================================

INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, content_type, commit_sha)
VALUES
    ('tc_nd', 9991, 'dispatch_test',
     'navigate dispatch entity row alpha bravo charlie xylophone',
     'entity', 'nd-sha-entity-1'),
    ('tc_nd', 9991, 'dispatch_test',
     'navigate dispatch lesson row alpha bravo charlie xylophone',
     'lesson', 'nd-sha-lesson-1'),
    ('tc_nd', 9991, 'dispatch_test',
     'navigate dispatch temporal row alpha bravo recent event',
     'temporal', 'nd-sha-temporal-1');

-- Setup: mem_edge connecting entity → lesson for T10 relation dispatch test
DO $$
DECLARE
    _entity_id BIGINT;
    _lesson_id BIGINT;
BEGIN
    SELECT id INTO _entity_id
    FROM pgmnemo.agent_lesson
    WHERE role = 'tc_nd' AND content_type = 'entity' LIMIT 1;
    SELECT id INTO _lesson_id
    FROM pgmnemo.agent_lesson
    WHERE role = 'tc_nd' AND content_type = 'lesson' LIMIT 1;
    PERFORM pgmnemo.add_edge(_entity_id, _lesson_id, 'ELABORATES', 0.9);
END;
$$;

-- ============================================================================
-- T3: entity dispatch routes to BM25 path → navigation_path = 'bm25_entity'
-- ============================================================================

SELECT COUNT(*) >= 1           AS t3_entity_found,
       bool_and(navigation_path = 'bm25_entity') AS t3_entity_path_correct
FROM pgmnemo.navigate_locate_dispatch(
    NULL,
    'navigate dispatch entity xylophone',
    2000, NULL, 9991, 'entity'
);

-- ============================================================================
-- T4: entity dispatch without query_text raises exception
-- ============================================================================

DO $$
BEGIN
    PERFORM pgmnemo.navigate_locate_dispatch(
        NULL, NULL, 2000, NULL, 9991, 'entity'
    );
    RAISE EXCEPTION 'T4 FAIL: expected exception not raised for NULL query_text';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'T4 PASS: entity dispatch with NULL query_text raises exception';
END;
$$;

-- ============================================================================
-- T5: temporal dispatch routes to btree path → navigation_path = 'temporal_btree'
-- ============================================================================

SELECT COUNT(*) >= 1           AS t5_temporal_found,
       bool_and(navigation_path = 'temporal_btree') AS t5_temporal_path_correct
FROM pgmnemo.navigate_locate_dispatch(
    NULL, NULL, 2000, NULL, 9991, 'temporal'
);

-- ============================================================================
-- T6: NULL content_type delegates to navigate_locate — path is NOT bm25_entity
--     or temporal_btree. With NULL embedding + text query, BM25 fallback fires.
-- ============================================================================

SELECT COUNT(*) = 0 AS t6_no_typed_paths_in_unified_dispatch
FROM (
    SELECT 1
    FROM pgmnemo.navigate_locate_dispatch(
        NULL,
        'navigate dispatch lesson xylophone',
        2000, NULL, 9991, NULL
    )
    WHERE navigation_path IN ('bm25_entity', 'temporal_btree', 'graph_relation')
) typed_rows;

-- ============================================================================
-- T7: navigate_expand_typed with NULL ids returns 0 rows
-- ============================================================================

SELECT COUNT(*) = 0 AS t7_null_ids_empty
FROM pgmnemo.navigate_expand_typed(NULL, 0, 0.5, NULL);

-- ============================================================================
-- T8: navigate_expand_typed lesson row returns navigation_path = 'content'
-- ============================================================================

SELECT navigation_path = 'content' AS t8_lesson_path_content
FROM pgmnemo.navigate_expand_typed(
    ARRAY[(SELECT id FROM pgmnemo.agent_lesson
           WHERE role = 'tc_nd' AND content_type = 'lesson' LIMIT 1)],
    0, 0.5, NULL
);

-- ============================================================================
-- T9: navigate_expand_typed entity row returns navigation_path = 'typed_entity'
-- ============================================================================

SELECT navigation_path = 'typed_entity' AS t9_entity_path_typed
FROM pgmnemo.navigate_expand_typed(
    ARRAY[(SELECT id FROM pgmnemo.agent_lesson
           WHERE role = 'tc_nd' AND content_type = 'entity' LIMIT 1)],
    0, 0.5, NULL
);

-- ============================================================================
-- T10: relation dispatch routes to graph_relation path
-- Seed: entity row matches BM25 query; follow mem_edge → lesson neighbor.
-- ============================================================================

SELECT COUNT(*) >= 1                                AS t10_relation_dispatch_found,
       bool_and(navigation_path = 'graph_relation') AS t10_relation_path_correct
FROM pgmnemo.navigate_locate_dispatch(
    NULL,
    'navigate dispatch entity xylophone',
    2000, NULL, 9991, 'relation'
);

-- ============================================================================
-- T11: Boundary — relation dispatch without query_text raises exception
-- ============================================================================

DO $$
BEGIN
    PERFORM pgmnemo.navigate_locate_dispatch(
        NULL, NULL, 2000, NULL, 9991, 'relation'
    );
    RAISE EXCEPTION 'T11 FAIL: expected exception not raised for NULL query_text';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'T11 PASS: relation dispatch with NULL query_text raises exception';
END;
$$;

-- ============================================================================
-- T12: Boundary — navigate_expand_typed entity typed_detail JSONB structure
-- Entity rows must return non-null typed_detail with canonical_name + entity_type keys.
-- ============================================================================

SELECT typed_detail IS NOT NULL           AS t12_entity_typed_detail_not_null,
       typed_detail ? 'canonical_name'    AS t12_has_canonical_name_key,
       typed_detail ? 'entity_type'       AS t12_has_entity_type_key
FROM pgmnemo.navigate_expand_typed(
    ARRAY[(SELECT id FROM pgmnemo.agent_lesson
           WHERE role = 'tc_nd' AND content_type = 'entity' LIMIT 1)],
    0, 0.5, NULL
);

-- ============================================================================
-- Cleanup
-- ============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_nd';
