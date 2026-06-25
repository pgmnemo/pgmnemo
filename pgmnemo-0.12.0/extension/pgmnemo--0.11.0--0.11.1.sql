-- pgmnemo--0.11.0--0.11.1.sql
-- pgmnemo upgrade 0.11.0 → 0.11.1
-- MEM-ERA-0111: typed recall on the hot path — p_content_types mirrored to
-- recall_fast(), recall_lessons() (0.11.0 added it only to recall_hybrid).
--
-- Changes (backward-compatible PATCH):
--   recall_fast()    5 params → 6 (p_content_types TEXT[] DEFAULT NULL, LAST)
--   recall_lessons() 7 params → 8 (p_content_types TEXT[] DEFAULT NULL, LAST)
--
--   NULL  → unchanged behavior (all content types; full backward compat).
--   non-NULL → pushes content_type = ANY(p_content_types) into the WHERE clause
--               as a pushdown predicate, NOT a post-filter.
--               Uses index ix_pgmnemo_content_type_active
--               (WHERE is_active AND content_type IS NOT NULL).
--   '{}'  → zero rows (explicit empty array — no silent fallback to all-types).
--
-- recall_lessons(): when routing to recall_hybrid() (hybrid path), p_content_types
--   is forwarded to the recall_hybrid() call so pushdown is applied there.
--   When executing the vector-only path, the WHERE predicate is applied directly.
--
-- No schema column changes. No data migration. No other function changed.
-- Users on 0.10.x should apply pgmnemo--0.10.1--0.11.0.sql first, then this file.
--
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.11.1'" to load this file. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. recall_fast() — 5 → 6 params: add p_content_types TEXT[] DEFAULT NULL
--
-- Drop the old 5-param overload to prevent ambiguous-function errors when
-- callers pass exactly 5 positional arguments. The 6-param version is
-- backward-compatible: existing 5-arg call sites pick up the DEFAULT NULL.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_fast(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    exclude_dag_id    TEXT    DEFAULT NULL,
    p_content_types   TEXT[]  DEFAULT NULL   -- P0.2: typed recall; NULL=all types
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
    created_at    TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _track_recency      BOOLEAN;
BEGIN
    -- Set HNSW ef_search from GUC (same pattern as recall_hybrid)
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    BEGIN
        _track_recency := COALESCE(
            NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN, TRUE);
    EXCEPTION WHEN OTHERS THEN _track_recency := TRUE;
    END;

    -- #84: reject NULL query_embedding early — HNSW-only path has no text fallback.
    -- recall_hybrid() accepts NULL query_embedding when query_text is present; recall_fast
    -- is vector-only and cannot fall back to BM25, so NULL embedding is always an error.
    IF query_embedding IS NULL THEN
        RAISE EXCEPTION
            'pgmnemo.recall_fast: query_embedding IS NULL -- '
            'a vector embedding is required for HNSW search. '
            'recall_fast has no text-only fallback; use recall_hybrid() '
            'if you have query_text but no embedding.';
    END IF;

    RETURN QUERY
    WITH fast_ranked AS (
        SELECT
            al.id,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS vec_score,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.commit_sha,
            al.artifact_hash,
            al.verified_at,
            al.created_at
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_fast.role_filter IS NULL
               OR al.role = recall_fast.role_filter)
          AND (recall_fast.project_id_filter IS NULL
               OR al.project_id = recall_fast.project_id_filter)
          AND (recall_fast.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_fast.exclude_dag_id)
          -- P0.2: typed recall pushdown (ix_pgmnemo_content_type_active)
          AND (recall_fast.p_content_types IS NULL
               OR al.content_type = ANY(recall_fast.p_content_types))
        ORDER BY al.embedding <=> query_embedding
        LIMIT k
    ),
    stamped AS (
        UPDATE pgmnemo.agent_lesson al2
        SET
            last_recalled_at = NOW(),
            recall_count     = al2.recall_count + 1
        FROM fast_ranked fr
        WHERE al2.id = fr.id
          AND _track_recency
        RETURNING al2.id
    )
    SELECT
        fr.id          AS lesson_id,
        fr.vec_score   AS score,
        fr.role,
        fr.project_id,
        fr.topic,
        fr.lesson_text,
        fr.importance,
        fr.metadata,
        fr.commit_sha,
        fr.artifact_hash,
        fr.verified_at,
        fr.created_at
    FROM fast_ranked fr
    -- stamped CTE is a side-effect sink; reference it to prevent optimiser elision
    LEFT JOIN stamped s ON s.id = fr.id
    ORDER BY fr.vec_score DESC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT, TEXT[]) IS
    'HNSW-only vector recall — O(k log n), no BM25/graph/RRF. '
    'Uses ORDER BY embedding <=> query LIMIT k to activate the HNSW index. '
    'score = cosine similarity (1 - distance). '
    'Respects include_unverified, ef_search, track_recall_recency GUCs. '
    'Filters: role_filter, project_id_filter, exclude_dag_id (same as recall_hybrid). '
    'v0.10.0: default MCP recall path. Use recall_hybrid for full 6-signal fusion. '
    'v0.10.1 #84: raises EXCEPTION when query_embedding IS NULL (no text-only fallback). '
    'v0.11.1: p_content_types TEXT[] DEFAULT NULL (6th param) — typed recall pushdown '
    'using ix_pgmnemo_content_type_active. NULL=all types (backward-compatible). '
    'Non-NULL restricts candidates to the given content_type values before HNSW ranking.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. recall_lessons() — 7 → 8 params: add p_content_types TEXT[] DEFAULT NULL
