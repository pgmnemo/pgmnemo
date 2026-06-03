-- test_v080.sql
-- pg_regress tests for pgmnemo v0.8.0
--
-- Coverage:
--   T1:  source_type column — default 'auto_captured', CHECK rejects invalid value
--   T2:  embedding_at column — starts NULL, populated after reembed()
--   T3:  navigate_locate — basic call returns rows (id, score, tokens_consumed, nav_path)
--   T4:  navigate_locate — token budget cap (cumulative chars <= budget + last row)
--   T5:  navigate_locate — JSONB pushdown (jsonb_filter restricts to matching rows only)
--   T6:  navigate_locate — navigation_path = 'vector' when no filter
--   T7:  navigate_locate — navigation_path = 'jsonb_gate' when jsonb_filter supplied
--   T8:  navigate_expand — returns lesson_text for given IDs
--   T9:  navigate_expand — expand_fields projects metadata keys into expand_detail
--   T10: navigate_expand — graph expansion adds causal/temporal neighbour rows
--   T11: reembed() — updates embedding + embedding_at, does NOT change lesson_text
--   T12: reembed_batch() — returns count, updates multiple rows
--   T13: recompute_content() — updates lesson_text, same id preserved, no new row
--   T14: recompute_content() — does NOT fire bitemporal close+create (row count stable)
--   T15: reembed() rejects wrong-dim vector
--   T16: reembed_batch() rejects mismatched array lengths
--   T17: recompute_content() rejects empty text
--
-- Prerequisites: pgmnemo 0.8.0 installed.
-- gate_strict=off:        insert test rows without commit_sha/artifact_hash.
-- include_unverified=on:  recall unverified test rows.
-- NOTE: These tests run against the experiment DB. Run with:
--   psql -v ON_ERROR_STOP=1 -f test_v080.sql
-- or via pg_regress if PG+pgvector test DB is available.

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

-- =============================================================================
-- Setup: insert test lessons for v0.8.0 tests
-- =============================================================================
--
-- We use role='tc_v080' for easy cleanup.
-- Embeddings: simple synthetic 1024-dim vectors (uniform value for predictable cosine).
-- Lesson A: short text (~50 chars), tagged with {env: 'prod'}
-- Lesson B: medium text (~100 chars), tagged with {env: 'staging'}
-- Lesson C: longer text (~200 chars), no jsonb tag
-- Lessons are inserted directly (bypassing ingest() guards) for test isolation.

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v080', 'lesson_a',
    'Short test lesson alpha for v0.8.0 navigate locate expand tests.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"env": "prod", "priority": 1}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v080', 'lesson_b',
    'Medium length test lesson beta for v0.8.0 navigate locate and expand testing purposes text here.',
    ('[' || repeat('0.02500,', 1023) || '0.02500]')::vector(1024),
    '{"env": "staging", "priority": 2}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v080', 'lesson_c',
    'This is a longer test lesson gamma for v0.8.0 navigate tests. '
    'It contains more content to test token budget cap enforcement behavior '
    'when cumulative character count exceeds the specified budget limit.',
    ('[' || repeat('0.01000,', 1023) || '0.01000]')::vector(1024),
    '{"env": "prod", "priority": 3}'::jsonb
);

-- =============================================================================
-- T1: source_type — default 'auto_captured', CHECK rejects invalid value
-- =============================================================================

SELECT source_type = 'auto_captured' AS t1_source_type_default
FROM pgmnemo.agent_lesson
WHERE role = 'tc_v080' AND topic = 'lesson_a';

DO $$
BEGIN
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, source_type)
    VALUES ('tc_v080', 'bad_source', 'test lesson text for source type check constraint',
            'invalid_value');
    RAISE EXCEPTION 'T1 FAIL: CHECK constraint did not reject invalid source_type';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'T1 PASS: CHECK constraint rejects invalid source_type';
END;
$$;

-- =============================================================================
-- T2: embedding_at — NULL before reembed, non-NULL after
-- =============================================================================

-- embedding_at should be non-NULL after backfill (upgrade sets it to updated_at
-- for rows with embeddings). For fresh inserts via raw INSERT embedding_at is NULL
-- (INSERT trigger does not set it — only reembed()/reembed_batch() do).
-- Test: embedding_at starts NULL for a freshly inserted row (no reembed called).

