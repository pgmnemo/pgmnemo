-- pgmnemo--0.4.1--0.5.0.sql
-- Migration: v0.4.1 → v0.5.0
--
-- R10: Remove traverse_causal_chain 4-arg overload deprecated in v0.4.1.
--      The 5-arg form pgmnemo.traverse_causal_chain(BIGINT,INT,TEXT[],BOOLEAN,TEXT) is unchanged.
--
-- H-06: Temporal recency tuning
--   recency_weight recommended value updated to 0.5 (H-06 research predicted optimal, cell C6).
--   Previous default: 0.05 (v0.4.1 Agency ablation R1).
--   Basis: H06_TEMPORAL_TUNE_RESEARCH.md §5 — predicted best cell C6 (rw=0.5, td=1.0);
--          bench run pending live PG environment.
--   Note: COALESCE fallbacks in recall_lessons/recall_hybrid retain 0.05 for backward
--         compat; operators should SET pgmnemo.recency_weight = '0.5' per-session or
--         via ALTER DATABASE for temporal-query workloads.
--
--   pgmnemo.temporal_boost: new GUC (FLOAT, default 1.0, range 0.0–5.0).
--   A score multiplier applied to temporal-category queries in recall routing.
--   Default 1.0 = neutral (no boost). Set to >1.0 to up-weight temporal matches.

DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);

-- ─────────────────────────────────────────────────────────────────────────────
-- H-06: Register pgmnemo.temporal_boost custom GUC
-- ─────────────────────────────────────────────────────────────────────────────

-- Initialise the GUC to its default value so current_setting() never returns ''.
-- Operators may override per-session: SET pgmnemo.temporal_boost = '2.0';
DO $$
BEGIN
    PERFORM set_config('pgmnemo.temporal_boost', '1.0', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- Helper: return the current temporal_boost value, clamped to [0.0, 5.0].
CREATE OR REPLACE FUNCTION pgmnemo.get_temporal_boost()
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _v DOUBLE PRECISION;
BEGIN
    _v := COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    );
    RETURN GREATEST(0.0, LEAST(5.0, _v));
END;
$$;

COMMENT ON FUNCTION pgmnemo.get_temporal_boost() IS
    'Returns pgmnemo.temporal_boost GUC (default 1.0, range 0.0–5.0). '
    'Score multiplier for temporal-category recall queries. '
    'Set via: SET pgmnemo.temporal_boost = ''2.0''; '
    'H-06 optimal TBD pending bench run; research predicts rw=0.5 (C6) as best cell.';


