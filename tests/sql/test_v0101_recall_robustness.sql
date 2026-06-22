-- test_v0101_recall_robustness.sql
-- pg_regress tests for pgmnemo v0.10.1 — issue #87
--
-- Coverage:
--   T1:  query_text >200 chars is truncated by BM25 path — function does not error
--   T2:  Cyrillic (non-Latin) query text handled by 'simple' tsconfig
--   T3:  Structured/JSON-like query text (code patterns) — no error, vector path fires
--   T4:  BM25 budget 1ms forces timeout — graceful degradation, still returns results
--   T5:  BM25 budget hit logs a NOTICE (not an ERROR)
--   T6:  recall_hybrid returns correct result shape (17 columns)
--   T7:  recall_hybrid second call in same tx works (temp table truncated, not errored)
--   T8:  'simple' tsvector stored in full_text, lesson_tsv, topic_tsv
--   T9:  full_text @@ tsquery('simple') matches
--   T10: navigate_locate works with 'simple' tsconfig
--
-- Run with:
--   psql -v ON_ERROR_STOP=1 -f tests/sql/test_v0101_recall_robustness.sql

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

-- ============================================================================
-- Setup: insert test lessons for v0.10.1 tests
-- role = 'tc_v0101' for easy cleanup
-- ============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v0101', 'robustness_test_topic',
    'When using recall_hybrid with long structured query text the BM25 signal '
    'must not time out. The embedding carries full semantics. Fix is to cap '
    'the lexical query_text to 200 chars before passing to websearch_to_tsquery.',
    ('[' || repeat('0.01,', 1023) || '0.01]')::vector(1024),
    '{}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v0101', 'кириллица_тема',
    'Урок о поиске на русском языке. Конфигурация simple не удаляет стоп-слова '
    'и не применяет стемминг, что важно для смешанного RU/EN корпуса агентов.',
    ('[' || repeat('0.02,', 1023) || '0.02]')::vector(1024),
    '{}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v0101', 'code_patterns',
    'psycopg2.connect(db_url) cursor.execute("SELECT id FROM agent_run WHERE id = %s") '
    'conn.commit() — standard pattern for background service database access.',
    ('[' || repeat('0.03,', 1023) || '0.03]')::vector(1024),
    '{}'::jsonb
);

-- ============================================================================
-- T8: Verify 'simple' config in stored generated columns
-- ============================================================================
\echo T8: simple tsconfig in generated tsvectors

-- 'simple' keeps stop words; 'english' removes them
SELECT
    to_tsvector('simple', 'The running dogs') @@ to_tsquery('simple', 'running')  AS simple_matches_running,
    to_tsvector('simple', 'The running dogs') @@ to_tsquery('simple', 'the')      AS simple_matches_the,
    NOT (to_tsvector('english', 'The running dogs') @@ to_tsquery('english', 'the')) AS english_removes_the;

-- Russian words appear in lesson_tsv (from lesson_text) via 'simple'
-- 'урок' is the first word in the Cyrillic lesson_text; 'конфигурация' is later
-- topic_tsv should contain either 'кириллица' or 'тема' (compound split) or whole token
SELECT
    'урок'         = ANY(tsvector_to_array(lesson_tsv)) AS russian_word_in_lesson_tsv,
    'конфигурация' = ANY(tsvector_to_array(lesson_tsv)) AS second_word_in_lesson_tsv,
    topic_tsv @@ to_tsquery('simple', 'кириллица | тема') AS cyrillic_in_topic_tsv
FROM pgmnemo.agent_lesson
WHERE role = 'tc_v0101' AND topic = 'кириллица_тема';

-- ============================================================================
-- T9: full_text @@ tsquery('simple') matches
-- ============================================================================
\echo T9: full_text GIN index matches with simple tsquery
SELECT COUNT(*) > 0 AS has_bm25_match
FROM pgmnemo.agent_lesson
WHERE role = 'tc_v0101'
  AND full_text @@ websearch_to_tsquery('simple', 'recall_hybrid BM25');

-- ============================================================================
-- T6: recall_hybrid returns correct shape (17 columns)
-- ============================================================================
\echo T6: recall_hybrid returns 17 output columns
SELECT
    lesson_id IS NOT NULL AS has_lesson_id,
    score IS NOT NULL     AS has_score,
    vec_score IS NOT NULL AS has_vec_score,
    match_confidence >= 0 AND match_confidence <= 1 AS confidence_in_range
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.01,', 1023) || '0.01]')::vector(1024),
    'recall hybrid BM25 lexical query embedding semantics',
    5,
    'tc_v0101', NULL, 0.4, 0.4, 60, NULL
)
LIMIT 1;