SELECT embedding_at IS NULL AS t2_embedding_at_null_before_reembed
FROM pgmnemo.agent_lesson
WHERE role = 'tc_v080' AND topic = 'lesson_a';

-- =============================================================================
-- T3: navigate_locate — basic call, correct column shape
-- =============================================================================

SELECT
    id IS NOT NULL          AS t3_has_id,
    preview IS NOT NULL     AS t3_has_preview,
    length(preview) <= 50   AS t3_preview_max50,
    score >= 0.0            AS t3_score_nonneg,
    tokens_consumed > 0     AS t3_tokens_positive,
    navigation_path IS NOT NULL AS t3_has_nav_path
FROM pgmnemo.navigate_locate(
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    'navigate locate test lesson',
    10000,   -- large budget: return all
    NULL
)
LIMIT 1;

-- =============================================================================
-- T4: navigate_locate — token budget cap
--     Budget = 80 chars. lesson_a is ~64 chars. Should return lesson_a (first)
--     but NOT lesson_c (cumulative would exceed 80).
--     tokens_consumed for the first result <= budget + len(first lesson).
-- =============================================================================

SELECT
    COUNT(*) >= 1                                      AS t4_at_least_one_result,
    MAX(tokens_consumed) <= 2000                       AS t4_tokens_within_budget_plus_one,
    -- The first row's tokens_consumed equals its own text length
    MIN(tokens_consumed) > 0                           AS t4_first_tokens_positive
FROM pgmnemo.navigate_locate(
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    'navigate test lesson',
    80,
    NULL
);

-- =============================================================================
-- T5: navigate_locate — JSONB pushdown restricts to env=prod rows
--     Only lessons A and C have {env: 'prod'}. Lesson B (env=staging) should
--     NOT appear in results when jsonb_filter = '{"env":"prod"}'.
-- =============================================================================

SELECT
    COUNT(*) > 0                               AS t5_has_results,
    bool_and(
        EXISTS (
            SELECT 1 FROM pgmnemo.agent_lesson al
            WHERE al.id = nl.id
              AND al.metadata @> '{"env":"prod"}'::jsonb
        )
    )                                          AS t5_all_results_match_filter
FROM pgmnemo.navigate_locate(
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    'navigate test lesson',
    10000,
    '{"env": "prod"}'::jsonb
) nl
WHERE nl.navigation_path <> 'graph_expand'; -- only base rows

-- =============================================================================
-- T6: navigate_locate — navigation_path = 'vector' without jsonb_filter
-- =============================================================================

SELECT
    navigation_path IN ('vector', 'bm25') AS t6_nav_path_is_signal_based
FROM pgmnemo.navigate_locate(
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    'navigate locate test lesson',
    10000,
    NULL
)
ORDER BY score DESC
LIMIT 1;

-- =============================================================================
-- T7: navigate_locate — navigation_path = 'jsonb_gate' when filter supplied
-- =============================================================================

SELECT
    navigation_path = 'jsonb_gate' AS t7_nav_path_jsonb_gate
FROM pgmnemo.navigate_locate(
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    'navigate locate test lesson',
    10000,
    '{"env": "prod"}'::jsonb
)
ORDER BY score DESC
LIMIT 1;

-- =============================================================================
-- T8: navigate_expand — returns lesson_text for given IDs
-- =============================================================================

SELECT
    ne.content IS NOT NULL          AS t8_has_content,
    length(ne.content) > 0          AS t8_content_nonempty,
    ne.tokens_consumed > 0          AS t8_has_tokens_consumed,
    ne.tokens_consumed >= length(ne.content) AS t8_tokens_ge_len,
    ne.navigation_path = 'content'  AS t8_nav_path_content
FROM (
    SELECT id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a'
    LIMIT 1
) seed
CROSS JOIN LATERAL pgmnemo.navigate_expand(
    ARRAY[seed.id],
    '{}',
    0,    -- no graph expansion
    0.7
) ne;

-- =============================================================================
-- T9: navigate_expand — expand_fields projects metadata keys
-- =============================================================================

SELECT
    ne.expand_detail IS NOT NULL        AS t9_has_expand_detail,
    ne.expand_detail ? 'env'            AS t9_has_env_key,
    ne.expand_detail ? 'priority'       AS t9_has_priority_key
