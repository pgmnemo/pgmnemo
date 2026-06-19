-- pgmnemo--0.9.4--0.9.5.sql
-- Upgrade: pgmnemo v0.9.4 → v0.9.5
-- RFC-PGM-CURATE-260619: recall-recency signals + mark_stale()
-- SPDX-License-Identifier: Apache-2.0
--
-- Changes:
--   A) Schema: last_recalled_at TIMESTAMPTZ, recall_count BIGINT on agent_lesson
--   B) Recall stamping: recall_hybrid(), recall_lessons(), navigate_locate(),
--      navigate_expand() stamp last_recalled_at / recall_count on returned lessons.
--      Controlled by GUC pgmnemo.track_recall_recency (default ON).
--      Functions changed from STABLE → VOLATILE to allow the UPDATE side-effect.
--   C) pgmnemo.mark_stale() — usage-based corpus curation with safeguards.

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.5'" to load this file. \quit

-- =============================================================================
-- A) Schema additions (idempotent via ADD COLUMN IF NOT EXISTS)
-- =============================================================================

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS last_recalled_at  TIMESTAMPTZ  DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS recall_count      BIGINT       NOT NULL DEFAULT 0;

-- Partial index for stale-lesson queries and corpus curation
CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_recall_recency
    ON pgmnemo.agent_lesson (last_recalled_at ASC NULLS FIRST, created_at ASC)
    WHERE is_active;

COMMENT ON COLUMN pgmnemo.agent_lesson.last_recalled_at IS
    'Timestamp of the most recent recall that included this lesson '
    '(recall_hybrid, recall_lessons, navigate_locate, navigate_expand). '
    'NULL = never recalled. Stamped unless GUC pgmnemo.track_recall_recency = off.';

COMMENT ON COLUMN pgmnemo.agent_lesson.recall_count IS
    'Cumulative count of recall events that returned this lesson. '
    'Incremented once per recall function call that includes this lesson. '
    'Stamped unless GUC pgmnemo.track_recall_recency = off.';

-- =============================================================================
-- B.1) recall_hybrid() v0.9.5 — VOLATILE, recency stamp via data-modifying CTE
-- Must DROP because STABLE → VOLATILE changes the function's volatility category.
-- =============================================================================

DROP FUNCTION IF EXISTS pgmnemo.recall_hybrid(
    vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT
);

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
VOLATILE
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
    _ghost_count        INT;
    _fetch_k_vec        INT;
    _fetch_k_bm25       INT;
    _conf_boost_w       DOUBLE PRECISION;
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
    EXCEPTION WHEN OTHERS THEN
        _ef_search := 100;
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

    -- I1: read confidence boost weight GUC (default 0.0 = OFF, clamped [0.0, 0.01])
    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
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

    -- #4 C2 fix: fetch_k floors — HNSW arm respects ef_search, BM25 arm floors at 40
    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    RETURN QUERY
    WITH RECURSIVE
    -- Phase 1: HNSW vector retrieval (index scan)
    vec_candidates AS (
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS raw_vec_score,
            0.0::DOUBLE PRECISION AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE _has_vec
          AND al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT _fetch_k_vec
    ),
    -- Phase 2: GIN BM25 retrieval (index scan)
    bm25_candidates AS (
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            ts_rank_cd(
                setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv,
                _tsquery, 32
            )::DOUBLE PRECISION AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE _has_text
          AND al.is_active
          AND (al.lesson_tsv @@ _tsquery
               OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY raw_bm25_score DESC
        LIMIT _fetch_k_bm25
    ),
    -- Merge: LEFT JOIN + anti-join UNION ALL (each id exactly once)
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(b.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM vec_candidates v
        LEFT JOIN bm25_candidates b ON b.id = v.id

        UNION ALL

        SELECT
            b.id, b.role, b.project_id, b.topic, b.lesson_text,
            b.importance, b.metadata, b.commit_sha, b.artifact_hash,
            b.verified_at, b.created_at, b.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            b.raw_bm25_score
        FROM bm25_candidates b
        WHERE b.id NOT IN (SELECT id FROM vec_candidates)
    ),
    -- RRF ranking over bounded candidate set
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC) AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                           AS bm25_rank_sparse
        FROM all_candidates
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
              -- I1: additive zero-centered confidence boost (w=0 when GUC off → no effect)
              + _conf_boost_w * (s.confidence::DOUBLE PRECISION - 0.5)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    -- v0.9.5: materialise top-k results before stamping
    final_results AS MATERIALIZED (
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
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    ),
    -- v0.9.5: stamp recency on returned lessons (runs always, gated by GUC)
    _stamp AS (
        UPDATE pgmnemo.agent_lesson
        SET last_recalled_at = NOW(),
            recall_count     = recall_count + 1
        WHERE id = ANY(ARRAY(SELECT lesson_id FROM final_results))
          AND COALESCE(
              NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
              TRUE)
        RETURNING id
    )
    SELECT
        fr.lesson_id,
        fr.score,
        fr.vec_score,
        fr.bm25_score,
        fr.rrf_score,
        fr.role,
        fr.project_id,
        fr.topic,
        fr.lesson_text,
        fr.importance,
        fr.metadata,
        fr.commit_sha,
        fr.artifact_hash,
        fr.verified_at,
        fr.created_at,
        fr.confidence,
        fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

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
    'v0.9.5 — Recall-recency stamping: stamps last_recalled_at + recall_count on returned lessons '
    'via data-modifying CTE (runs atomically with the SELECT, no double-scan). '
    'GUC pgmnemo.track_recall_recency (bool, default ON): set to off to disable stamping. '
    'Changed from STABLE → VOLATILE to permit the UPDATE side-effect. '
    'v0.9.2 — I1: confidence-weighted ranking (additive, zero-centered). '
    'GUC pgmnemo.confidence_boost_weight (default 0.0 = OFF, range [0.0, 0.01]). '
    'When ON: final_score += w * (confidence - 0.5). Recommended w=0.003. '
    'Cold-start (confidence=0.5) gets zero boost. High-vs-low delta at w=0.003 ≈ 0.0024 ≈ 8-15 RRF positions. '
    'graph_proximity contributes only when mem_edge is populated; with no edges the graph term is 0. '
    'v0.8.2 — F2: NOTICE when 0 rows returned and ghost lessons exist in scope. '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Two-phase indexed retrieval: HNSW (pgvector) + GIN (BM25) → RRF fusion → graph proximity boost. '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    '17 output columns. VOLATILE (side-effects: recency stamp).';

