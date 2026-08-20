-- test_v0200_graph_expand.sql
-- pg_regress suite: pgmnemo 0.20.0 — «Граф, который достаёт»
--
-- Assumes: extension installed at 0.20.0 (recall_hybrid has retrieval_source column,
--          stats() has 7 new graph expansion GUC columns).
-- REGRESS_OPTS in Makefile: --load-extension=vector --load-extension=pgmnemo
-- When run via pg_regress, a fresh DB is created with pgmnemo 0.20.0 loaded.
--
-- Coverage:
--   T1  structural: recall_hybrid prosrc has Variant A + Variant C + retrieval_source
--   T2  structural: stats() return signature has 7 new GUC columns
--   T3  stats() GUC defaults (all safe: 0.0 weights, sane counts)
--   T4  Variant C (entity GIN): entity_keys match → retrieval_source='entity'
--   T5  Entity expansion disabled when graph_entity_expand_weight = 0.0
--   T6  GIN containment correctness (R2_DB §7 fix)
--   T7  Variant A (BFS): causal edge reaches lesson outside ANN+BM25 pool
--   T8  Empty mem_edge + graph_expand_weight > 0 → 0 'graph' rows
--   T9  Cycle guard: cyclic edges terminate without error
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

-- ─────────────────────────────────────────────────────────────────────────────
-- T1: recall_hybrid prosrc has Variant A + Variant C + retrieval_source
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    prosrc ~ '_graph_expand_weight'        AS has_variant_a,
    prosrc ~ '_graph_entity_weight'        AS has_variant_c,
    prosrc ~ 'retrieval_source'            AS has_retrieval_source
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid' AND p.pronargs = 11;

-- ─────────────────────────────────────────────────────────────────────────────
-- T2: stats() return signature has 7 new GUC columns
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    pg_get_function_result(p.oid) ~ 'graph_expand_weight'        AS stats_has_variant_a_guc,
    pg_get_function_result(p.oid) ~ 'graph_entity_expand_weight' AS stats_has_variant_c_guc
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'stats' AND p.pronargs = 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- T3: stats() GUC defaults are all safe (0.0 weights / sane counts)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    graph_expand_weight = 0.0        AS a_weight_zero,
    graph_entity_expand_weight = 0.0 AS c_weight_zero,
    graph_expand_depth = 1           AS depth_one,
    graph_expand_ann_k = 15          AS ann_k_fifteen,
    graph_expand_per_node = 10       AS per_node_ten,
    graph_entity_min_overlap = 1     AS min_overlap_one,
    graph_entity_max_expansion = 50  AS max_exp_fifty
FROM pgmnemo.stats();

-- ─────────────────────────────────────────────────────────────────────────────
-- Setup: clean any prior test data
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE _ids BIGINT[];
BEGIN
    SELECT ARRAY(SELECT id FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200')
    INTO _ids;
    IF _ids IS NOT NULL AND array_length(_ids, 1) > 0 THEN
        DELETE FROM pgmnemo.mem_edge WHERE source_id = ANY(_ids) OR target_id = ANY(_ids);
    END IF;
    DELETE FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200';
END $$;

-- ── Variant C fixtures ───────────────────────────────────────────────────────
-- L_ent1, L_ent2: entity_key='model:claude-sonnet-4-6', text NOT BM25-matchable to probe
-- L_bm25: matches BM25 probe 'v0200probe zeta kappa omega', no entity key
-- L_both: matches BM25 probe AND has entity key
-- Query used by T4: 'claude-sonnet-4-6 v0200probe zeta kappa omega'
--   extract_entity_keys → ['model:claude-sonnet-4-6']
--   BM25 → NOTHING. The probe carries the token 'claude-sonnet-4-6', which lives
--   only in metadata and in no lesson body, and BM25 matching is conjunctive —
--   one absent token empties the whole pool. So under THIS probe every returned
--   row arrives through entity expansion, L_both included, and T4 exercises
--   Variant C alone. The pool-interaction claims it used to make here were never
--   true; T10 below uses a probe whose tokens do occur in the bodies, which is
--   what actually puts BM25 rows on the table.
--   Entity expansion → L_ent1, L_ent2, L_both
DO $$
BEGIN
    INSERT INTO pgmnemo.agent_lesson
        (role, topic, lesson_text, metadata, importance, verified_at)
    VALUES
        ('skill:test_v0200',
         'Entity alpha 1',
         'The quick brown fox jumped over the fence alpha',
         '{"entity_keys": ["model:claude-sonnet-4-6"]}', 3, NOW()),
        ('skill:test_v0200',
         'Entity alpha 2',
         'Lazy sleeping dog beside the river beta',
         '{"entity_keys": ["model:claude-sonnet-4-6"]}', 3, NOW()),
        ('skill:test_v0200',
         'BM25 probe lesson',
         'v0200probe zeta kappa omega unique marker text',
         '{}', 3, NOW()),
        ('skill:test_v0200',
         'Both BM25 and entity',
         'v0200probe zeta kappa omega also model text',
         '{"entity_keys": ["model:claude-sonnet-4-6"]}', 3, NOW());
END $$;

SELECT COUNT(*) AS entity_fixtures
FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200';

-- ─────────────────────────────────────────────────────────────────────────────
-- T4: Variant C — entity expansion puts L_ent1+L_ent2 in 'entity' pool
-- ─────────────────────────────────────────────────────────────────────────────
SET pgmnemo.graph_entity_expand_weight = '0.1';
SET pgmnemo.graph_entity_min_overlap = '1';

SELECT topic, retrieval_source
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'claude-sonnet-4-6 v0200probe zeta kappa omega',
    20,
    'skill:test_v0200'
)
ORDER BY topic;

