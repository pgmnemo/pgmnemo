-- recall_hybrid_robustness.sql
-- pg_regress tests for pgmnemo v0.10.1: recall_hybrid() robustness (#87)
--
-- Coverage:
--   T1:  pgmnemo.bm25_budget_ms GUC exists and is readable after SET
--   T2:  pgmnemo.bm25_budget_ms can be set to 1 (low-budget test floor)
--   T3:  recall_hybrid() with Cyrillic query_text returns rows — no crash (Fix 1+4)
--   T4:  recall_hybrid() with query_text > 200 chars returns rows — 200-char cap (Fix 1)
--   T5:  recall_hybrid() with JSON/structured query_text returns rows — no crash (Fix 1+4)
--   T6:  BM25 graceful degradation: bm25_budget_ms=1 forces timeout, result non-empty (Fix 3)
--   T7:  tsconfig 'simple' in use: topic_tsv generated column uses 'simple' configuration (Fix 4)
--   T8:  recall_hybrid() still respects role_filter after tsconfig switch
--
-- Test vector: uniform 1024-dim vector array_fill(0.1, 1024)::vector(1024).
-- Role prefix: tc_rhb (recall_hybrid_robustness) — isolated from other tests.
--
-- Note: T6 uses client_min_messages=WARNING to suppress the BM25-timeout NOTICE
-- so the expected output is deterministic regardless of timeout message content.

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
ALTER EXTENSION pgmnemo UPDATE TO '0.12.1';

-- ============================================================================
-- Seed data: 3 lessons with embeddings in role tc_rhb
-- ============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, embedding)
VALUES
    ('tc_rhb', 'robustness alpha',
     'recall hybrid robustness test lesson alpha for bm25 degradation testing',
     'sha-rhb-1',
     (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024))),
    ('tc_rhb', 'robustness beta',
     'recall hybrid robustness test lesson beta for cyrillic query testing',
     'sha-rhb-2',
     (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024))),
    ('tc_rhb', 'robustness gamma',
     'recall hybrid robustness test lesson gamma for structured query testing',
     'sha-rhb-3',
     (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)));

-- ============================================================================
-- T1: pgmnemo.bm25_budget_ms GUC exists and is readable
-- ============================================================================

SET pgmnemo.bm25_budget_ms = 250;
SELECT current_setting('pgmnemo.bm25_budget_ms') = '250' AS t1_bm25_budget_guc_exists;

-- ============================================================================
-- T2: GUC minimum floor: bm25_budget_ms=1 is accepted (allows low-budget test)
-- ============================================================================

SET pgmnemo.bm25_budget_ms = 1;
SELECT current_setting('pgmnemo.bm25_budget_ms') = '1' AS t2_bm25_budget_min_settable;

RESET pgmnemo.bm25_budget_ms;

-- ============================================================================
-- T3: Cyrillic query_text returns rows without crash (Fix 1 + Fix 4: 'simple' tsconfig)
-- Expected: 3 rows in role tc_rhb — vector path works regardless of BM25 result.
-- ============================================================================

SELECT COUNT(*) = 3 AS t3_cyrillic_query_returns_rows
FROM pgmnemo.recall_hybrid(
    (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)),
    'Кириллический текст для тестирования устойчивости',  -- Cyrillic: 49 chars
    10,
    'tc_rhb',  -- role_filter
    NULL       -- project_id_filter
);

-- ============================================================================
-- T4: query_text > 200 chars is capped — returns rows without crash (Fix 1)
-- 300-char text (60 * 'word ') is truncated to 200 chars before tsquery.
-- ============================================================================

SELECT COUNT(*) = 3 AS t4_long_query_text_capped
FROM pgmnemo.recall_hybrid(
    (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)),
    'word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word',
    10,
    'tc_rhb',
    NULL
);

-- ============================================================================
-- T5: JSON/structured query_text handled without crash (Fix 1 + Fix 4)
-- Special characters {, :, ->, [ cause to_tsquery syntax errors in 'english'
-- config. 'simple' config + websearch_to_tsquery normalises them.
-- ============================================================================

SELECT COUNT(*) = 3 AS t5_json_query_text_no_crash
FROM pgmnemo.recall_hybrid(
    (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)),
    '{"action": "query->optimize", "filters": [{"col": "embed", "op": "!=", "val": null}]}',
    10,
    'tc_rhb',
    NULL
);

-- ============================================================================
-- T6: BM25 graceful degradation under tight time budget (Fix 3)
-- bm25_budget_ms=1 forces statement_timeout on the BM25 INSERT; the function
-- must catch query_canceled, set _has_text=FALSE, and continue with vector-only.
-- Result: non-empty (vector path still fires). NOTICE suppressed for stable output.
-- ============================================================================

SET client_min_messages = WARNING;
SET pgmnemo.bm25_budget_ms = 1;

SELECT COUNT(*) = 3 AS t6_bm25_timeout_degrades_gracefully
FROM pgmnemo.recall_hybrid(
    (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)),
    'bm25 degradation test trigger text for timeout guard',
    10,
    'tc_rhb',
    NULL
);

RESET pgmnemo.bm25_budget_ms;
RESET client_min_messages;

-- ============================================================================
-- T7: tsconfig 'simple' on stored tsvector columns (Fix 4)
-- topic_tsv generation expression must reference 'simple', not 'english'.
-- ============================================================================

SELECT
    pg_get_expr(d.adbin, d.adrelid) LIKE '%simple%' AS t7_topic_tsv_uses_simple_config
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE n.nspname = 'pgmnemo'
  AND c.relname = 'agent_lesson'
  AND a.attname = 'topic_tsv';

-- ============================================================================
-- T8: role_filter still works after tsconfig switch
-- ============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, embedding)
VALUES ('tc_rhb_other', 'other role lesson',
        'this lesson belongs to a different role and must not appear in tc_rhb recall',
        'sha-rhb-other',
        (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)));

SELECT COUNT(*) = 3 AS t8_role_filter_isolates_results
FROM pgmnemo.recall_hybrid(
    (SELECT array_fill(0.1::float4, ARRAY[1024])::vector(1024)),
    'robustness test role filter',
    10,
    'tc_rhb',    -- must NOT return tc_rhb_other row
    NULL
);

-- ============================================================================
-- Cleanup
-- ============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role IN ('tc_rhb', 'tc_rhb_other');