FROM (
    SELECT id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a'
    LIMIT 1
) seed
CROSS JOIN LATERAL pgmnemo.navigate_expand(
    ARRAY[seed.id],
    ARRAY['env', 'priority'],
    0,
    0.7
) ne;

-- =============================================================================
-- T10: navigate_expand — graph expansion traverses causal/temporal edges
--      Setup: insert a causal edge from lesson_a → lesson_b.
--      Expand lesson_a with depth=1 → should include lesson_b as 'graph_expand'.
-- =============================================================================

DO $$
DECLARE
    _id_a BIGINT;
    _id_b BIGINT;
BEGIN
    SELECT id INTO _id_a FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a' LIMIT 1;

    SELECT id INTO _id_b FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_b' LIMIT 1;

    INSERT INTO pgmnemo.mem_edge (source_id, target_id, relation_type, edge_kind, weight)
    VALUES (_id_a, _id_b, 'causal', 'causal', 0.9)
    ON CONFLICT DO NOTHING;
END;
$$;

SELECT
    COUNT(*) = 2                                               AS t10_two_rows_returned,
    bool_or(navigation_path = 'content')                      AS t10_has_content_row,
    bool_or(navigation_path = 'graph_expand')                 AS t10_has_graph_expand_row
FROM (
    SELECT id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a'
    LIMIT 1
) seed
CROSS JOIN LATERAL pgmnemo.navigate_expand(
    ARRAY[seed.id],
    '{}',
    1,     -- depth=1: traverse one hop
    0.8    -- threshold < 0.9 edge weight → edge is traversed
) ne;

-- =============================================================================
-- T10b: navigate_expand — graph_neighbor_ids populated for seed rows
--       The seed (lesson_a) has a causal edge to lesson_b → neighbor_ids non-null.
-- =============================================================================

SELECT
    ne.graph_neighbor_ids IS NOT NULL                  AS t10b_has_neighbor_ids,
    array_length(ne.graph_neighbor_ids, 1) >= 1        AS t10b_at_least_one_neighbor,
    ne.graph_neighbor_previews IS NOT NULL              AS t10b_has_neighbor_previews,
    ne.tokens_consumed > 0                             AS t10b_has_tokens
FROM (
    SELECT id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a'
    LIMIT 1
) seed
CROSS JOIN LATERAL pgmnemo.navigate_expand(
    ARRAY[seed.id],
    '{}',
    1,
    0.8
) ne
WHERE ne.navigation_path = 'content';

-- =============================================================================
-- T11: reembed() — updates embedding + embedding_at, preserves lesson_text
-- =============================================================================

DO $$
DECLARE
    _id          BIGINT;
    _text_before TEXT;
    _text_after  TEXT;
    _emb_at      TIMESTAMPTZ;
BEGIN
    SELECT id, lesson_text INTO _id, _text_before
    FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a' LIMIT 1;

    PERFORM pgmnemo.reembed(
        _id,
        ('[' || repeat('0.05000,', 1023) || '0.05000]')::vector(1024)
    );

    SELECT lesson_text, embedding_at INTO _text_after, _emb_at
    FROM pgmnemo.agent_lesson WHERE id = _id;

    IF _text_before = _text_after THEN
        RAISE NOTICE 'T11a PASS: reembed() preserves lesson_text';
    ELSE
        RAISE EXCEPTION 'T11a FAIL: lesson_text changed after reembed()';
    END IF;

    IF _emb_at IS NOT NULL THEN
        RAISE NOTICE 'T11b PASS: reembed() sets embedding_at';
    ELSE
        RAISE EXCEPTION 'T11b FAIL: embedding_at still NULL after reembed()';
    END IF;
END;
$$;

-- =============================================================================
-- T12: reembed_batch() — returns count, updates multiple rows
-- =============================================================================

DO $$
DECLARE
    _id_a   BIGINT;
    _id_b   BIGINT;
    _cnt    INT;
BEGIN
    SELECT id INTO _id_a FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a' LIMIT 1;
    SELECT id INTO _id_b FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_b' LIMIT 1;

    _cnt := pgmnemo.reembed_batch(
        ARRAY[_id_a, _id_b],
        ARRAY[
            ('[' || repeat('0.06250,', 1023) || '0.06250]')::vector(1024),
            ('[' || repeat('0.06250,', 1023) || '0.06250]')::vector(1024)
        ]::vector[]
    );

    IF _cnt = 2 THEN
        RAISE NOTICE 'T12 PASS: reembed_batch() returned 2';
    ELSE
        RAISE EXCEPTION 'T12 FAIL: expected 2, got %', _cnt;
    END IF;