-- ─────────────────────────────────────────────────────────────────────────────
-- T5: Entity expansion disabled when weight = 0.0 (default)
-- ─────────────────────────────────────────────────────────────────────────────
SET pgmnemo.graph_entity_expand_weight = '0.0';

SELECT COUNT(*) FILTER (WHERE retrieval_source = 'entity') AS entity_rows_when_disabled
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'claude-sonnet-4-6 v0200probe zeta kappa omega',
    20,
    'skill:test_v0200'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T6: GIN containment correctness (R2_DB §7)
-- Correct pattern: jsonb_build_object nesting → rows
-- Wrong pattern:   bare jsonb_build_array → 0 rows
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) AS correct_gin_rows
FROM pgmnemo.agent_lesson
WHERE is_active
  AND metadata @> jsonb_build_object('entity_keys', jsonb_build_array('model:claude-sonnet-4-6'))
  AND role = 'skill:test_v0200';

SELECT COUNT(*) AS wrong_gin_rows
FROM pgmnemo.agent_lesson
WHERE is_active
  AND metadata @> jsonb_build_array('model:claude-sonnet-4-6')
  AND role = 'skill:test_v0200';

-- ── Variant A BFS fixtures ───────────────────────────────────────────────────
-- L_anc: embedding=e1 (unit vec), BM25-matchable ('v0200probe bfs anchor')
-- L_tgt: embedding=NULL (outside ANN pool), causal edge from L_anc
-- BFS from ANN pool {L_anc} → reaches L_tgt → retrieval_source='graph'
DO $$
DECLARE
    _anc BIGINT;
    _tgt BIGINT;
    _e1  TEXT := '[' || '1,' || repeat('0,', 1022) || '0]';
BEGIN
    INSERT INTO pgmnemo.agent_lesson
        (role, topic, lesson_text, metadata, importance, embedding, verified_at)
    VALUES
        ('skill:test_v0200',
         'BFS anchor lesson',
         'v0200probe bfs anchor unit vector first dim',
         '{}', 4, _e1::vector(1024), NOW())
    RETURNING id INTO _anc;

    INSERT INTO pgmnemo.agent_lesson
        (role, topic, lesson_text, metadata, importance, verified_at)
    VALUES
        ('skill:test_v0200',
         'BFS target lesson',
         'completely different text not probe match xyz bfs target',
         '{}', 4, NOW())
    RETURNING id INTO _tgt;

    PERFORM pgmnemo.add_edge(_anc, _tgt, 'CAUSED_BY', 0.9);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- T7: Variant A — BFS reaches L_tgt via causal edge from ANN anchor L_anc
-- Query with e1 vector + probe text → L_anc in ANN+BM25 pool; L_tgt in graph pool
-- ─────────────────────────────────────────────────────────────────────────────
SET pgmnemo.graph_expand_weight = '0.2';
SET pgmnemo.graph_entity_expand_weight = '0.0';

SELECT topic, retrieval_source
FROM pgmnemo.recall_hybrid(
    ('[' || '1,' || repeat('0,', 1022) || '0]')::vector(1024),
    'v0200probe bfs anchor',
    30,
    'skill:test_v0200'
)
ORDER BY topic;

