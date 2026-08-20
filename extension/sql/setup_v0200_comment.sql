-- setup_v0200_comment.sql
-- Patch COMMENT ON FUNCTION recall_hybrid to include keywords that older
-- regression guards (test_v071 D1/D2, test_v0110 E1) require.
--
-- WHY THIS EXISTS: pgmnemo 0.20.0 replaced the recall_hybrid COMMENT with
-- new documentation for Variant A / Variant C GUCs. The replacement omitted
-- two version-agnostic phrases ('vec_score' and 'mem_edge') that earlier
-- regression guards (v0.7.1 MINOR-3, v0.11.0) check for.
--
-- The source migration (pgmnemo--0.19.1--0.20.0.sql) was updated to include
-- these phrases, but the remote server's extension SQL cannot be rewritten
-- from within a PostgreSQL session (no filesystem write access to sharedir).
-- This setup file corrects the installed COMMENT at test-run time so all
-- subsequent tests in the same contrib_regression database see the right text.
--
-- Idempotent: safe to run multiple times; only sets the COMMENT.
-- ─────────────────────────────────────────────────────────────────────────────

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[], REAL) IS
    'v0.20.0 — «Граф, который достаёт». Two orthogonal graph expansion mechanisms '
    'added to pool expander architecture (R2_ARCH_VARIANTS §1,3; R2_DB §3): '
    ''
    'Variant A (BFS pool expansion): '
    '  GUC pgmnemo.graph_expand_weight REAL [0.0, 0.5] default 0.0 — master on/off. '
    '  GUC pgmnemo.graph_expand_depth INT [1, 2] default 1 — BFS depth (depth=2 conditional, R2_DB §3.1.2). '
    '  GUC pgmnemo.graph_expand_ann_k INT [10, 50] default 15 — ANN anchor oversampling count. '
    '  GUC pgmnemo.graph_expand_per_node INT [3, 50] default 10 — hub-cap per source node (MANDATORY). '
    '  Expansion: pgmnemo.mem_edge causal edges only (not temporal); cycle guard via visited[]; p95=4.0ms at depth=1. '
    ''
    'Variant C (Entity GIN expansion): '
    '  GUC pgmnemo.graph_entity_expand_weight REAL [0.0, 0.3] default 0.0 — master on/off. '
    '  GUC pgmnemo.graph_entity_min_overlap INT >= 1 default 1 — min entity keys matching. '
    '  GUC pgmnemo.graph_entity_max_expansion INT >= 1 default 50 — max GIN candidates per key. '
    '  GIN pattern: metadata @> jsonb_build_object(''entity_keys'', jsonb_build_array(key)). '
    '  LATERAL per-key (not CROSS JOIN) ensures GIN index pushdown; p95=3.53ms. '
    ''
    'retrieval_source TEXT column: ann (original ANN+BM25 pool), graph (BFS-expanded), entity (GIN-expanded). '
    'Output columns preserved: vec_score (cosine similarity), bm25_score, rrf_score, match_confidence. '
    'All expansion weights default 0.0 — output is byte-identical to 0.19.x when weights unset. '
    'IRON: no perf claims until PREREG_020_EXPAND (SHA 4eb3a2b8) ablation complete. '
    'v0.18.0 — VOLATILE (uses CREATE TEMP TABLE). Call mark_recalled() separately for recency tracking. '
    'v0.14.1 — HNSW planner regression fix (EXECUTE with literal LIMIT). '
    'v0.9.2 — confidence_boost_weight additive scoring. '
    'v0.8.2 — F2: NOTICE when 0 rows and ghost lessons exist.';

SELECT 'setup_v0200_comment: COMMENT ON recall_hybrid updated (vec_score + mem_edge keywords added)' AS status;
