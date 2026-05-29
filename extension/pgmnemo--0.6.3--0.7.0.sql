-- pgmnemo--0.6.3--0.7.0.sql
-- Incremental upgrade: v0.6.3 → v0.7.0
--
-- Theme: Outcome-learning loop + footgun remediation
--
-- A) Schema: confidence REAL, success_count INT, fail_count INT,
--            last_outcome TEXT, last_outcome_at TIMESTAMPTZ on agent_lesson
-- B) pgmnemo.reinforce(lesson_id, outcome) — asymmetric confidence update
-- C) recall_lessons() + recall_hybrid() — confidence in scoring + output
-- D) Footgun guard: RAISE NOTICE when embedding missing (recall_lessons vector-only path)
-- E) match_confidence [0,1] interpretable recall-match score in output
-- F) Ingestion guards: min-length reject, token-repetition reject, embedding dedup warn+return
-- G) stats() extension: confidence distribution columns (19 cols total, was 14)
--
-- Backward compatibility:
--   Named-column callers of recall_lessons/recall_hybrid: unaffected.
--   Positional callers: re-audit for new trailing cols (confidence, match_confidence).
--   ingest() signature unchanged (9 params).
--   stats() gains 5 columns -- named-column callers unaffected.
--
-- SPDX-License-Identifier: Apache-2.0

-- =============================================================================
-- A) Schema additions (idempotent via ADD COLUMN IF NOT EXISTS)
-- =============================================================================

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
    'Most recent outcome string from reinforce(): success | failure (neutral is a no-op).';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome_at IS
    'Timestamp of the most recent reinforce() call that changed this row (success or failure only).';

-- =============================================================================
-- B) pgmnemo.reinforce() -- asymmetric confidence update
--    success: +0.10  failure: -0.15  neutral: no-op (no write)
--    Unknown outcome: RAISE EXCEPTION (exact case required)
--    Returns new confidence value (REAL).
--    Row-locked via SELECT ... FOR UPDATE for concurrent-safe update.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _row      pgmnemo.agent_lesson%ROWTYPE;
    _new_conf REAL;
BEGIN
    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    CASE p_outcome
        WHEN 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + 0.10);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                success_count   = _row.success_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            _new_conf := GREATEST(0.0, _row.confidence - 0.15);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                fail_count      = _row.fail_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            _new_conf := _row.confidence;

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    RETURN _new_conf;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'Outcome-learning update (v0.7.0): adjusts confidence for lesson p_lesson_id. '
    'Exact case required: ''success'' | ''failure'' | ''neutral''. '
    'success: confidence += 0.10 (clamped to 1.0); increments success_count; sets last_outcome/at. '
    'failure: confidence -= 0.15 (clamped to 0.0); increments fail_count; sets last_outcome/at. '
    'neutral: no-op -- returns current confidence without any write. '
    'Unknown outcome string: RAISE EXCEPTION. '
    'Row-locked (SELECT ... FOR UPDATE) for concurrent-safe update on hot lessons.';

-- =============================================================================
-- C + D + E) recall_hybrid() v0.7.0
-- Return-type changes (new trailing cols) require DROP + CREATE.
-- New output columns appended at end: confidence REAL, match_confidence REAL
-- Scoring change: aux term = 0.025*(imp/5) + 0.025*confidence + 0.05*recency + 0.05*prov
-- match_confidence = LEAST(1.0, GREATEST(0.0, score / 1.5))::REAL
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
                    0.025 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.025 * s.confidence::DOUBLE PRECISION
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
        LEAST(1.0, GREATEST(0.0, f.final_score / 1.5))::REAL AS match_confidence
    FROM final f
    ORDER BY f.final_score DESC
    LIMIT k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.7.0 -- confidence scoring + match_confidence output. '
    'Scoring: rrf_sparse + _aux_scale*(0.025*imp/5 + 0.025*conf + 0.05*recency + 0.05*prov) + delta*graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, GREATEST(0.0, score/1.5)) -- interpretable [0,1] quality indicator. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL).';

-- =============================================================================
-- C + D + E) recall_lessons() v0.7.0
-- Return-type changes (new trailing cols) require DROP + CREATE.
-- New output columns appended at end: confidence REAL, match_confidence REAL
-- Scoring change (vector-only): 0.2*(imp/5) => 0.15*(imp/5) + 0.15*confidence
-- D footgun: RAISE NOTICE when query_embedding IS NULL and _has_text
-- match_confidence = LEAST(1.0, GREATEST(0.0, score / 1.5))::REAL
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
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.7.0 -- confidence integration + footgun guard + match_confidence. '
    'Scoring (vector path): 0.5*vec + 0.15*imp/5 + 0.15*confidence + gamma*recency + 0.1*prov + delta*graph. '
    'confidence: outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, GREATEST(0.0, score/1.5)) -- interpretable [0,1] quality indicator. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL and text-only fallback active. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL). '
    'Named-column callers unaffected; positional callers: re-audit for 2 new trailing cols.';

-- =============================================================================
-- F) Ingestion guards -- CREATE OR REPLACE (signature unchanged, 9 params)
-- F1: lesson_text < 20 chars -> RAISE EXCEPTION
-- F2: most-frequent token > 80% of all tokens -> RAISE EXCEPTION (repetitive content)
-- F3: cosine similarity > 0.98 to existing active lesson (same project_id) ->
--     RAISE WARNING + RETURN existing lesson_id (no new insert)
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT     DEFAULT 3,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT         DEFAULT NULL,
    p_artifact_hash TEXT         DEFAULT NULL,
    p_metadata      JSONB        DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql AS $func$