-- =============================================================================
-- B.2) recall_lessons() v0.9.5 — VOLATILE, delegates to recall_hybrid (already stamps)
--      On vector-only path: adds inline stamping.
-- Must DROP because STABLE → VOLATILE.
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

    -- Hybrid path delegates to recall_hybrid (which handles stamping)
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
    ),
    -- v0.9.5: materialise top-k before stamping
    result_rows AS MATERIALIZED (
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
        LIMIT k
    ),
    -- v0.9.5: stamp recency on returned lessons (runs always, gated by GUC)
    _stamp AS (
        UPDATE pgmnemo.agent_lesson
        SET last_recalled_at = NOW(),
            recall_count     = recall_count + 1
        WHERE id = ANY(ARRAY(SELECT rr.lesson_id FROM result_rows rr))
          AND COALESCE(
              NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
              TRUE)
        RETURNING id
    )
    SELECT
        rr.lesson_id, rr.score, rr.role, rr.project_id, rr.topic, rr.lesson_text,
        rr.importance, rr.metadata, rr.commit_sha, rr.artifact_hash,
        rr.verified_at, rr.created_at,
        rr.vec_score, rr.bm25_score, rr.rrf_score,
        rr.confidence, rr.match_confidence
    FROM result_rows rr
    ORDER BY rr.score DESC, rr.importance DESC, rr.created_at DESC;

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
    'v0.9.5 — Recall-recency stamping on vector-only path (hybrid path delegates to recall_hybrid). '
    'GUC pgmnemo.track_recall_recency (bool, default ON): set to off to disable stamping. '
    'Changed from STABLE → VOLATILE to permit the UPDATE side-effect. '
    'v0.8.2 — F2: NOTICE when 0 rows returned (vector-only path) and ghost lessons exist in scope. '
    'v0.7.0 -- confidence integration + footgun guard + match_confidence. '
    'Scoring (vector path): 0.5*vec + 0.15*imp/5 + 0.15*confidence + gamma*recency + 0.1*prov + delta*graph. '
    'confidence: outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, GREATEST(0.0, score/1.5)) -- interpretable [0,1] quality indicator. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL and text-only fallback active. '
    '17 output columns. VOLATILE (side-effects: recency stamp).';

