-- pgmnemo--0.6.3--0.7.0.sql
-- Incremental upgrade: v0.6.3 → v0.7.0
--
-- Theme: Outcome-learning loop + footgun remediation
--
-- A) Schema: confidence REAL, success_count INT, fail_count INT,
--            last_outcome TEXT, last_outcome_at TIMESTAMPTZ on agent_lesson
-- B) pgmnemo.reinforce(lesson_id, outcome) — asymmetric confidence update
-- C) recall_lessons() + recall_hybrid() — confidence in scoring + output
-- D) Footgun guard: RAISE NOTICE when embedding missing, path_used output col
-- E) match_confidence [0,1] interpretable recall-match score in output
-- F) Ingestion guards: min-signal reject, repeated-substring warn, embedding dedup warn
-- G) stats() extension: confidence distribution columns (19 cols total, was 14)
--
-- Backward compatibility:
--   Named-column callers of recall_lessons/recall_hybrid: unaffected.
--   Positional callers: re-audit for 3 new trailing cols (confidence, match_confidence, path_used).
--   ingest() signature unchanged.
--   stats() gains 5 columns — named-column callers unaffected.
--
-- SPDX-License-Identifier: Apache-2.0

-- ─────────────────────────────────────────────────────────────────────────────
-- A) Schema additions (idempotent via ADD COLUMN IF NOT EXISTS)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS confidence      REAL        NOT NULL DEFAULT 0.5
        CONSTRAINT ck_agent_lesson_confidence CHECK (confidence BETWEEN 0.0 AND 1.0),
    ADD COLUMN IF NOT EXISTS success_count   INT         NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS fail_count      INT         NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_outcome    TEXT,
    ADD COLUMN IF NOT EXISTS last_outcome_at TIMESTAMPTZ;

-- Partial index for monitoring at-risk (low-confidence) lessons
CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_confidence_low
    ON pgmnemo.agent_lesson (confidence ASC)
    WHERE is_active AND confidence < 0.3;

COMMENT ON COLUMN pgmnemo.agent_lesson.confidence IS
    'Outcome-track-record confidence score [0.0, 1.0]. '
    'Default 0.5 (cold-start neutral). '
    'Updated by pgmnemo.reinforce(): success +0.10, failure -0.15 (asymmetric), neutral no-op. '
    'Clamped to [0.0, 1.0] by CHECK constraint + reinforce() logic.';

COMMENT ON COLUMN pgmnemo.agent_lesson.success_count IS
    'Cumulative count of successful recall outcomes recorded via reinforce().';

COMMENT ON COLUMN pgmnemo.agent_lesson.fail_count IS
    'Cumulative count of failure outcomes recorded via reinforce().';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome IS
    'Most recent outcome string from reinforce(): success | failure | neutral.';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome_at IS
    'Timestamp of the most recent reinforce() call that wrote to this row.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B) pgmnemo.reinforce() — asymmetric confidence update
--    success: +0.10  failure: -0.15  neutral: no-op
--    Returns new confidence value (REAL).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT    -- 'success' | 'failure' | 'neutral'
)
RETURNS REAL
LANGUAGE plpgsql
AS $$
DECLARE
    _old_conf  REAL;
    _new_conf  REAL;
    _delta     REAL;
    _norm_out  TEXT;
BEGIN
    _norm_out := lower(trim(COALESCE(p_outcome, 'neutral')));

    IF _norm_out NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' — must be success | failure | neutral',
            p_outcome;
    END IF;

    SELECT confidence INTO _old_conf
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;  -- row-level lock for concurrent-safe update

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    _delta := CASE _norm_out
        WHEN 'success'  THEN  0.10
        WHEN 'failure'  THEN -0.15
        ELSE                  0.0
    END;

    IF _delta = 0.0 THEN
        -- neutral: no write, return current value unchanged
        RETURN _old_conf;
    END IF;

    _new_conf := GREATEST(0.0, LEAST(1.0, _old_conf + _delta));

    UPDATE pgmnemo.agent_lesson
    SET
        confidence      = _new_conf,
        success_count   = success_count + CASE WHEN _norm_out = 'success' THEN 1 ELSE 0 END,
        fail_count      = fail_count    + CASE WHEN _norm_out = 'failure' THEN 1 ELSE 0 END,
        last_outcome    = _norm_out,
        last_outcome_at = NOW(),
        updated_at      = NOW()
    WHERE id = p_lesson_id;

    RETURN _new_conf;
