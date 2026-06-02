-- pgmnemo--0.6.2--0.6.3.sql
-- Incremental upgrade: v0.6.2 → v0.6.3
--
-- R1 (P0 — production blocker): Fix AmbiguousColumn in recall_lessons() and recall_hybrid().
-- Error: psycopg2.errors.AmbiguousColumn: column reference "role" is ambiguous
-- Root cause: PL/pgSQL variable_conflict between RETURNS TABLE OUT variable "role TEXT" and
-- agent_lesson.role column. Table-qualification (al.role, r.role, s.role) is NOT sufficient to
-- suppress the PL/pgSQL-level ambiguity.
-- Fix: #variable_conflict use_column directive — tells PL/pgSQL to prefer columns over variables
-- when names clash. Zero signature change. Zero scoring change. Backward compatible.
--
-- No schema changes. No new tables. No index changes. Safe for hot-upgrade via ALTER EXTENSION.

-- ─────────────────────────────────────────────────────────────────────────────
-- R1 Fix: recall_hybrid() — add #variable_conflict use_column
-- ─────────────────────────────────────────────────────────────────────────────

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
    -- v0.6.2 F1: A-scale constant — keeps max(aux) ≈ 0.0026 << rrf_sparse range
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    -- v0.6.1 F2: point-in-time timestamp (from pgmnemo.as_of_timestamp GUC)
    _as_of_ts           TIMESTAMPTZ;