-- =============================================================================
-- B.3) navigate_locate() v0.9.5 — VOLATILE, recency stamp via data-modifying CTE
-- Must DROP because STABLE → VOLATILE.
-- =============================================================================

DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(
    vector, TEXT, INT, JSONB, INT
);

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT              DEFAULT 2000,
    jsonb_filter      JSONB             DEFAULT NULL,
    project_id_filter INT               DEFAULT NULL
)
RETURNS TABLE (
    id              BIGINT,
    preview         TEXT,
    score           FLOAT8,
    tokens_consumed INT,
    navigation_path TEXT
)
LANGUAGE plpgsql
VOLATILE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 2;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _vec_weight         CONSTANT DOUBLE PRECISION := 0.4;
    _bm25_weight        CONSTANT DOUBLE PRECISION := 0.4;
    _raw_blend_weight   DOUBLE PRECISION;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.navigate_locate: both query_embedding and query_text are NULL/empty';
    END IF;

    _rrf_k_f := 60.0;
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

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
            al.topic_tsv,
            al.lesson_tsv,
            al.lesson_text,
            al.importance,
            al.commit_sha,
            al.verified_at,
            al.created_at,
            al.metadata,
            length(al.lesson_text)                                            AS text_len,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            CASE
                WHEN _has_text AND (al.topic_tsv @@ _tsquery OR al.lesson_tsv @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(al.topic_tsv, 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (navigate_locate.project_id_filter IS NULL
               OR al.project_id = navigate_locate.project_id_filter)
          AND (navigate_locate.jsonb_filter IS NULL
               OR al.metadata @> navigate_locate.jsonb_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
          AND (
                  (_has_vec  AND al.embedding IS NOT NULL)
               OR (_has_text AND (al.topic_tsv @@ _tsquery OR al.lesson_tsv @@ _tsquery))
          )
    ),
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC)  AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK()   OVER (PARTITION BY (raw_bm25_score > 0)
                                     ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                                  AS bm25_rank_sparse,
            COUNT(*) OVER ()                                                     AS n_candidates
        FROM raw_candidates
    ),
    scored AS (
        SELECT
            r.id, r.text_len, r.lesson_text, r.metadata, r.importance,
            r.commit_sha, r.verified_at, r.created_at,
            r.vec_rank, r.n_candidates,
            CASE WHEN r.bm25_rank_sparse IS NOT NULL THEN r.bm25_rank_sparse
                 ELSE r.n_candidates + 1
            END AS bm25_rank_eff,
            (
                _vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
              + _bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                     r.n_candidates + 1)::DOUBLE PRECISION)
              + _raw_blend_weight * (
                    _vec_weight  * r.raw_vec_score
                  + _bm25_weight * r.raw_bm25_score)
            ) AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT
            gw.anchor_id,
            gw.depth + 1,
            CASE WHEN me.source_id = gw.reached_id
                    THEN me.target_id
                    ELSE me.source_id
               END
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = gw.reached_id OR me.target_id = gw.reached_id
        )
        WHERE gw.depth < _max_depth
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
    ),
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    ),
    final_ranked AS (
        SELECT
            s.id,
            s.text_len,
            s.vec_rank,
            s.bm25_rank_eff,
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
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
        ORDER BY (
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
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
            DESC
        LIMIT 200
    ),
    budget_window AS (
        SELECT
            fr.id,
            fr.final_score,
            fr.text_len,
            fr.vec_rank,
            fr.bm25_rank_eff,
            SUM(fr.text_len) OVER (
                ORDER BY fr.final_score DESC, fr.id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cum_chars,
            ROW_NUMBER() OVER (ORDER BY fr.final_score DESC, fr.id ASC) AS rn
        FROM final_ranked fr
    ),
    -- v0.9.5: materialise budget result before stamping
    located_rows AS MATERIALIZED (
        SELECT
            bw.id,
            left(al.lesson_text, 50)  AS preview,
            bw.final_score::FLOAT8    AS score,
            bw.cum_chars::INT         AS tokens_consumed,
            CASE
                WHEN jsonb_filter IS NOT NULL THEN 'jsonb_gate'
                WHEN bw.vec_rank <= bw.bm25_rank_eff THEN 'vector'
                ELSE 'bm25'
            END                       AS navigation_path
        FROM budget_window bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE bw.rn = 1
           OR (bw.cum_chars - bw.text_len) < token_budget_chars
        ORDER BY bw.final_score DESC, bw.id ASC
    ),
    -- v0.9.5: stamp recency on located lessons
    _stamp AS (
        UPDATE pgmnemo.agent_lesson
        SET last_recalled_at = NOW(),
            recall_count     = recall_count + 1
        WHERE id = ANY(ARRAY(SELECT lr.id FROM located_rows lr))
          AND COALESCE(
              NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
              TRUE)
        RETURNING id
    )
    SELECT lr.id, lr.preview, lr.score, lr.tokens_consumed, lr.navigation_path
    FROM located_rows lr
    ORDER BY lr.score DESC, lr.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT) IS
    'v0.9.5 — Recall-recency stamping: stamps last_recalled_at + recall_count on returned lessons. '
    'GUC pgmnemo.track_recall_recency (bool, default ON). Changed STABLE → VOLATILE. '
    'v0.9.1 fixes: (1) graph_walk traverses ALL relation_types bidirectionally; '
    '(2) raw_candidates uses stored topic_tsv column (GIN-indexed). '
    'Returns id/preview/score/tokens_consumed/navigation_path. '
    'token_budget_chars: cumulative char limit; first row always returned. '
    'jsonb_filter: WHERE metadata @> jsonb_filter pushed into candidate scan. '
    'project_id_filter: scopes candidates to a single project. '
    'Combine with navigate_expand() to retrieve content for chosen IDs.';

-- =============================================================================
-- B.4) navigate_expand() v0.9.5 — VOLATILE, recency stamp via data-modifying CTE
-- Must DROP because STABLE → VOLATILE.
-- =============================================================================