--
-- Drop the old 7-param overload to prevent ambiguous-function errors.
-- The 8-param version is backward-compatible: existing 7-arg call sites pick
-- up DEFAULT NULL, and 6-arg calls (recall_lessons_pooled) remain unchanged.
--
-- Hybrid path:   p_content_types forwarded to recall_hybrid() as 10th param.
-- Vector-only path: WHERE pushdown on content_type = ANY(p_content_types).
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT         DEFAULT 10,
    role_filter       TEXT        DEFAULT NULL,
    project_id_filter INT         DEFAULT NULL,
    query_text        TEXT        DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ DEFAULT NULL,
    exclude_dag_id    TEXT        DEFAULT NULL,
    p_content_types   TEXT[]      DEFAULT NULL   -- P0.2: typed recall; NULL=all types
)
RETURNS TABLE (
    lesson_id        BIGINT,
    score            DOUBLE PRECISION,
    role             TEXT,
    project_id       INT,
    topic            TEXT,
    lesson_text      TEXT,
    importance       SMALLINT,
    metadata         JSONB,
    commit_sha       TEXT,
    artifact_hash    TEXT,
    verified_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ,
    vec_score        DOUBLE PRECISION,
    bm25_score       DOUBLE PRECISION,
    rrf_score        DOUBLE PRECISION,
    confidence       REAL,
    match_confidence REAL
)
LANGUAGE plpgsql
VOLATILE
AS $func$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _ghost_count        INT;
BEGIN
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT, 2000);
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars. Original: %',
                     _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    _has_vec  := query_embedding IS NOT NULL;
    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _disable_hybrid := FALSE;
    END;

    -- Hybrid path delegates to recall_hybrid (which handles stamping + exclude_dag_id)
    -- P0.2: p_content_types forwarded as the 10th argument of recall_hybrid().
    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60,
            exclude_dag_id, p_content_types   -- P0.2: pass typed recall filter
        ) h;
        RETURN;
    END IF;

    -- Vector-only path (pgmnemo.disable_hybrid = 'true' or no query_text)
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION, 0.05);
    _temporal_boost := GREATEST(0.0, LEAST(20.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION, 1.0)));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));  -- Fix 5: OPT-IN default (was 0.2)
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(_query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', left(trim(_query_text), 200));   -- Fix 4+1
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    candidates AS (
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
            al.confidence,
            CASE
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery     -- Fix 2: indexed full_text
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL
               OR al.project_id = recall_lessons.project_id_filter)
          AND (recall_lessons.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_lessons.exclude_dag_id)
          AND (al.embedding IS NOT NULL OR _has_text)
          -- P0.2: typed recall pushdown (ix_pgmnemo_content_type_active)
          AND (recall_lessons.p_content_types IS NULL
               OR al.content_type = ANY(recall_lessons.p_content_types))
    ),
    anchors AS (
        SELECT id FROM candidates ORDER BY vec_score DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0  -- Fix 5
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    scored AS (
        SELECT
            c.id, c.role, c.project_id, c.topic, c.lesson_text, c.importance,
            c.metadata, c.commit_sha, c.artifact_hash, c.verified_at, c.created_at,
            c.confidence,
            c.vec_score,
            c.ft_score,
            (c.vec_score + _gamma * GREATEST(0.0, 1.0 - LEAST(
                 EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0), 1.0
             ))) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
             + c.ft_score * 0.1
             AS combined_score
        FROM candidates c
        LEFT JOIN graph_proximity gp ON gp.lesson_id = c.id
    )
    SELECT
        s.id                  AS lesson_id,
        s.combined_score      AS score,
        s.role,
        s.project_id,
        s.topic,
        s.lesson_text,
        s.importance,
        s.metadata,
        s.commit_sha,
        s.artifact_hash,
        s.verified_at,
        s.created_at,
        s.vec_score,
        s.ft_score            AS bm25_score,
        0.0::DOUBLE PRECISION AS rrf_score,
        s.confidence::REAL,
        LEAST(1.0, GREATEST(0.0, s.vec_score))::REAL AS match_confidence
    FROM scored s
    ORDER BY s.combined_score DESC, s.id ASC
    LIMIT k;

    IF NOT FOUND THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active AND al.t_valid_to = 'infinity'::TIMESTAMPTZ AND al.verified_at IS NULL
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL
               OR al.project_id = recall_lessons.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % unverified lesson(s) excluded. '
                'SET pgmnemo.include_unverified = ''on'' to include them.',
                _ghost_count;
        END IF;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ, TEXT, TEXT[]) IS
    'v0.11.1 hybrid router with diagnostic columns and typed recall. '
    'Routes to recall_hybrid() when both query_embedding and query_text are present '
    '(and pgmnemo.disable_hybrid is FALSE/unset). '
    'Falls back to vector-only (HNSW + recency + graph) when query_text is absent. '
    'p_content_types TEXT[] DEFAULT NULL (8th param, v0.11.1): typed recall pushdown. '
    'On the hybrid path: forwarded to recall_hybrid() as the 10th argument. '
    'On the vector-only path: applied as WHERE content_type = ANY(p_content_types). '
    'NULL=all types (backward-compatible). Non-NULL filters by content type before ranking. '
    'GIN-indexed for BM25 retrieval via ts_rank_cd in recall_hybrid(). '
    'Respects pgmnemo.disable_hybrid, ef_search, include_unverified, recency_weight, '
    'temporal_boost, graph_proximity_weight, max_query_text_chars GUCs.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Version bump notice
-- ─────────────────────────────────────────────────────────────────────────────

DO $$ BEGIN
    RAISE NOTICE 'pgmnemo version "0.11.1" installed successfully.';
END $$;
