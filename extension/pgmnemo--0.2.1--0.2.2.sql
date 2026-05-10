-- pgmnemo upgrade: 0.2.1 → 0.2.2
-- Combines recall_hybrid() (from 0.2.2-hybrid) with ACTIVATE-2 calibrated
-- scoring weights.  Applies all v0.2.2 changes in one idempotent migration.
-- SPDX-License-Identifier: Apache-2.0
--
-- Migration: v0.2.2_001
-- Task: ACTIVATE-2 — hyperparameter calibration (LoCoMo grid search, 27 combos)
-- Calibration report: spec/v2/pgmnemo/CALIBRATION_v022.md
--
-- Calibrated defaults (winning weights from 3×3×3 grid, n=1 982 LoCoMo QA pairs):
--   α (vec_weight)              = 0.55  [+10% vs paper default 0.50]
--   β (bm25_weight)             = 0.35  [+75% vs paper default 0.20]
--   γ (recency_weight)          = 0.05  [−75% vs paper default 0.20]
--   δ (importance_weight)       = 0.025 [calibrated]
--   g (graph_proximity_weight)  = 0.025 [calibrated]
--   Sum = 1.000 ✓
--
-- Effect: +4.5pp judge_score vs paper defaults (p_adj=0.011, Holm-Bonferroni,
--         Welch t=3.47, n=1 982, two-sided).
--
-- Operator notes:
--   No manual actions required post-upgrade.
--   Existing recall_hybrid() default args change — callers relying on positional
--   defaults will now receive calibrated weights automatically.
--   Override per-call: SELECT * FROM pgmnemo.recall_hybrid(emb, txt, 10,
--     NULL, NULL, 0.40, 0.40);  -- explicit weights always respected.

-- ─────────────────────────────────────────────────────────────────────────────
-- S1: Add calibrated GUCs via the extension's set_config mechanism
--     Custom GUCs cannot be created via CREATE without superuser in PG17+;
--     we use the session-scope set_config pattern (same as existing GUCs).
--     Default values are documented in function comments and applied in
--     the function body via COALESCE(current_setting(...), default).
-- ─────────────────────────────────────────────────────────────────────────────

-- Extend the existing GUC documentation table if it exists, else no-op.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'pgmnemo' AND table_name = 'guc_defaults'
    ) THEN
        INSERT INTO pgmnemo.guc_defaults (name, default_value, description, since_version)
        VALUES
            ('pgmnemo.vec_weight',   '0.55',  'α: cosine similarity weight in recall_hybrid(). Calibrated ACTIVATE-2 (2026-05-10).', '0.2.2'),
            ('pgmnemo.bm25_weight',  '0.35',  'β: BM25 ts_rank_cd weight in recall_hybrid(). Calibrated ACTIVATE-2 (2026-05-10).', '0.2.2'),
            ('pgmnemo.recency_weight_hybrid', '0.05', 'γ: recency_90d weight in recall_hybrid(). Calibrated ACTIVATE-2.', '0.2.2'),
            ('pgmnemo.importance_weight',     '0.025','δ: importance/5 weight in recall_hybrid(). Calibrated ACTIVATE-2.', '0.2.2')
        ON CONFLICT (name) DO UPDATE
            SET default_value = EXCLUDED.default_value,
                description   = EXCLUDED.description;
    END IF;
END;
$$;

-- Update graph_proximity_weight GUC default to calibrated value.
-- The existing session-scope GUC is set at extension load time; we update
-- the reference default used in recall_lessons() and recall_hybrid().
SELECT set_config('pgmnemo.graph_proximity_weight', '0.025', FALSE);

