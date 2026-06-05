\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.8.2'" to load this file. \quit
-- pgmnemo upgrade script: 0.8.1 → 0.8.2
-- SPDX-License-Identifier: Apache-2.0
--
-- Fixes:
--   F1 — traverse_temporal_window: unify include_unverified parsing to
--         COALESCE(current_setting(...)::BOOLEAN, FALSE), matching all other
--         recall functions (accepts on/true/1/yes, not just 'on').
--   F2 — recall_lessons + recall_hybrid: RAISE NOTICE when 0 rows returned
--         but ghost lessons (verified_at IS NULL) exist in scope, guiding
--         adopters to SET pgmnemo.include_unverified = 'on'.
--
-- All changes are body-only; no schema changes; no scoring/ranking change.

-- =============================================================================
-- F1: traverse_temporal_window — fix include_unverified parsing
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.traverse_temporal_window(
    start_id            BIGINT,
    window_interval     INTERVAL    DEFAULT INTERVAL '15 minutes',
    include_unlinked    BOOLEAN     DEFAULT TRUE,
    role_filter         TEXT        DEFAULT NULL,
    project_id_filter   INT         DEFAULT NULL,
    k                   INT         DEFAULT 20
)
RETURNS TABLE (
    lesson_id       BIGINT,
    time_delta_sec  DOUBLE PRECISION,
    linked          BOOLEAN,
    edge_weight     REAL,
    role            TEXT,
    topic           TEXT,
    lesson_text     TEXT,
    importance      SMALLINT,
    created_at      TIMESTAMPTZ,
    commit_sha      TEXT,
    verified_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _start_ts           TIMESTAMPTZ;
    _include_unverified BOOLEAN;
BEGIN
    SELECT al.created_at INTO _start_ts
    FROM pgmnemo.agent_lesson al
    WHERE al.id = start_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- F1 fix: use ::BOOLEAN cast (accepts on/true/1/yes) not string-compare = 'on'
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    RETURN QUERY
    WITH candidates AS (
        SELECT
            al.id,
            al.role,
            al.topic,
            al.lesson_text,
            al.importance,
            al.created_at,
            al.commit_sha,
            al.verified_at,
            ABS(EXTRACT(EPOCH FROM (al.created_at - _start_ts))) AS delta_sec
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.id <> start_id
          AND al.created_at BETWEEN (_start_ts - window_interval)
                                AND (_start_ts + window_interval)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter         IS NULL OR al.role       = role_filter)
          AND (project_id_filter   IS NULL OR al.project_id = project_id_filter)
    ),
    edges AS (
        SELECT e.target_id AS other_id, e.weight
        FROM pgmnemo.mem_edge e
        WHERE e.source_id = start_id
          AND e.valid_until IS NULL
        UNION ALL
        SELECT e.source_id AS other_id, e.weight
        FROM pgmnemo.mem_edge e
        WHERE e.target_id = start_id
          AND e.valid_until IS NULL
    )
    SELECT
        c.id                            AS lesson_id,
        c.delta_sec                     AS time_delta_sec,
        (e.weight IS NOT NULL)          AS linked,
        e.weight                        AS edge_weight,
        c.role,
        c.topic,
        c.lesson_text,
        c.importance,
        c.created_at,
        c.commit_sha,
        c.verified_at
    FROM candidates c
    LEFT JOIN edges e ON e.other_id = c.id
    WHERE include_unlinked OR e.weight IS NOT NULL
    ORDER BY c.delta_sec ASC, c.importance DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_temporal_window(BIGINT, INTERVAL, BOOLEAN, TEXT, INT, INT) IS
    'Return up to k agent_lesson rows whose created_at falls within ±window_interval of start_id. '
    'linked=TRUE when a mem_edge (any direction) exists between that row and start_id. '
    'include_unlinked=FALSE restricts output to explicitly connected lessons. '
    'v0.8.2 F1: include_unverified parsed via ::BOOLEAN (accepts on/true/1/yes).';