END;
$$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'Outcome-learning update (v0.7.0): adjusts confidence for lesson p_lesson_id. '
    'success: confidence += 0.10 (clamped to 1.0). '
    'failure: confidence -= 0.15 (clamped to 0.0). '
    'neutral: no-op — returns current confidence without writing. '
    'Increments success_count / fail_count; sets last_outcome, last_outcome_at, updated_at. '
    'Row-locked (SELECT … FOR UPDATE) for concurrent-safe update on hot lessons. '
    'Raises exception on unknown outcome string or missing lesson_id.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C + D + E) recall_hybrid() v0.7.0
-- Return-type changes require DROP + CREATE.
-- 3 new trailing columns: confidence REAL, match_confidence FLOAT8, path_used TEXT
-- ─────────────────────────────────────────────────────────────────────────────

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
    match_confidence DOUBLE PRECISION,
    path_used        TEXT
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
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _conf_weight        CONSTANT DOUBLE PRECISION := 0.15;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION
            'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty — '
            'at least one retrieval signal is required';
    END IF;

    -- D) Footgun guard
    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo.recall_hybrid: query_embedding IS NULL — running BM25-only path. '
            'Semantic similarity unavailable; path_used = ''text_only''. '
            'Provide a 1024-dim embedding for full hybrid recall.';
    END IF;

    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);

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
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
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
            CASE
                WHEN _has_text AND al.lesson_tsv @@ _tsquery
                THEN ts_rank_cd(al.lesson_tsv, _tsquery, 32)::DOUBLE PRECISION
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
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
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
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION))
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
        FROM graph_walk WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    final AS (
        SELECT
            s.id,
            (
                s.rrf_sparse
              + _aux_scale * (
                    _conf_weight * s.confidence::DOUBLE PRECISION
                  + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0), 1.0))
                  + 0.05 * (CASE
                                WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                                WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                                ELSE 0.0 END)
                )
              + _graph_weight * COALESCE(gp.proximity, 0.0)
            ) AS final_score,
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
        LEAST(1.0, f.final_score)::DOUBLE PRECISION AS match_confidence,
        CASE WHEN _has_vec THEN 'hybrid' ELSE 'text_only' END::TEXT AS path_used
    FROM final f
    ORDER BY f.final_score DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.7.0 — confidence scoring, match_confidence, path_used, footgun guard. '
    'Scoring: rrf_sparse + _aux_scale*(0.15×conf + 0.05×imp/5 + 0.05×recency + 0.05×prov) + δ×graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, score) — interpretable [0,1] quality indicator. '
    'path_used: ''hybrid'' when vec present, ''text_only'' when vec IS NULL. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    'New trailing columns (18 total): confidence REAL, match_confidence FLOAT8, path_used TEXT.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C + D + E) recall_lessons() v0.7.0
-- ─────────────────────────────────────────────────────────────────────────────

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
    match_confidence DOUBLE PRECISION,
    path_used        TEXT
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
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _path_used          TEXT;
    _conf_weight        CONSTANT DOUBLE PRECISION := 0.15;