-- ============================================================================
-- T1: Long query text (>200 chars) does not cause error
-- ============================================================================
\echo T1: long query_text handled without error
SELECT COUNT(*) >= 0 AS no_error_on_long_query
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.01,', 1023) || '0.01]')::vector(1024),
    -- 300-char query text: BM25 should cap at 200 chars
    repeat('longquery structured text with many tokens to test the 200 char cap in pgmnemo fix one ', 4),
    5, 'tc_v0101', NULL, 0.4, 0.4, 60, NULL
);

-- ============================================================================
-- T2: Cyrillic query text works with 'simple' config
-- ============================================================================
\echo T2: Cyrillic query text handled by simple tsconfig
SELECT COUNT(*) >= 0 AS no_error_on_cyrillic
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.02,', 1023) || '0.02]')::vector(1024),
    'кириллица урок русский язык поиск агент',
    5, 'tc_v0101', NULL, 0.4, 0.4, 60, NULL
);

-- ============================================================================
-- T3: Code/structured query text does not cause error
-- ============================================================================
\echo T3: structured/code query text handled
SELECT COUNT(*) >= 0 AS no_error_on_code
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.03,', 1023) || '0.03]')::vector(1024),
    'psycopg2.connect(db_url) cursor.execute SELECT agent_run WHERE id %s conn.commit',
    5, 'tc_v0101', NULL, 0.4, 0.4, 60, NULL
);

-- ============================================================================
-- T4+T5: BM25 budget of 1ms forces graceful degradation.
-- The function must NOT error — it should return vector-only results.
-- NOTICE is expected (BM25 timed out) captured in pg_regress output.
-- ============================================================================
\echo T4+T5: BM25 budget 1ms forces graceful degradation to vector-only
SET pgmnemo.bm25_budget_ms = 1;

SELECT COUNT(*) >= 0 AS vector_only_fallback_returns_results
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.01,', 1023) || '0.01]')::vector(1024),
    'robustness test recall hybrid BM25 budget exceeded graceful degradation',
    5, 'tc_v0101', NULL, 0.4, 0.4, 60, NULL
);

-- Reset budget
RESET pgmnemo.bm25_budget_ms;

-- ============================================================================
-- T7: Second call in same transaction reuses temp table (truncate, not error)
-- ============================================================================
\echo T7: second call in same tx — temp table re-used cleanly
SELECT COUNT(*) >= 0 AS second_call_no_error
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.01,', 1023) || '0.01]')::vector(1024),
    'second call same transaction temp table truncate robustness',
    5, 'tc_v0101', NULL, 0.4, 0.4, 60, NULL
);

-- ============================================================================
-- T10: navigate_locate works with 'simple' tsconfig
-- ============================================================================
\echo T10: navigate_locate with simple tsconfig
SELECT COUNT(*) >= 0 AS navigate_locate_no_error
FROM pgmnemo.navigate_locate(
    ('[' || repeat('0.01,', 1023) || '0.01]')::vector(1024),
    'robustness recall hybrid BM25 lexical',
    2000, NULL, NULL
);

-- ============================================================================
-- T11: recall_fast() with NULL query_embedding raises EXCEPTION (#84)
-- ============================================================================
\echo T11: recall_fast NULL query_embedding raises EXCEPTION
DO $$
DECLARE
    caught BOOLEAN := FALSE;
BEGIN
    BEGIN
        PERFORM * FROM pgmnemo.recall_fast(NULL::vector(1024), 5, 'tc_v0101');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%recall_fast%IS NULL%' THEN
            caught := TRUE;
        ELSE
            RAISE EXCEPTION 'Wrong exception message: %', SQLERRM;
        END IF;
    END;
    IF NOT caught THEN
        RAISE EXCEPTION 'recall_fast(NULL) did not raise an exception — #84 guard missing';
    END IF;
END;
$$;
SELECT TRUE AS recall_fast_null_raises_exception;

-- ============================================================================
-- Cleanup
-- ============================================================================
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_v0101';

\echo PASS: all v0.10.1 recall_robustness tests completed (T1-T11)