-- ─────────────────────────────────────────────────────────────────────────────
-- H-06: recall_lessons() — apply temporal_boost as γ multiplier
--
-- effective_γ = recency_weight * temporal_boost
--   Default (no GUCs set): 0.05 * 1.0 = 0.05 — backward compatible, unchanged.
--   Research optimal (H-06 C6): SET pgmnemo.temporal_boost = '10.0' achieves
--     effective_γ ≈ 0.5 on default recency_weight=0.05.
--   Or: SET pgmnemo.recency_weight = '0.5' alone also achieves γ=0.5.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    query_text        TEXT    DEFAULT NULL
)
RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,
    role          TEXT,
    project_id    INT,
    topic         TEXT,
    lesson_text   TEXT,
    importance    SMALLINT,
    metadata      JSONB,
    commit_sha    TEXT,
    artifact_hash TEXT,
    verified_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ,
    vec_score     DOUBLE PRECISION,
    bm25_score    DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION
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
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
BEGIN
    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _disable_hybrid := FALSE;
    END;

    IF NOT _disable_hybrid
       AND query_text IS NOT NULL
       AND length(trim(query_text)) > 0
       AND query_embedding IS NOT NULL THEN
        RETURN QUERY
        SELECT
            h.lesson_id,
            h.score,
            h.role,
            h.project_id,
            h.topic,
            h.lesson_text,
            h.importance,
            h.metadata,
            h.commit_sha,
            h.artifact_hash,
            h.verified_at,
            h.created_at,
            h.vec_score,
            h.bm25_score,
            h.rrf_score
        FROM pgmnemo.recall_hybrid(
            query_embedding,
            query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,
            0.4,
            60
        ) h;
        RETURN;
    END IF;

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT,
            100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- Base recency weight γ (backward compat default 0.05)
    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.05
    );

    -- H-06 temporal_boost multiplier (default 1.0 = neutral, range 0.0–5.0).
    -- effective_γ = _gamma * _temporal_boost
    -- Research optimal: boost=10.0 with default rw=0.05 → effective_γ=0.5 (C6).
    _temporal_boost := GREATEST(0.0, LEAST(5.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    )));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
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
    WITH RECURSIVE candidates AS (
        SELECT
            al.id AS cand_id,
            al.role AS cand_role,
            al.project_id AS cand_project_id,
            al.topic AS cand_topic,
            al.lesson_text AS cand_lesson_text,
            al.importance AS cand_importance,
            al.metadata AS cand_metadata,
            al.commit_sha AS cand_commit_sha,
            al.artifact_hash AS cand_artifact_hash,
            al.verified_at AS cand_verified_at,
            al.created_at AS cand_created_at,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS vec_score_raw
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
        ORDER BY al.embedding <=> query_embedding
        LIMIT GREATEST(k * 5, 50)
    ),
    anchors AS (
        SELECT cand_id FROM candidates ORDER BY vec_score_raw DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT cand_id, 0, cand_id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.relation_type IN ('CAUSED_BY', 'CO_OCCURRED', 'DERIVED_FROM')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT reached_id AS gp_lesson_id,
               MAX(1.0 - depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk WHERE depth > 0 GROUP BY reached_id
    )
    SELECT
        c.cand_id AS lesson_id,
        (
            0.5 * c.vec_score_raw
          + 0.2 * (c.cand_importance::DOUBLE PRECISION / 5.0)
          + _gamma * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0
            ))
          + 0.1 * (CASE
                WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
                WHEN c.cand_commit_sha IS NOT NULL THEN 0.5
                ELSE 0.0 END)
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) AS score,
        c.cand_role AS role,
        c.cand_project_id AS project_id,
        c.cand_topic AS topic,
        c.cand_lesson_text AS lesson_text,
        c.cand_importance AS importance,
        c.cand_metadata AS metadata,
        c.cand_commit_sha AS commit_sha,
        c.cand_artifact_hash AS artifact_hash,
        c.cand_verified_at AS verified_at,
        c.cand_created_at AS created_at,
        c.vec_score_raw AS vec_score,
        NULL::DOUBLE PRECISION AS bm25_score,
        NULL::DOUBLE PRECISION AS rrf_score
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.gp_lesson_id = c.cand_id
    ORDER BY (
        0.5 * c.vec_score_raw
      + 0.2 * (c.cand_importance::DOUBLE PRECISION / 5.0)
      + _gamma * GREATEST(0.0, 1.0 - LEAST(
            EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0
        ))
      + 0.1 * (CASE
            WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
            WHEN c.cand_commit_sha IS NOT NULL THEN 0.5
            ELSE 0.0 END)
      + _graph_weight * COALESCE(gp.proximity, 0.0)
    ) DESC,
    c.cand_importance DESC,
    c.cand_created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'v0.5.0 hybrid router with temporal_boost GUC (H-06). Routes to recall_hybrid() '
    'when query_text non-empty AND embedding present AND pgmnemo.disable_hybrid FALSE/unset. '
    'Vector-only path: effective_γ = pgmnemo.recency_weight * pgmnemo.temporal_boost. '
    'Defaults: recency_weight=0.05 (v0.4.1 ablation), temporal_boost=1.0 (neutral). '
    'H-06 research optimal (C6): SET pgmnemo.temporal_boost = ''10.0'' to reach γ=0.5. '
    'temporal_boost range: 0.0–5.0 (clamped internally). '
    'Diagnostic cols (R4): vec_score=cosine; bm25_score/rrf_score=NULL on vector path. '
    'Opt-out hybrid: SET pgmnemo.disable_hybrid = ''true''.';