-- ─────────────────────────────────────────────────────────────────────────────
-- T8: Empty mem_edge + graph_expand_weight > 0 → 0 'graph' source rows
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE _ids BIGINT[];
BEGIN
    SELECT ARRAY(SELECT id FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200')
    INTO _ids;
    IF _ids IS NOT NULL AND array_length(_ids, 1) > 0 THEN
        DELETE FROM pgmnemo.mem_edge WHERE source_id = ANY(_ids) OR target_id = ANY(_ids);
    END IF;
END $$;

SELECT COUNT(*) FILTER (WHERE retrieval_source = 'graph') AS graph_rows_no_edges
FROM pgmnemo.recall_hybrid(
    ('[' || '1,' || repeat('0,', 1022) || '0]')::vector(1024),
    'v0200probe bfs anchor',
    30,
    'skill:test_v0200'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T9: Cycle guard — cyclic edges A→B, B→A must terminate without error
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    _la BIGINT; _lb BIGINT;
    _e1 TEXT := '[' || '1,' || repeat('0,', 1022) || '0]';
BEGIN
    INSERT INTO pgmnemo.agent_lesson
        (role, topic, lesson_text, metadata, importance, embedding, verified_at)
    VALUES
        ('skill:test_v0200', 'Cycle node A',
         'v0200probe cycle node alpha', '{}', 3, _e1::vector(1024), NOW())
    RETURNING id INTO _la;
    INSERT INTO pgmnemo.agent_lesson
        (role, topic, lesson_text, metadata, importance, verified_at)
    VALUES
        ('skill:test_v0200', 'Cycle node B',
         'v0200probe cycle node beta', '{}', 3, NOW())
    RETURNING id INTO _lb;
    PERFORM pgmnemo.add_edge(_la, _lb, 'CAUSED_BY', 0.8);
    PERFORM pgmnemo.add_edge(_lb, _la, 'CAUSED_BY', 0.8);
END $$;

SELECT COUNT(*) > 0 AS recall_terminates_with_cycle
FROM pgmnemo.recall_hybrid(
    ('[' || '1,' || repeat('0,', 1022) || '0]')::vector(1024),
    'v0200probe cycle node',
    30,
    'skill:test_v0200'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- T10: expansion is ADDITIVE — enabling an expander never removes a row that
-- the same query returned with the expander off. T4/T5 only show that entity
-- rows appear; nothing so far proved the base rows survive. The probe below is
-- BM25-matchable on its own (every token occurs in a lesson body), otherwise
-- the baseline arm is empty and the comparison is vacuous.
-- ─────────────────────────────────────────────────────────────────────────────
SET pgmnemo.graph_entity_expand_weight = '0.0';
CREATE TEMP TABLE _t10_off AS
SELECT lesson_id FROM pgmnemo.recall_hybrid(
    NULL::vector(1024), 'v0200probe zeta kappa omega', 20, 'skill:test_v0200',
    NULL, 0.0, 1.0, NULL, NULL, NULL, NULL);

SET pgmnemo.graph_entity_expand_weight = '0.1';
CREATE TEMP TABLE _t10_on AS
SELECT lesson_id FROM pgmnemo.recall_hybrid(
    NULL::vector(1024), 'v0200probe zeta kappa omega', 20, 'skill:test_v0200',
    NULL, 0.0, 1.0, NULL, NULL, NULL, NULL);

SELECT (SELECT COUNT(*) FROM _t10_off) > 0 AS baseline_non_empty,
       NOT EXISTS (SELECT lesson_id FROM _t10_off
                   EXCEPT SELECT lesson_id FROM _t10_on) AS nothing_lost_when_enabled;

DROP TABLE _t10_off;
DROP TABLE _t10_on;

-- ─────────────────────────────────────────────────────────────────────────────
-- T11: pools are DISJOINT by construction. entity_scores and graph_scores both
-- exclude everything already in the ANN and BM25 pools, so one lesson can never
-- carry two sources — the "priority entity > graph > ann" rule described in the
-- design docs has no reachable case. What must hold instead: every row appears
-- once, with exactly one source drawn from the allowed set.
-- ─────────────────────────────────────────────────────────────────────────────
SET pgmnemo.graph_entity_expand_weight = '0.1';
SET pgmnemo.graph_expand_weight = '0.2';

SELECT COUNT(*) = COUNT(DISTINCT lesson_id) AS each_lesson_once,
       COUNT(*) FILTER (WHERE retrieval_source IS NULL) AS null_source,
       COUNT(*) FILTER (WHERE retrieval_source NOT IN ('ann','graph','entity'))
                                                        AS unknown_source
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024), 'claude-sonnet-4-6 v0200probe zeta kappa omega', 20,
    'skill:test_v0200', NULL, 0.0, 1.0, NULL, NULL, NULL, NULL);

RESET pgmnemo.graph_expand_weight;
RESET pgmnemo.graph_entity_expand_weight;

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleanup
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE _ids BIGINT[];
BEGIN
    SELECT ARRAY(SELECT id FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200')
    INTO _ids;
    IF _ids IS NOT NULL AND array_length(_ids, 1) > 0 THEN
        DELETE FROM pgmnemo.mem_edge WHERE source_id = ANY(_ids) OR target_id = ANY(_ids);
    END IF;
    DELETE FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200';
END $$;

SELECT COUNT(*) AS remaining_test_lessons
FROM pgmnemo.agent_lesson WHERE role = 'skill:test_v0200';

RESET pgmnemo.graph_entity_expand_weight;
RESET pgmnemo.graph_expand_weight;