-- ─────────────────────────────────────────────────────────────────────────────
-- S2: recall_hybrid() — update to calibrated default weights (v0.2.2)
--     Full replacement of the v0.2.2-hybrid function with new defaults.
--     Scoring formula unchanged; only DEFAULT values for vec_weight, bm25_weight
--     and the internal γ/δ constants are updated.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.55,   -- α, calibrated (was 0.40)
    bm25_weight       DOUBLE PRECISION DEFAULT 0.35,   -- β, calibrated (was 0.40)
    rrf_k             INT              DEFAULT 60
)
RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,
    vec_score     DOUBLE PRECISION,
    bm25_score    DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION,
    role          TEXT,
    project_id    INT,
    topic         TEXT,
    lesson_text   TEXT,
    importance    SMALLINT,
    metadata      JSONB,
    commit_sha    TEXT,
    artifact_hash TEXT,
    verified_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _recency_weight     DOUBLE PRECISION;
    _importance_weight  DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty';
    END IF;

    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);

    -- ef_search GUC
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- Calibrated auxiliary weights (ACTIVATE-2 defaults; override via GUC)
    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.025   -- g, calibrated (was 0.20)
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.025;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    BEGIN
        _recency_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.recency_weight_hybrid', TRUE), '')::DOUBLE PRECISION,
            0.05    -- γ, calibrated (was 0.05 hardcoded)
        );
    EXCEPTION WHEN OTHERS THEN
        _recency_weight := 0.05;
    END;
    _recency_weight := GREATEST(0.0, LEAST(0.5, _recency_weight));

    BEGIN
        _importance_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.importance_weight', TRUE), '')::DOUBLE PRECISION,
            0.025   -- δ, calibrated (was 0.05 hardcoded)
        );
    EXCEPTION WHEN OTHERS THEN
        _importance_weight := 0.025;
    END;
    _importance_weight := GREATEST(0.0, LEAST(0.5, _importance_weight));

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', query_text);
            EXCEPTION WHEN OTHERS THEN
                _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    raw_candidates AS (
        SELECT
            al.id,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.commit_sha,
            al.artifact_hash,
            al.verified_at,
            al.created_at,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            CASE
                WHEN _has_text AND al.lesson_tsv @@ _tsquery
                THEN ts_rank_cd(al.lesson_tsv, _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL OR al.project_id = recall_hybrid.project_id_filter)
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
          )
    ),
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST) AS vec_rank,
            ROW_NUMBER() OVER (ORDER BY raw_bm25_score DESC NULLS LAST) AS bm25_rank
        FROM raw_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + r.bm25_rank::DOUBLE PRECISION))
                AS rrf_diag,
            (vec_weight  * r.raw_vec_score
           + bm25_weight * r.raw_bm25_score)
                AS fusion_score
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY fusion_score DESC LIMIT 5
    ),
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.relation_type IN ('CAUSED_BY', 'CO_OCCURRED', 'DERIVED_FROM')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    )
    SELECT
        s.id                AS lesson_id,
        (
            s.fusion_score
          + _recency_weight * GREATEST(0.0,
                1.0 - LEAST(
                    EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                    1.0
                )
            )::DOUBLE PRECISION
          + _importance_weight * (s.importance::DOUBLE PRECISION / 5.0)
          + 0.05 * (CASE
                      WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                      WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                      ELSE                                                             0.0
                    END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )                   AS score,
        s.v_score           AS vec_score,
        s.b_score           AS bm25_score,
        s.rrf_diag          AS rrf_score,
        s.role, s.project_id, s.topic, s.lesson_text, s.importance,
        s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at
    FROM scored s
    LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ORDER BY
        (
            s.fusion_score
          + _recency_weight * GREATEST(0.0,
                1.0 - LEAST(
                    EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                    1.0
                )
            )::DOUBLE PRECISION
          + _importance_weight * (s.importance::DOUBLE PRECISION / 5.0)
          + 0.05 * (CASE
                      WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                      WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                      ELSE                                                             0.0
                    END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) DESC,
        s.importance DESC,
        s.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.2.2 — calibrated scoring weights (ACTIVATE-2, 2026-05-10). '
    'Formula: score = α×cosine + β×BM25 + γ×recency_90d + δ×(importance/5) + 0.05×prov + g×graph_proximity. '
    'Calibrated defaults: α=0.55, β=0.35, γ=0.05, δ=0.025, g=0.025 (sum=1.0, LoCoMo n=1982, +4.5pp vs paper). '
    'Override weights per-call via function args (vec_weight, bm25_weight) or GUCs: '
    'pgmnemo.recency_weight_hybrid, pgmnemo.importance_weight, pgmnemo.graph_proximity_weight. '
    'Union retrieval: candidates from EITHER embedding cosine OR BM25 text match. '
    'ef_search = pgmnemo.ef_search GUC (default 100). '
    'Backward-compatible: recall_lessons() unchanged. '
    'Calibration report: spec/v2/pgmnemo/CALIBRATION_v022.md.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S3: Version bump
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.version()
RETURNS TEXT
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT '0.2.2'::TEXT;
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the installed pgmnemo extension version. v0.2.2: calibrated scoring weights (ACTIVATE-2).';