-- =============================================================================
-- F2: recall_hybrid — ghost guidance NOTICE when 0 rows returned
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60
)
RETURNS TABLE (
    lesson_id        BIGINT,
    score            DOUBLE PRECISION,
    vec_score        DOUBLE PRECISION,
    bm25_score       DOUBLE PRECISION,
    rrf_score        DOUBLE PRECISION,
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
    confidence       REAL,
    match_confidence REAL
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $func$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _raw_blend_weight   DOUBLE PRECISION;
    _ghost_count        INT;   -- F2: ghost guidance
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION
            'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty -- '
            'at least one retrieval signal is required';
    END IF;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

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
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.2;
    END;

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', query_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
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
            al.confidence,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            -- v0.8.1 F3: topic in BM25 — setweight(topic, 'A') || lesson_tsv
            CASE
                WHEN _has_text AND (al.lesson_tsv @@ _tsquery
                     OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND (al.lesson_tsv @@ _tsquery
               OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery))
          )
    ),
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)   AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                           AS bm25_rank_sparse
        FROM raw_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at, r.confidence,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            -- v0.8.1 F2: ordinal RRF + cardinal raw score blend
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 vec_weight  * r.raw_vec_score
               + bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
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
    final AS (
        SELECT
            s.id,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.025 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.025 * s.confidence::DOUBLE PRECISION
                  + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0), 1.0))
                  + 0.05 * (CASE
                                WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                                WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                                ELSE 0.0 END)
                )
            -- v0.8.1 F1: graph is multiplicative re-rank (tie-breaker, not driver)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    )
    SELECT
        f.id                   AS lesson_id,
        f.final_score          AS score,
        f.v_score              AS vec_score,
        f.b_score              AS bm25_score,
        f.rrf_sparse           AS rrf_score,
        f.role,
        f.project_id,
        f.topic,
        f.lesson_text,
        f.importance,
        f.metadata,
        f.commit_sha,
        f.artifact_hash,
        f.verified_at,
        f.created_at,
        f.confidence::REAL,
        LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence
    FROM final f
    ORDER BY f.final_score DESC
    LIMIT k;

    -- F2: ghost guidance — if 0 rows returned, check for unverified (ghost) lessons in scope
    IF NOT FOUND THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND al.verified_at IS NULL
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % matching lesson(s) are unverified (ingested without commit_sha/artifact_hash) '
                'and excluded by default. SET pgmnemo.include_unverified = ''on'' for this session, '
                'or pass provenance on ingest.',
                _ghost_count;
        END IF;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.8.2 — F2: NOTICE when 0 rows and ghost lessons exist in scope. '
    'v0.7.1 -- match_confidence formula corrected (BUG-1), graph_proximity note added. '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Scoring: rrf_sparse + _aux_scale*(0.025*imp/5 + 0.025*conf + 0.05*recency + 0.05*prov) + delta*graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'graph_proximity contributes only when mem_edge is populated; with no edges the graph term is 0 (correct, not a bug). '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL).';