DROP FUNCTION IF EXISTS pgmnemo.navigate_expand(
    BIGINT[], TEXT[], INT, FLOAT, TEXT[]
);

CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand(
    ids                    BIGINT[],
    expand_fields          TEXT[]           DEFAULT '{}',
    graph_expand_depth     INT              DEFAULT 1,
    graph_expand_threshold FLOAT            DEFAULT 0.5,
    relation_types         TEXT[]           DEFAULT NULL
)
RETURNS TABLE (
    id                      BIGINT,
    content                 TEXT,
    expand_detail           JSONB,
    graph_neighbor_ids      BIGINT[],
    graph_neighbor_previews TEXT[],
    tokens_consumed         INT,
    navigation_path         TEXT
)
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF ids IS NULL OR array_length(ids, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    -- Step 1: seed rows — the requested IDs
    seed_rows AS (
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, al.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE al.metadata ? f
                )
                ELSE NULL::JSONB
            END                                                            AS expand_detail,
            'content'::TEXT                                                AS navigation_path,
            0                                                              AS depth,
            ARRAY[al.id]                                                   AS path
        FROM pgmnemo.agent_lesson al
        WHERE al.id = ANY(ids)
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
    ),
    -- Step 2: BFS graph expansion — BIDIRECTIONAL, relation_type-gated, weight-gated
    graph_expand (node_id, lesson_text, metadata, depth, path) AS (
        SELECT sr.id, sr.lesson_text, sr.metadata, 0, sr.path
        FROM seed_rows sr

        UNION ALL

        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            ge.depth + 1,
            ge.path || al.id
        FROM graph_expand ge
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = ge.node_id OR me.target_id = ge.node_id
        )
        JOIN pgmnemo.agent_lesson al ON al.id = CASE
            WHEN me.source_id = ge.node_id THEN me.target_id
            ELSE me.source_id
        END
        WHERE ge.depth < graph_expand_depth
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND NOT (al.id = ANY(ge.path))
          AND (relation_types IS NULL OR me.relation_type = ANY(relation_types))
          AND me.weight >= graph_expand_threshold
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
    ),
    -- Step 3: expanded rows — neighbors not in seed set
    expanded_rows AS (
        SELECT DISTINCT ON (ge.node_id)
            ge.node_id AS id,
            ge.lesson_text,
            ge.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, ge.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE ge.metadata ? f
                )
                ELSE NULL::JSONB
            END AS expand_detail,
            'graph_expand'::TEXT AS navigation_path
        FROM graph_expand ge
        WHERE ge.depth > 0
          AND NOT (ge.node_id = ANY(ids))
        ORDER BY ge.node_id, ge.depth ASC
    ),
    -- Step 4a: distinct neighbors per seed
    distinct_neighbors AS (
        SELECT
            ge.path[1]   AS seed_id,
            ge.node_id,
            ge.depth,
            left(ge.lesson_text, 50)  AS neighbor_preview
        FROM graph_expand ge
        WHERE ge.depth > 0
          AND NOT (ge.node_id = ANY(ids))
        ORDER BY ge.path[1], ge.node_id, ge.depth ASC
    ),
    neighbor_summary AS (
        SELECT
            dn.seed_id,
            array_agg(dn.node_id ORDER BY dn.depth, dn.node_id)          AS neighbor_ids,
            array_agg(dn.neighbor_preview ORDER BY dn.depth, dn.node_id) AS neighbor_previews
        FROM distinct_neighbors dn
        GROUP BY dn.seed_id
    ),
    -- Step 5: union seed + expanded
    combined AS (
        SELECT sr.id,
               sr.lesson_text                                  AS content,
               sr.expand_detail,
               ns.neighbor_ids                                 AS graph_neighbor_ids,
               ns.neighbor_previews                            AS graph_neighbor_previews,
               sr.navigation_path
        FROM seed_rows sr
        LEFT JOIN neighbor_summary ns ON ns.seed_id = sr.id

        UNION ALL

        SELECT er.id,
               er.lesson_text                                  AS content,
               er.expand_detail,
               NULL::BIGINT[]                                  AS graph_neighbor_ids,
               NULL::TEXT[]                                    AS graph_neighbor_previews,
               er.navigation_path
        FROM expanded_rows er
    ),
    -- v0.9.5: materialise combined before stamping
    expand_results AS MATERIALIZED (
        SELECT
            c.id,
            c.content,
            c.expand_detail,
            c.graph_neighbor_ids,
            c.graph_neighbor_previews,
            SUM(length(c.content)) OVER (
                ORDER BY c.id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )::INT  AS tokens_consumed,
            c.navigation_path
        FROM combined c
        ORDER BY c.id ASC
    ),
    -- v0.9.5: stamp recency on all returned lesson IDs
    _stamp AS (
        UPDATE pgmnemo.agent_lesson
        SET last_recalled_at = NOW(),
            recall_count     = recall_count + 1
        WHERE id = ANY(ARRAY(SELECT er.id FROM expand_results er))
          AND COALESCE(
              NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
              TRUE)
        RETURNING id
    )
    SELECT
        er.id,
        er.content,
        er.expand_detail,
        er.graph_neighbor_ids,
        er.graph_neighbor_previews,
        er.tokens_consumed,
        er.navigation_path
    FROM expand_results er
    ORDER BY er.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_expand(BIGINT[], TEXT[], INT, FLOAT, TEXT[]) IS
    'v0.9.5 — Recall-recency stamping: stamps last_recalled_at + recall_count on all returned IDs '
    '(seeds + graph-expanded neighbors). GUC pgmnemo.track_recall_recency (bool, default ON). '
    'Changed STABLE → VOLATILE. '
    'v0.9.1 fixes: '
    '(B1) relation_type filter replaces broken edge_kind filter; '
    '(B2) valid_until handles both NULL and infinity sentinel conventions; '
    '(B3) bidirectional BFS; '
    '(B4) relation_types TEXT[] param — NULL traverses all. '
    'Threshold default 0.5 (was 0.7). Combine with navigate_locate() for locate→expand loop.';