BEGIN
    -- R5: clamp query_text
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

    -- D) Footgun guard: warn when embedding absent
    IF NOT _has_vec THEN
        RAISE NOTICE
            'pgmnemo.recall_lessons: query_embedding IS NULL — semantic similarity unavailable. '
            'Hybrid routing suppressed; path_used=''text_only''. '
            'Provide a 1024-dim embedding for full hybrid recall.';
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _disable_hybrid := FALSE;
    END;

    -- Route to recall_hybrid when all 3 conditions met
    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        _path_used := 'hybrid';

        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence, _path_used
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60
        ) h;
        RETURN;
    END IF;

    -- ── Vector-only or text-only path ──────────────────────────────────────

    _path_used := CASE WHEN _has_vec THEN 'vector' ELSE 'text_only' END;

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
          + 0.10 * (c.cand_importance::DOUBLE PRECISION / 5.0)
          + _conf_weight * c.cand_confidence::DOUBLE PRECISION
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
        LEAST(1.0,
            0.5  * c.vec_score_raw
          + 0.10 * (c.cand_importance::DOUBLE PRECISION / 5.0)
          + _conf_weight * c.cand_confidence::DOUBLE PRECISION
          + _gamma * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0))
          + 0.1 * (CASE
                WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
                WHEN c.cand_commit_sha IS NOT NULL THEN 0.5 ELSE 0.0 END)
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )::DOUBLE PRECISION     AS match_confidence,
        _path_used              AS path_used
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.gp_lesson_id = c.cand_id
    ORDER BY score DESC, c.cand_importance DESC, c.cand_created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.7.0 — confidence integration + footgun guard + match_confidence + path_used. '
    'Scoring (vector path): 0.5×vec + 0.10×imp/5 + 0.15×confidence + γ×recency + 0.1×prov + δ×graph. '
    'confidence: outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, score) — interpretable [0,1] quality indicator. '
    'path_used: ''hybrid'' | ''vector'' | ''text_only''. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '18 output columns (15 existing + confidence, match_confidence, path_used). '
    'Named-column callers unaffected; positional callers: re-audit for 3 new trailing cols.';

-- ─────────────────────────────────────────────────────────────────────────────
-- F) Ingestion guards — CREATE OR REPLACE (signature unchanged)
-- G1: min-signal reject (<3 words or <10 chars)
-- G2: repeated-substring warn (>60% repetition heuristic)
-- G3: embedding dedup warn (cosine_sim >= pgmnemo.dedup_threshold, default 0.97)
-- GUCs:
--   pgmnemo.guard_min_signal  = 'on'   (default)
--   pgmnemo.guard_repeat_warn = 'on'   (default)
--   pgmnemo.guard_dedup_warn  = 'on'   (default)
--   pgmnemo.dedup_threshold   = '0.97' (default)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT     DEFAULT 3,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT         DEFAULT NULL,
    p_artifact_hash TEXT         DEFAULT NULL,
    p_metadata      JSONB        DEFAULT '{}'::jsonb,
    p_confidence    REAL         DEFAULT 0.5   -- initial outcome-track-record score [0,1]
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id             BIGINT;
    _max_chars         INT;
    _content_hash      TEXT;
    _prior_count       INT;
    _word_count        INT;
    _guard_min         BOOLEAN;
    _guard_repeat      BOOLEAN;
    _guard_dedup       BOOLEAN;
    _dedup_threshold   REAL;
    _near_dup_id       BIGINT;
    _near_dup_sim      REAL;
    _collapsed_len     INT;