DECLARE
    new_id             BIGINT;
    _content_hash      TEXT;
    _prior_count       INT;
    _dedup_id          BIGINT;
    _dedup_sim         DOUBLE PRECISION;
    _tokens            TEXT[];
    _token             TEXT;
    _token_counts      JSONB;
    _max_freq          INT;
    _total_tokens      INT;
    _trimmed_text      TEXT;
BEGIN
    -- F1: minimum length guard (fires BEFORE provenance gate trigger)
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) < 20 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars)';
    END IF;

    -- F2: token-frequency repetition guard
    _trimmed_text := trim(p_lesson_text);
    _tokens := regexp_split_to_array(
        regexp_replace(_trimmed_text, '\s+', ' ', 'g'), ' ');
    _total_tokens := array_length(_tokens, 1);

    IF _total_tokens > 0 THEN
        _token_counts := '{}'::JSONB;
        FOREACH _token IN ARRAY _tokens LOOP
            _token_counts := jsonb_set(
                _token_counts,
                ARRAY[_token],
                to_jsonb(COALESCE((_token_counts->>_token)::INT, 0) + 1)
            );
        END LOOP;

        SELECT MAX(value::INT)
        INTO _max_freq
        FROM jsonb_each_text(_token_counts);

        IF _max_freq::DOUBLE PRECISION / _total_tokens::DOUBLE PRECISION > 0.8 THEN
            RAISE EXCEPTION 'pgmnemo.ingest: lesson_text appears to be repetitive content';
        END IF;
    END IF;

    -- Embedding dimension guard
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch -- expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- F3: near-duplicate embedding guard (cosine > 0.98, same project_id)
    IF p_embedding IS NOT NULL THEN
        SELECT id, (1.0 - (embedding <=> p_embedding))
        INTO _dedup_id, _dedup_sim
        FROM pgmnemo.agent_lesson
        WHERE is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
          AND embedding IS NOT NULL
          AND project_id = p_project_id
          AND (1.0 - (embedding <=> p_embedding)) > 0.98
        ORDER BY embedding <=> p_embedding
        LIMIT 1;

        IF FOUND THEN
            RAISE WARNING
                'pgmnemo.ingest: near-duplicate detected -- cosine similarity % > 0.98 '
                'to existing lesson_id=% (project_id=%). Returning existing lesson_id.',
                ROUND(_dedup_sim::NUMERIC, 4), _dedup_id, p_project_id;
            RETURN _dedup_id;
        END IF;
    END IF;

    -- Bitemporal dedup observability
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
        commit_sha, artifact_hash, metadata, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
    ) RETURNING id INTO new_id;

    IF _prior_count > 0 THEN
        RAISE NOTICE
            'pgmnemo.ingest: bitemporal close+create fired -- closed % prior version(s) '
            '(content_hash=%). New lesson_id=%.',
            _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API v0.7.0 with ingestion guards. '
    'F1 (min-length): RAISE EXCEPTION when lesson_text < 20 chars (fires before provenance trigger). '
    'F2 (repetition): RAISE EXCEPTION when most-frequent token > 80% of all tokens. '
    'F3 (dedup-warn): RAISE WARNING + RETURN existing lesson_id when cosine_sim > 0.98 '
    'to active lesson with same project_id (no new insert). '
    'Signature unchanged (9 params). '
    'Provenance gate trigger fires on INSERT (after F1/F2 guards pass, F3 short-circuits before INSERT).';

-- =============================================================================
-- G) stats() v0.7.0 -- confidence distribution columns
-- Return-type change requires DROP + CREATE.
-- 5 new columns: confidence_mean, confidence_p10, confidence_p50, confidence_p90,
--                confidence_below_threshold_count (confidence < 0.3)
-- =============================================================================

DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                          TEXT,
    lesson_count                     BIGINT,
    embedded_count                   BIGINT,
    embedding_coverage_pct           DOUBLE PRECISION,
    tsv_coverage_pct                 DOUBLE PRECISION,
    mem_edge_count                   BIGINT,
    recency_weight                   DOUBLE PRECISION,
    ef_search                        INT,
    importance_weight                DOUBLE PRECISION,
    hybrid_enabled                   BOOLEAN,
    recall_hybrid_available          BOOLEAN,
    oldest_lesson_age_days           INT,
    orphan_count                     BIGINT,
    ghost_count                      BIGINT,
    confidence_mean                  REAL,
    confidence_p10                   REAL,
    confidence_p50                   REAL,
    confidence_p90                   REAL,
    confidence_below_threshold_count INT
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $func$
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
        (SELECT COALESCE(AVG(confidence), 0.5)::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_mean,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p10,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p50,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p90,
        (SELECT COUNT(*)::INT
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ
           AND confidence < 0.3)                                                   AS confidence_below_threshold_count;
$func$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.7.0 diagnostic health-check (19 columns, was 14). '
    'New columns: confidence_mean REAL, confidence_p10 REAL, confidence_p50 REAL, '
    'confidence_p90 REAL, confidence_below_threshold_count INT (lessons with confidence < 0.3). '
    'ghost_count: active lessons (t_valid_to=infinity) without provenance. '
    'orphan_count: pgmnemo-schema functions not owned by the extension. '
    'Single-row; <100ms on N=10k corpus.';