-- =============================================================================
-- C) pgmnemo.mark_stale() — usage-based corpus curation
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.mark_stale(
    p_unused_days         INT     DEFAULT 45,
    p_min_confidence_keep REAL    DEFAULT 0.6,
    p_keep_provenance     BOOLEAN DEFAULT TRUE,
    p_dry_run             BOOLEAN DEFAULT TRUE,
    p_cap                 INT     DEFAULT 500
)
RETURNS TABLE(
    lesson_id        BIGINT,
    role             TEXT,
    topic            TEXT,
    last_recalled_at TIMESTAMPTZ,
    confidence       REAL,
    would_deprecate  BOOLEAN
)
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _candidate_count INT;
    _cutoff          TIMESTAMPTZ;
BEGIN
    _cutoff := NOW() - (p_unused_days * INTERVAL '1 day');

    -- Count candidates that would_deprecate (not in any safeguard)
    SELECT COUNT(*) INTO _candidate_count
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.state NOT IN ('deprecated', 'archived', 'rejected')
      AND (
          -- Never recalled within window
          (al.last_recalled_at IS NOT NULL AND al.last_recalled_at < _cutoff)
          OR
          -- Never recalled at all and old enough
          (al.last_recalled_at IS NULL AND al.created_at < _cutoff)
      )
      -- Not in any safeguard
      AND al.confidence < p_min_confidence_keep
      AND al.importance < 5
      AND NOT (p_keep_provenance
               AND (al.commit_sha IS NOT NULL OR al.artifact_hash IS NOT NULL));

    -- Cap guard: refuse to deprecate without explicit higher cap
    IF NOT p_dry_run AND _candidate_count > p_cap THEN
        RAISE NOTICE
            'pgmnemo.mark_stale: % candidates exceed cap %. No action taken. '
            'Re-run with p_cap=>% to proceed, or narrow criteria first.',
            _candidate_count, p_cap, _candidate_count;
        -- Still return candidate list for review
        RETURN QUERY
        SELECT
            al.id                  AS lesson_id,
            al.role,
            al.topic,
            al.last_recalled_at,
            al.confidence,
            -- would_deprecate: not in any safeguard
            (al.confidence < p_min_confidence_keep
             AND al.importance < 5
             AND NOT (p_keep_provenance
                      AND (al.commit_sha IS NOT NULL OR al.artifact_hash IS NOT NULL))
            ) AS would_deprecate
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.state NOT IN ('deprecated', 'archived', 'rejected')
          AND (
              (al.last_recalled_at IS NOT NULL AND al.last_recalled_at < _cutoff)
              OR
              (al.last_recalled_at IS NULL AND al.created_at < _cutoff)
          )
        ORDER BY al.last_recalled_at ASC NULLS FIRST, al.created_at ASC;
        RETURN;
    END IF;

    -- Dry-run or within cap: return candidates with would_deprecate flag
    RETURN QUERY
    SELECT
        al.id                  AS lesson_id,
        al.role,
        al.topic,
        al.last_recalled_at,
        al.confidence,
        (al.confidence < p_min_confidence_keep
         AND al.importance < 5
         AND NOT (p_keep_provenance
                  AND (al.commit_sha IS NOT NULL OR al.artifact_hash IS NOT NULL))
        ) AS would_deprecate
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.state NOT IN ('deprecated', 'archived', 'rejected')
      AND (
          (al.last_recalled_at IS NOT NULL AND al.last_recalled_at < _cutoff)
          OR
          (al.last_recalled_at IS NULL AND al.created_at < _cutoff)
      )
    ORDER BY al.last_recalled_at ASC NULLS FIRST, al.created_at ASC;

    -- Actual deprecation (only when NOT dry_run AND within cap)
    IF NOT p_dry_run THEN
        -- Direct UPDATE bypasses the state-machine guard intentionally:
        -- mark_stale() is an operator-level curation primitive; eligible lessons
        -- may be in any active state (draft, candidate, validated, canonical).
        -- Unlike transition_lesson(), we do NOT enforce a specific from-state.
        UPDATE pgmnemo.agent_lesson
        SET state            = 'deprecated',
            state_changed_at = NOW()
        WHERE is_active
          AND state NOT IN ('deprecated', 'archived', 'rejected')
          AND (
              (last_recalled_at IS NOT NULL AND last_recalled_at < _cutoff)
              OR
              (last_recalled_at IS NULL AND created_at < _cutoff)
          )
          AND confidence < p_min_confidence_keep
          AND importance < 5
          AND NOT (p_keep_provenance
                   AND (commit_sha IS NOT NULL OR artifact_hash IS NOT NULL));
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.mark_stale(INT, REAL, BOOLEAN, BOOLEAN, INT) IS
    'v0.9.5 — Usage-based corpus curation. Identifies and optionally deprecates '
    'lessons unused for p_unused_days (default 45). '
    'Candidates: active lessons where last_recalled_at < cutoff OR (NULL AND created_at < cutoff). '
    'Safeguards (never touched): '
    '  confidence >= p_min_confidence_keep (default 0.6), '
    '  importance = 5, '
    '  p_keep_provenance=TRUE AND (commit_sha IS NOT NULL OR artifact_hash IS NOT NULL). '
    'p_dry_run=TRUE (default): returns candidates without modifying. SAFE to run anytime. '
    'p_dry_run=FALSE: directly sets state=''deprecated'' on each eligible candidate (bypasses state-machine guard — intentional for operator curation). '
    'p_cap (default 500): if eligible candidates > cap, raises NOTICE and takes NO action — '
    'caller must explicitly set p_cap higher. '
    'Returns all candidates with would_deprecate flag (TRUE = not in any safeguard). '
    'ALWAYS review the dry_run output before running with p_dry_run=>FALSE.';