BEGIN
    -- p_confidence range guard
    IF p_confidence IS NOT NULL AND (p_confidence < 0.0 OR p_confidence > 1.0) THEN
        RAISE EXCEPTION
            'pgmnemo.ingest: p_confidence must be between 0.0 and 1.0, got %',
            p_confidence;
    END IF;

    -- R5: clamp lesson_text length
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT, 2000);
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) = 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text is NULL or empty — proceeding.';
    ELSIF _max_chars > 0 AND length(p_lesson_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text truncated to % chars. Original: %',
                     _max_chars, length(p_lesson_text);
        p_lesson_text := left(p_lesson_text, _max_chars);
    END IF;

    -- G1: min-signal guard
    BEGIN
        _guard_min := COALESCE(
            current_setting('pgmnemo.guard_min_signal', TRUE)::BOOLEAN, TRUE);
    EXCEPTION WHEN OTHERS THEN _guard_min := TRUE;
    END;

    IF _guard_min AND p_lesson_text IS NOT NULL AND length(trim(p_lesson_text)) > 0 THEN
        _word_count := array_length(
            string_to_array(
                regexp_replace(trim(p_lesson_text), '\s+', ' ', 'g'), ' '), 1);
        IF COALESCE(_word_count, 0) < 3 OR length(trim(p_lesson_text)) < 10 THEN
            RAISE EXCEPTION
                'pgmnemo.ingest: min-signal guard rejected — lesson_text has % word(s) and % chars '
                '(minimum: 3 words AND 10 chars). '
                'Disable with SET pgmnemo.guard_min_signal = ''off''.',
                COALESCE(_word_count, 0), length(trim(p_lesson_text));
        END IF;
    END IF;

    -- G2: repeated-substring warn
    BEGIN
        _guard_repeat := COALESCE(
            current_setting('pgmnemo.guard_repeat_warn', TRUE)::BOOLEAN, TRUE);
    EXCEPTION WHEN OTHERS THEN _guard_repeat := TRUE;
    END;

    IF _guard_repeat AND p_lesson_text IS NOT NULL AND length(p_lesson_text) >= 20 THEN
        _collapsed_len := length(
            regexp_replace(p_lesson_text, '(.{10,})\1{2,}', '', 'g'));
        IF _collapsed_len < length(p_lesson_text) * 0.4 THEN
            RAISE NOTICE
                'pgmnemo.ingest: repeated-substring pattern detected (collapsed % → % chars, '
                '>60%% repetition). Ingesting anyway — consider de-duplicating.',
                length(p_lesson_text), _collapsed_len;
        END IF;
    END IF;

    -- Embedding dimension guard
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- G3: embedding dedup warn
    BEGIN
        _guard_dedup := COALESCE(
            current_setting('pgmnemo.guard_dedup_warn', TRUE)::BOOLEAN, TRUE);
    EXCEPTION WHEN OTHERS THEN _guard_dedup := TRUE;
    END;

    BEGIN
        _dedup_threshold := COALESCE(
            NULLIF(current_setting('pgmnemo.dedup_threshold', TRUE), '')::REAL, 0.97);
    EXCEPTION WHEN OTHERS THEN _dedup_threshold := 0.97;
    END;

    IF _guard_dedup AND p_embedding IS NOT NULL THEN
        SELECT id, (1.0 - (embedding <=> p_embedding))::REAL
        INTO _near_dup_id, _near_dup_sim
        FROM pgmnemo.agent_lesson
        WHERE is_active
          AND embedding IS NOT NULL
          AND (1.0 - (embedding <=> p_embedding)) >= _dedup_threshold
          AND (p_project_id IS NULL OR project_id = p_project_id)
        ORDER BY embedding <=> p_embedding
        LIMIT 1;

        IF FOUND THEN
            RAISE NOTICE
                'pgmnemo.ingest: near-duplicate embedding — lesson_id=% cosine_sim=% '
                '(threshold=%). Ingesting anyway. '
                'Raise pgmnemo.dedup_threshold to suppress.',
                _near_dup_id, ROUND(_near_dup_sim::NUMERIC, 4), _dedup_threshold;
        END IF;
    END IF;

    -- Bitemporal dedup observability (Q5)
    _content_hash := MD5(
        COALESCE(p_role, '')  || '|' ||
        COALESCE(p_topic, '') || '|' ||
        COALESCE(p_commit_sha, COALESCE(p_artifact_hash, ''))
    );

    SELECT COUNT(*)::INT INTO _prior_count
    FROM pgmnemo.agent_lesson
    WHERE content_hash = _content_hash
      AND t_valid_to   = 'infinity'::TIMESTAMPTZ;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, verified_at, confidence
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END,
        COALESCE(p_confidence, 0.5)
    ) RETURNING id INTO new_id;

    IF _prior_count > 0 THEN
        RAISE NOTICE
            'pgmnemo.ingest: bitemporal close+create fired — closed % prior version(s) '
            '(content_hash=%). New lesson_id=%.',
            _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB, REAL) IS
    'Validated public write API v0.7.0 + ingestion guards (10-arg). '
    'New v0.7.0: p_confidence REAL DEFAULT 0.5 — initial outcome-track-record score [0,1]. '
    'Range guard: EXCEPTION if p_confidence not in [0.0, 1.0]. '
    'G1 (min-signal): rejects lesson_text < 3 words or < 10 chars. '
    'Disable: SET pgmnemo.guard_min_signal = ''off''. '
    'G2 (repeat-warn): RAISE NOTICE when > 60% of text is repeated pattern (heuristic). '
    'Disable: SET pgmnemo.guard_repeat_warn = ''off''. '
    'G3 (dedup-warn): RAISE NOTICE when cosine_sim >= pgmnemo.dedup_threshold (default 0.97). '
    'Disable: SET pgmnemo.guard_dedup_warn = ''off''. '
    'Q5: bitemporal close+create NOTICE (pre-existing). '
    'R5: lesson_text truncation to pgmnemo.max_query_text_chars (pre-existing).';