-- =============================================================================
-- F2: recall_lessons (v0.7.0, 6-arg) — ghost guidance NOTICE on vector-only path
-- Note: hybrid path delegates to recall_hybrid which issues its own notice;
--       ghost check here covers the vector-only path only (avoids double notice).
-- =============================================================================

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(
    vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ
);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT         DEFAULT 10,
    role_filter       TEXT        DEFAULT NULL,
    project_id_filter INT         DEFAULT NULL,
    query_text        TEXT        DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ DEFAULT NULL
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
STABLE
PARALLEL SAFE
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
    _ghost_count        INT;   -- F2: ghost guidance
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

    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        -- Hybrid path: delegate to recall_hybrid (which issues its own ghost notice on 0 rows)
        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60
        ) h;
        RETURN;
    END IF;

    -- Vector-only path
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
            0.2)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.2;
    END;

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', _query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', _query_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    candidates AS (
        SELECT
            al.id          AS cand_id,
            al.role        AS cand_role,
            al.project_id  AS cand_project_id,
            al.topic       AS cand_topic,
            al.lesson_text AS cand_lesson_text,
            al.importance  AS cand_importance,
            al.metadata    AS cand_metadata,
            al.commit_sha  AS cand_commit_sha,
            al.artifact_hash AS cand_artifact_hash,
            al.verified_at AS cand_verified_at,
            al.created_at  AS cand_created_at,
            al.confidence  AS cand_confidence,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score_raw,
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score_raw
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          AND (as_of_ts IS NULL
               OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts))
          AND (al.embedding IS NOT NULL OR _has_text)
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
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT reached_id AS gp_lesson_id,
               MAX(1.0 - depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk WHERE depth > 0 GROUP BY reached_id
    )
    SELECT
        c.cand_id               AS lesson_id,
        (
            0.5  * c.vec_score_raw
          + 0.15 * (c.cand_importance::DOUBLE PRECISION / 5.0)
          + 0.15 * c.cand_confidence::DOUBLE PRECISION
          + _gamma * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0))
          + 0.1 * (CASE
                WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
                WHEN c.cand_commit_sha IS NOT NULL THEN 0.5
                ELSE 0.0 END)
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )                       AS score,
        c.cand_role             AS role,
        c.cand_project_id       AS project_id,
        c.cand_topic            AS topic,
        c.cand_lesson_text      AS lesson_text,
        c.cand_importance       AS importance,
        c.cand_metadata         AS metadata,
        c.cand_commit_sha       AS commit_sha,
        c.cand_artifact_hash    AS artifact_hash,
        c.cand_verified_at      AS verified_at,
        c.cand_created_at       AS created_at,
        c.vec_score_raw         AS vec_score,
        NULL::DOUBLE PRECISION  AS bm25_score,
        NULL::DOUBLE PRECISION  AS rrf_score,
        c.cand_confidence::REAL AS confidence,
        LEAST(1.0, GREATEST(0.0,
            (
                0.5  * c.vec_score_raw
              + 0.15 * (c.cand_importance::DOUBLE PRECISION / 5.0)
              + 0.15 * c.cand_confidence::DOUBLE PRECISION
              + _gamma * GREATEST(0.0, 1.0 - LEAST(
                    EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0))
              + 0.1 * (CASE
                    WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
                    WHEN c.cand_commit_sha IS NOT NULL THEN 0.5 ELSE 0.0 END)
              + _graph_weight * COALESCE(gp.proximity, 0.0)
            ) / 1.5
        ))::REAL                AS match_confidence
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.gp_lesson_id = c.cand_id
    ORDER BY score DESC, c.cand_importance DESC, c.cand_created_at DESC
    LIMIT k;

    -- F2: ghost guidance — vector-only path: if 0 rows, warn about excluded ghost lessons
    IF NOT FOUND THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND al.verified_at IS NULL
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % matching lesson(s) are unverified (ingested without commit_sha/artifact_hash) '
                'and excluded by default. SET pgmnemo.include_unverified = ''on'' for this session, '
                'or pass provenance on ingest.',
                _ghost_count;
        END IF;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.8.2 — F2: NOTICE when 0 rows returned (vector-only path) and ghost lessons exist in scope. '
    'v0.7.0 -- confidence integration + footgun guard + match_confidence. '
    'Scoring (vector path): 0.5*vec + 0.15*imp/5 + 0.15*confidence + gamma*recency + 0.1*prov + delta*graph. '
    'confidence: outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, GREATEST(0.0, score/1.5)) -- interpretable [0,1] quality indicator. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL and text-only fallback active. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL). '
    'Named-column callers unaffected; positional callers: re-audit for 2 new trailing cols.';