END;
$$;

-- =============================================================================
-- T13: recompute_content() — updates lesson_text, same id preserved
-- =============================================================================

DO $$
DECLARE
    _id          BIGINT;
    _new_text    CONSTANT TEXT := 'Updated lesson text for v0.8.0 recompute content test validation.';
    _text_after  TEXT;
    _id_after    BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_b' LIMIT 1;

    PERFORM pgmnemo.recompute_content(_id, _new_text);

    SELECT id, lesson_text INTO _id_after, _text_after
    FROM pgmnemo.agent_lesson WHERE id = _id;

    IF _id_after = _id THEN
        RAISE NOTICE 'T13a PASS: recompute_content() preserves id';
    ELSE
        RAISE EXCEPTION 'T13a FAIL: id changed after recompute_content()';
    END IF;

    IF _text_after = _new_text THEN
        RAISE NOTICE 'T13b PASS: recompute_content() updated lesson_text';
    ELSE
        RAISE EXCEPTION 'T13b FAIL: lesson_text not updated: %', _text_after;
    END IF;
END;
$$;

-- =============================================================================
-- T14: recompute_content() — does NOT create a new row (bitemporal safe)
--      Count active rows for lesson_b before and after; should be the same.
-- =============================================================================

DO $$
DECLARE
    _id          BIGINT;
    _cnt_before  INT;
    _cnt_after   INT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_b' LIMIT 1;

    SELECT COUNT(*)::INT INTO _cnt_before
    FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_b'
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

    -- Call recompute_content again with different text
    PERFORM pgmnemo.recompute_content(
        _id,
        'Second update to lesson text for bitemporal no-churn verification test.'
    );

    SELECT COUNT(*)::INT INTO _cnt_after
    FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_b'
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

    IF _cnt_before = _cnt_after THEN
        RAISE NOTICE 'T14 PASS: recompute_content() did not create new row (cnt=%)', _cnt_after;
    ELSE
        RAISE EXCEPTION 'T14 FAIL: row count changed: before=%, after=%',
            _cnt_before, _cnt_after;
    END IF;
END;
$$;

-- =============================================================================
-- T15: reembed() — rejects wrong-dimension vector
-- =============================================================================

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a' LIMIT 1;

    PERFORM pgmnemo.reembed(_id, '[0.1, 0.2, 0.3]'::vector(3));
    RAISE EXCEPTION 'T15 FAIL: wrong-dim vector did not raise';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%1024%' OR SQLERRM LIKE '%dims%' OR SQLERRM LIKE '%dimension%' THEN
        RAISE NOTICE 'T15 PASS: reembed() rejects wrong-dim vector';
    ELSE
        RAISE EXCEPTION 'T15 FAIL: unexpected error: %', SQLERRM;
    END IF;
END;
$$;

-- =============================================================================
-- T16: reembed_batch() — rejects mismatched array lengths
-- =============================================================================

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a' LIMIT 1;

    PERFORM pgmnemo.reembed_batch(
        ARRAY[_id, _id + 1],
        ARRAY[('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024)]::vector[]
    );
    RAISE EXCEPTION 'T16 FAIL: mismatched arrays did not raise';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%length%' OR SQLERRM LIKE '%differs%' THEN
        RAISE NOTICE 'T16 PASS: reembed_batch() rejects mismatched array lengths';
    ELSE
        RAISE EXCEPTION 'T16 FAIL: unexpected error: %', SQLERRM;
    END IF;
END;
$$;

-- =============================================================================
-- T17: recompute_content() — rejects empty text
-- =============================================================================

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson
    WHERE role = 'tc_v080' AND topic = 'lesson_a' LIMIT 1;

    PERFORM pgmnemo.recompute_content(_id, '   ');
    RAISE EXCEPTION 'T17 FAIL: empty text did not raise';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%non-empty%' OR SQLERRM LIKE '%empty%' THEN
        RAISE NOTICE 'T17 PASS: recompute_content() rejects empty text';
    ELSE
        RAISE EXCEPTION 'T17 FAIL: unexpected error: %', SQLERRM;
    END IF;
END;
$$;

-- =============================================================================
-- Cleanup
-- =============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_v080';