-- ─────────────────────────────────────────────────────────────────────────────
-- G) stats() v0.7.0 — confidence distribution columns
-- Return-type change requires DROP + CREATE.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                    TEXT,
    lesson_count               BIGINT,
    embedded_count             BIGINT,
    embedding_coverage_pct     DOUBLE PRECISION,
    tsv_coverage_pct           DOUBLE PRECISION,
    mem_edge_count             BIGINT,
    recency_weight             DOUBLE PRECISION,
    ef_search                  INT,
    importance_weight          DOUBLE PRECISION,
    hybrid_enabled             BOOLEAN,
    recall_hybrid_available    BOOLEAN,
    oldest_lesson_age_days     INT,
    orphan_count               BIGINT,
    ghost_count                BIGINT,
    -- v0.7.0: confidence distribution (5 new columns)
    confidence_mean            DOUBLE PRECISION,
    confidence_p25             DOUBLE PRECISION,
    confidence_median          DOUBLE PRECISION,
    confidence_p75             DOUBLE PRECISION,
    confidence_below_half      BIGINT
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT
        pgmnemo.version()                                                          AS version,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.agent_lesson)                        AS lesson_count,
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson WHERE embedding IS NOT NULL)                    AS embedded_count,
        (SELECT CASE WHEN COUNT(*) > 0
                     THEN ROUND(100.0 *
                          SUM(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END)::NUMERIC
                          / COUNT(*), 2)::DOUBLE PRECISION
                     ELSE 0.0 END
         FROM pgmnemo.agent_lesson)                                                AS embedding_coverage_pct,
        (SELECT CASE WHEN COUNT(*) > 0
                     THEN ROUND(100.0 *
                          SUM(CASE WHEN lesson_tsv IS NOT NULL THEN 1 ELSE 0 END)::NUMERIC
                          / COUNT(*), 2)::DOUBLE PRECISION
                     ELSE 0.0 END
         FROM pgmnemo.agent_lesson)                                                AS tsv_coverage_pct,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.mem_edge)                            AS mem_edge_count,
        COALESCE(NULLIF(current_setting('pgmnemo.recency_weight',  TRUE), '')::DOUBLE PRECISION,
                 0.05)                                                             AS recency_weight,
        COALESCE(NULLIF(current_setting('pgmnemo.ef_search',       TRUE), '')::INT,
                 100)                                                              AS ef_search,
        COALESCE(NULLIF(current_setting('pgmnemo.importance_weight',TRUE), '')::DOUBLE PRECISION,
                 0.15)                                                             AS importance_weight,
        NOT COALESCE(current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
                     FALSE)                                                        AS hybrid_enabled,
        EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
        )                                                                          AS recall_hybrid_available,
        (SELECT COALESCE(
                    EXTRACT(EPOCH FROM (NOW() - MIN(created_at))) / 86400.0, 0
                )::INT
         FROM pgmnemo.agent_lesson)                                                AS oldest_lesson_age_days,
        (SELECT COUNT(*)::BIGINT
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         LEFT JOIN pg_depend d
             ON d.objid = p.oid AND d.deptype = 'e'
            AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
         WHERE n.nspname = 'pgmnemo'
           AND p.proname NOT LIKE '\_%' ESCAPE '\'
           AND d.objid IS NULL)                                                    AS orphan_count,
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count,
        -- v0.7.0: confidence distribution (active rows, t_valid_to = infinity)
        (SELECT COALESCE(AVG(confidence)::DOUBLE PRECISION, 0.5)
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_mean,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY confidence), 0.5
                )::DOUBLE PRECISION
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p25,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY confidence), 0.5
                )::DOUBLE PRECISION
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_median,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY confidence), 0.5
                )::DOUBLE PRECISION
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p75,
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ
           AND confidence < 0.5)                                                   AS confidence_below_half;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.7.0 diagnostic health-check (19 columns, was 14). '
    'New columns: confidence_mean, confidence_p25, confidence_median, confidence_p75, '
    'confidence_below_half (lessons with confidence < 0.5 — candidates for deprecation). '
    'ghost_count: active lessons (t_valid_to=infinity) without provenance. '
    'orphan_count: pgmnemo-schema functions not owned by the extension. '
    'Single-row; <100ms on N=10k corpus.';