BEGIN
    -- Validate: at least one retrieval signal required
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty — at least one retrieval signal is required';
    END IF;

    -- Clamp weights
    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);

    -- ef_search GUC for HNSW recall quality
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

    -- v0.6.1 F2: read as_of_ts from GUC (set by recall_lessons() or caller via SET LOCAL)
    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN
        _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    -- Parse query_text → tsquery (websearch preferred, fallback to plainto)
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
    -- Step 1: union candidates from vector OR BM25 retrieval paths
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
            -- ts_rank_cd normalization=32: divides rank by rank+1 → bounded [0,1]
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
          -- v0.6.1 F2: point-in-time bitemporal filter
          AND (_as_of_ts IS NULL OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          -- Union: any candidate matched by vector OR BM25
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
          )
    ),
    -- Step 2: compute sparse-safe RRF ranks (v0.6.2 Fix-A — Cormack 2009)
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                                AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST)    AS vec_rank,
            -- Sparse-safe BM25 rank: only BM25-matching items get a real rank; absent items → NULL.
            -- Cormack et al. 2009: items not in a ranked list should not receive an RRF rank.
            -- PARTITION BY (raw_bm25_score > 0) separates BM25-matching (TRUE) from absent (FALSE).
            -- The FALSE partition is discarded via CASE WHEN; COALESCE below applies sentinel.
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                             AS bm25_rank_sparse
        FROM raw_candidates
    ),
    -- Step 3: compute sparse-safe RRF score (primary) + linear fusion (backward compat)
    scored AS (
        SELECT
            r.id,
            r.role,
            r.project_id,
            r.topic,
            r.lesson_text,
            r.importance,
            r.metadata,
            r.commit_sha,
            r.artifact_hash,
            r.verified_at,
            r.created_at,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            -- v0.6.2 Fix-A: sparse-safe RRF (Cormack 2009).
            -- Absent BM25 items receive sentinel rank = n_candidates+1 (excluded from BM25 list).
            -- Sentinel ensures no zero-BM25 item can rank above a BM25-matching item on BM25 axis.
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                  r.n_candidates + 1)::DOUBLE PRECISION))
                AS rrf_sparse,
            -- linear fusion: retained for backward compatibility (not used for ranking in v0.6.2)
            (vec_weight  * r.raw_vec_score
           + bm25_weight * r.raw_bm25_score)
                AS fusion_score
        FROM rrf_ranked r
    ),
    -- Step 4: anchor top-5 by rrf_sparse for graph proximity walk (v0.6.2 Fix-A)
    anchors AS (
        SELECT id
        FROM scored
        ORDER BY rrf_sparse DESC
        LIMIT 5
    ),
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id
        FROM anchors

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
        -- v0.6.2 Fix-A: score = rrf_sparse (primary) + _aux_scale × (importance + recency + provenance) + graph.
        -- rrf_sparse: sparse-safe RRF; aux terms capped at max ≈ 0.0026 << rrf_sparse range.
        (
            s.rrf_sparse
          + _aux_scale * (
                0.05 * (s.importance::DOUBLE PRECISION / 5.0)
              + 0.05 * GREATEST(0.0,
                           1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                               1.0
                           )
                       )::DOUBLE PRECISION
              + 0.05 * (CASE
                          WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                          WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                          ELSE                                                             0.0
                        END)::DOUBLE PRECISION
            )
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )                   AS score,
        s.v_score           AS vec_score,
        s.b_score           AS bm25_score,
        s.rrf_sparse        AS rrf_score,
        s.role,
        s.project_id,
        s.topic,
        s.lesson_text,
        s.importance,
        s.metadata,
        s.commit_sha,
        s.artifact_hash,
        s.verified_at,
        s.created_at
    FROM scored s
    LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ORDER BY
        (
            s.rrf_sparse
          + _aux_scale * (
                0.05 * (s.importance::DOUBLE PRECISION / 5.0)
              + 0.05 * GREATEST(0.0,
                           1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                               1.0
                           )
                       )::DOUBLE PRECISION
              + 0.05 * (CASE
                          WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                          WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                          ELSE                                                             0.0
                        END)::DOUBLE PRECISION
            )
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.6.3 — R1 AmbiguousColumn fix (#variable_conflict use_column). '
    'v0.6.2: F1 sparse-safe RRF (Cormack 2009) + F2 as_of_ts bitemporal filter. '
    'Primary rank signal: rrf_sparse = vec_w/(k+vec_rank) + bm25_w/(k+bm25_rank_sparse_or_sentinel). '
    'bm25_rank_sparse: only BM25-matching items (bm25_score > 0) get a rank; others get sentinel = n_candidates+1. '
    'Fixes v0.6.1 regression: ROW_NUMBER() over all candidates assigned arbitrary rank to zero-BM25 items '
    'causing high-cosine/no-BM25 answers to rank below BM25-matching non-answers in small corpora. '
    'Aux tie-breaker: _aux_scale*(0.05*importance + 0.05*recency + 0.05*provenance) + graph_proximity. '
    '_aux_scale=(0.8/61)/0.76=0.01726; max aux ≈ 0.0026 << rrf_sparse range (guaranteed tiebreaker only). '
    'F2: reads pgmnemo.as_of_timestamp GUC for point-in-time bitemporal filter on raw_candidates. '
    'Set GUC automatically by calling pgmnemo.recall_lessons(..., as_of_ts). '
    'fusion_score is still computed and returned as backward-compat reference (not used for ranking). '
    'rrf_score column = rrf_sparse (sparse-safe RRF, semantically correct value). '
    'Defaults: vec_weight=0.4, bm25_weight=0.4, rrf_k=60. '
    'graph_proximity_weight = pgmnemo.graph_proximity_weight GUC (default 0.2, range 0.0–0.5). '
    'ef_search = pgmnemo.ef_search GUC (default 100).';


-- ─────────────────────────────────────────────────────────────────────────────
-- R1 Fix: recall_lessons() — add #variable_conflict use_column
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT           DEFAULT 10,
    role_filter       TEXT          DEFAULT NULL,
    project_id_filter INT           DEFAULT NULL,
    query_text        TEXT          DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ   DEFAULT NULL  -- v0.6.1 F2: point-in-time recall
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
#variable_conflict use_column
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
    _max_chars          INT;
    _query_text         TEXT;
BEGIN
    -- R5: clamp query_text to pgmnemo.max_query_text_chars (default 2000).
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars '
                     '(pgmnemo.max_query_text_chars). Original length: %',
                     _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _disable_hybrid := FALSE;
    END;

    IF NOT _disable_hybrid
       AND _query_text IS NOT NULL
       AND length(trim(_query_text)) > 0
       AND query_embedding IS NOT NULL THEN

        -- v0.6.1 F2: propagate as_of_ts to recall_hybrid() via GUC (transaction-local)
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

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
            _query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,
            0.4,
            60
        ) h;
        RETURN;
    END IF;

    -- Vector-only path
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

    -- Base recency weight γ (backward compat default 0.05).
    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.05
    );

    -- H-06: recency decay coefficient = recency_weight × temporal_boost
    _temporal_boost := GREATEST(0.0, LEAST(20.0, COALESCE(
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

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', _query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', _query_text);
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
          -- v0.6.1 F2: point-in-time filter on vector-only path
          AND (as_of_ts IS NULL OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts))
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

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.6.3 — R1 AmbiguousColumn fix (#variable_conflict use_column). '
    'v0.6.2 hybrid router with as_of_ts point-in-time parameter (F2). '
    'as_of_ts DEFAULT NULL preserves v0.5.1/v0.6.0 behavior at existing call sites. '
    'When as_of_ts IS NOT NULL: propagates to recall_hybrid() via pgmnemo.as_of_timestamp GUC '
    '  (transaction-local SET, TRUE flag = local to transaction); '
    '  vector-only path applies filter directly in candidates CTE WHERE clause. '
    'R5: query_text truncated to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'H-06: recency decay = max(0, 1 - age_days/90); coeff=recency_weight×temporal_boost. '
    'Diagnostic cols: vec_score=cosine; bm25_score/rrf_score=NULL on vector-only path.';
