-- pgmnemo--0.6.3--0.7.0.sql
-- Incremental upgrade: v0.6.3 → v0.7.0
-- Theme: Production maturity + outcome-learning loop
--
-- A: confidence + outcome tracking columns on agent_lesson
-- B: pgmnemo.reinforce() — asymmetric confidence update
-- C: recall_lessons() — confidence-weighted scoring + match_confidence column
-- D: Hybrid fallback warning (RAISE NOTICE / strict mode) in recall_lessons() vector-only path
-- E: match_confidence output column in recall_lessons() and recall_hybrid()
-- F: Ingestion guards (min-signal, repetition-collapse, embedding dedup) in pgmnemo.ingest()
-- G: stats() confidence distribution extension (DROP + recreate due to new columns)
-- H: control + metadata version bump (in separate files)
--
-- Backward compatibility notes:
--   - All ALTER TABLE use ADD COLUMN IF NOT EXISTS — idempotent
--   - All function changes use CREATE OR REPLACE — idempotent
--   - recall_lessons() RETURNS TABLE gains match_confidence REAL as last column.
--     Named-column callers unaffected. Positional callers must re-audit.
--   - recall_hybrid() RETURNS TABLE gains match_confidence REAL as last column.
--     Same positional-caller caveat.
--   - ingest() gains optional p_confidence REAL DEFAULT 0.5 parameter.
--     Existing call sites (no p_confidence) continue to work unchanged.
--   - stats() gains 3 new columns: avg_confidence, p50_confidence,
--     lessons_needing_reinforcement. DROP + recreate required (column count change).
--
-- GUCs added:
--   pgmnemo.strict_embedding_required (default 'off') — D: raise EXCEPTION on NULL embedding
--   pgmnemo.embedding_dedup_threshold  (default 0.99)  — F: near-duplicate embedding gate

-- ─────────────────────────────────────────────────────────────────────────────
-- A: confidence + outcome tracking columns on pgmnemo.agent_lesson
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS confidence      REAL          NOT NULL DEFAULT 0.5
        CONSTRAINT ck_agent_lesson_confidence CHECK (confidence BETWEEN 0.0 AND 1.0),
    ADD COLUMN IF NOT EXISTS success_count   INT           NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS fail_count      INT           NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_outcome    TEXT,
    ADD COLUMN IF NOT EXISTS last_outcome_at TIMESTAMPTZ;

COMMENT ON COLUMN pgmnemo.agent_lesson.confidence IS
    'Bayesian-style confidence score [0.0, 1.0]. Default 0.5. '
    'Updated by pgmnemo.reinforce(): success +0.10, failure -0.15, neutral no change. '
    'Used in recall scoring: 0.15×(importance/5) + 0.15×confidence (v0.7.0 blend).';

COMMENT ON COLUMN pgmnemo.agent_lesson.success_count IS
    'Cumulative count of reinforce(''success'') calls on this lesson.';

COMMENT ON COLUMN pgmnemo.agent_lesson.fail_count IS
    'Cumulative count of reinforce(''failure'') calls on this lesson.';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome IS
    'Most recent outcome string passed to reinforce() — ''success'', ''failure'', ''neutral'', or custom.';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome_at IS
    'Timestamp of the most recent reinforce() call.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B: pgmnemo.reinforce() — asymmetric confidence update
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
) RETURNS REAL
LANGUAGE plpgsql
AS $$
DECLARE
    _new_confidence REAL;
    _delta          REAL;
BEGIN
    -- Determine confidence delta based on outcome
    _delta := CASE lower(trim(p_outcome))
        WHEN 'success' THEN  0.10
        WHEN 'failure' THEN -0.15
        ELSE                  0.0   -- 'neutral' or any other string
    END;

    UPDATE pgmnemo.agent_lesson
    SET
        confidence      = CASE lower(trim(p_outcome))
                              WHEN 'success' THEN LEAST(1.0,    confidence + 0.10)
                              WHEN 'failure' THEN GREATEST(0.0, confidence - 0.15)
                              ELSE confidence
                          END,
        success_count   = CASE lower(trim(p_outcome))
                              WHEN 'success' THEN success_count + 1
                              ELSE success_count
                          END,
        fail_count      = CASE lower(trim(p_outcome))
                              WHEN 'failure' THEN fail_count + 1
                              ELSE fail_count
                          END,
        last_outcome    = p_outcome,
        last_outcome_at = NOW()
    WHERE id = p_lesson_id
    RETURNING confidence INTO _new_confidence;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    RETURN _new_confidence;
END;
$$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'Asymmetric confidence update (v0.7.0). '
    'success: confidence += 0.10, success_count++, clamped to 1.0. '
    'failure: confidence -= 0.15, fail_count++, clamped to 0.0. '
    'neutral (or any other string): no confidence change, just updates last_outcome/last_outcome_at. '
    'Returns new confidence value. Raises EXCEPTION if lesson_id not found.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C + D + E: recall_hybrid() — add match_confidence REAL output column
-- (C: confidence-weighted scoring; E: match_confidence column)
-- Note: recall_hybrid does not have a NULL-embedding path so D does not apply here.
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
    match_confidence REAL              -- E: lesson confidence score (v0.7.0)
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
            al.confidence,                                      -- C: carry confidence through
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
            r.confidence,                                       -- C: carry confidence
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            -- v0.6.2 Fix-A: sparse-safe RRF (Cormack 2009).
            -- Absent BM25 items receive sentinel rank = n_candidates+1 (excluded from BM25 list).
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
        -- v0.7.0 C: confidence added as aux tiebreaker (0.05 weight, same scale as importance/recency/prov).
        -- In hybrid path, rrf_sparse dominates; confidence nudges ties in favour of higher-confidence lessons.
        (
            s.rrf_sparse
          + _aux_scale * (
                0.05 * (s.importance::DOUBLE PRECISION / 5.0)
              + 0.05 * s.confidence::DOUBLE PRECISION                    -- C: confidence aux term
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
        s.created_at,
        s.confidence::REAL  AS match_confidence  -- E: lesson confidence score
    FROM scored s
    LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ORDER BY
        (
            s.rrf_sparse
          + _aux_scale * (
                0.05 * (s.importance::DOUBLE PRECISION / 5.0)
              + 0.05 * s.confidence::DOUBLE PRECISION
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
    'Hybrid recall v0.7.0 — adds match_confidence REAL output column (E). '
    'v0.7.0 C: confidence pulled into candidates/scored CTEs; match_confidence = lesson.confidence. '
    'v0.6.3: R1 AmbiguousColumn fix (#variable_conflict use_column). '
    'v0.6.2: F1 sparse-safe RRF (Cormack 2009) + F2 as_of_ts bitemporal filter. '
    'Primary rank signal: rrf_sparse = vec_w/(k+vec_rank) + bm25_w/(k+bm25_rank_sparse_or_sentinel). '
    'bm25_rank_sparse: only BM25-matching items (bm25_score > 0) get a rank; others get sentinel = n_candidates+1. '
    'Aux tie-breaker: _aux_scale*(0.05*importance + 0.05*confidence + 0.05*recency + 0.05*provenance) + graph_proximity. '
    'BREAKING (positional callers): match_confidence REAL added as last output column. '
    'Named-column callers: unaffected.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C + D + E: recall_lessons() — full CREATE OR REPLACE
-- C: 0.2×(importance/5) → 0.15×(importance/5) + 0.15×confidence in vector-only path
-- D: RAISE NOTICE (or EXCEPTION) when query_embedding IS NULL
-- E: match_confidence REAL added as last output column
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
    match_confidence REAL              -- E: lesson confidence score (v0.7.0)
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search              INT;
    _include_unverified     BOOLEAN;
    _tsquery                TSQUERY;
    _has_text               BOOLEAN;
    _gamma                  DOUBLE PRECISION;
    _temporal_boost         DOUBLE PRECISION;
    _graph_weight           DOUBLE PRECISION;
    _disable_hybrid         BOOLEAN;
    _max_depth              CONSTANT INT := 5;
    _max_chars              INT;
    _query_text             TEXT;
    _strict_embedding       BOOLEAN;
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

    -- D: read strict_embedding_required GUC
    BEGIN
        _strict_embedding := COALESCE(
            current_setting('pgmnemo.strict_embedding_required', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _strict_embedding := FALSE;
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
            h.rrf_score,
            h.match_confidence   -- E: forward match_confidence from hybrid path
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

    -- D: warn or raise if embedding is NULL and we are in vector-only path
    IF query_embedding IS NULL THEN
        IF _strict_embedding THEN
            RAISE EXCEPTION 'pgmnemo.recall_lessons: query_embedding IS NULL — recall falling back to text-only path; semantic similarity scores unavailable. Set pgmnemo.strict_embedding_required = ''on'' to raise an exception instead.';
        ELSE
            RAISE NOTICE 'pgmnemo.recall_lessons: query_embedding IS NULL — recall falling back to text-only path; semantic similarity scores unavailable. Set pgmnemo.strict_embedding_required = ''on'' to raise an exception instead.';
        END IF;
    END IF;

    -- Vector-only path (or text-only when query_embedding IS NULL)
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
            al.id             AS cand_id,
            al.role           AS cand_role,
            al.project_id     AS cand_project_id,
            al.topic          AS cand_topic,
            al.lesson_text    AS cand_lesson_text,
            al.importance     AS cand_importance,
            al.metadata       AS cand_metadata,
            al.commit_sha     AS cand_commit_sha,
            al.artifact_hash  AS cand_artifact_hash,
            al.verified_at    AS cand_verified_at,
            al.created_at     AS cand_created_at,
            al.confidence     AS cand_confidence,                -- C: carry confidence
            CASE
                WHEN query_embedding IS NOT NULL AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score_raw
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (query_embedding IS NULL OR al.embedding IS NOT NULL)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          -- v0.6.1 F2: point-in-time filter on vector-only path
          AND (as_of_ts IS NULL OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts))
        ORDER BY
            CASE WHEN query_embedding IS NOT NULL AND al.embedding IS NOT NULL
                 THEN al.embedding <=> query_embedding
                 ELSE 0.0 END ASC
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
        -- C: confidence-weighted blend.
        -- Old: 0.2×(importance/5). New: 0.15×(importance/5) + 0.15×confidence.
        -- Net importance-family weight preserved at 0.3 total.
        (
            0.5 * c.vec_score_raw
          + 0.15 * (c.cand_importance::DOUBLE PRECISION / 5.0)
          + 0.15 * c.cand_confidence::DOUBLE PRECISION
          + _gamma * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0
            ))
          + 0.1 * (CASE
                WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
                WHEN c.cand_commit_sha IS NOT NULL THEN 0.5
                ELSE 0.0 END)
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) AS score,
        c.cand_role           AS role,
        c.cand_project_id     AS project_id,
        c.cand_topic          AS topic,
        c.cand_lesson_text    AS lesson_text,
        c.cand_importance     AS importance,
        c.cand_metadata       AS metadata,
        c.cand_commit_sha     AS commit_sha,
        c.cand_artifact_hash  AS artifact_hash,
        c.cand_verified_at    AS verified_at,
        c.cand_created_at     AS created_at,
        c.vec_score_raw       AS vec_score,
        NULL::DOUBLE PRECISION AS bm25_score,
        NULL::DOUBLE PRECISION AS rrf_score,
        c.cand_confidence     AS match_confidence  -- E: lesson confidence score
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.gp_lesson_id = c.cand_id
    ORDER BY (
        0.5 * c.vec_score_raw
      + 0.15 * (c.cand_importance::DOUBLE PRECISION / 5.0)
      + 0.15 * c.cand_confidence::DOUBLE PRECISION
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
    'v0.7.0 — confidence-weighted scoring (C), NULL-embedding warning/exception (D), '
    'match_confidence REAL output column (E). '
    'C: vector-only path scoring changed: 0.2×(importance/5) → 0.15×(importance/5) + 0.15×confidence. '
    'D: when query_embedding IS NULL, emits RAISE NOTICE (or EXCEPTION if '
    '   pgmnemo.strict_embedding_required = ''on''). '
    'E: match_confidence column = lesson.confidence — lets callers filter independently of blended score. '
    'BREAKING (positional callers): match_confidence REAL added as last output column. '
    'Named-column callers: unaffected. '
    'v0.6.3: R1 AmbiguousColumn fix (#variable_conflict use_column). '
    'v0.6.2 hybrid router with as_of_ts point-in-time parameter (F2). '
    'as_of_ts DEFAULT NULL preserves v0.5.1/v0.6.0 behavior at existing call sites. '
    'R5: query_text truncated to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'H-06: recency decay = max(0, 1 - age_days/90); coeff=recency_weight×temporal_boost. '
    'Diagnostic cols: vec_score=cosine; bm25_score/rrf_score=NULL on vector-only path.';

-- ─────────────────────────────────────────────────────────────────────────────
-- F: Ingestion guards in pgmnemo.ingest()
-- Adding optional p_confidence REAL DEFAULT 0.5 parameter.
-- Three guards: min-signal, repetition-collapse, embedding dedup.
-- Signature change (new optional param) → CREATE OR REPLACE is sufficient
-- because the old 9-arg signature is replaced and callers without p_confidence still work.
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
    p_confidence    REAL         DEFAULT 0.5       -- F: confidence seed (v0.7.0)
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id              BIGINT;
    _max_chars          INT;
    _content_hash       TEXT;
    _prior_count        INT;
    _dedup_threshold    REAL;
BEGIN
    -- F guard 1: min-signal guard
    IF length(trim(COALESCE(p_lesson_text, ''))) < 20 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars) / topic too short (min 3 chars)';
    END IF;
    IF length(trim(COALESCE(p_topic, ''))) < 3 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars) / topic too short (min 3 chars)';
    END IF;

    -- F guard 2: repetition-collapse guard
    -- Checks for any substring of length ≥ 8 repeated ≥ 3 times consecutively.
    BEGIN
        IF regexp_count(p_lesson_text, '(.{8,})\1{2,}') > 0 THEN
            RAISE EXCEPTION 'pgmnemo.ingest: lesson_text appears to be repetition-collapsed (repeated pattern detected). Summarise the lesson instead.';
        END IF;
    EXCEPTION
        WHEN invalid_regular_expression THEN
            -- regex not supported on this PG version — skip guard (fail-open)
            NULL;
        WHEN undefined_function THEN
            -- regexp_count not available (PG < 15) — skip guard (fail-open)
            NULL;
    END;

    -- F confidence range check
    IF p_confidence < 0.0 OR p_confidence > 1.0 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: p_confidence must be between 0.0 and 1.0, got %', p_confidence;
    END IF;

    -- R5: clamp lesson_text
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) = 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text is NULL or empty — proceeding.';
    ELSIF _max_chars > 0 AND length(p_lesson_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text truncated to % chars '
                     '(pgmnemo.max_query_text_chars). Original length: %',
                     _max_chars, length(p_lesson_text);
        p_lesson_text := left(p_lesson_text, _max_chars);
    END IF;

    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- F guard 3: embedding dedup guard
    -- Gate behind pgmnemo.embedding_dedup_threshold GUC (default 0.99). If 0.0, skip.
    IF p_embedding IS NOT NULL THEN
        BEGIN
            _dedup_threshold := COALESCE(
                NULLIF(current_setting('pgmnemo.embedding_dedup_threshold', TRUE), '')::REAL,
                0.99
            );
        EXCEPTION WHEN OTHERS THEN
            _dedup_threshold := 0.99;
        END;

        IF _dedup_threshold > 0.0 THEN
            IF EXISTS (
                SELECT 1 FROM pgmnemo.agent_lesson
                WHERE is_active
                  AND embedding IS NOT NULL
                  AND 1 - (embedding <=> p_embedding) > _dedup_threshold
                LIMIT 1
            ) THEN
                RAISE EXCEPTION 'pgmnemo.ingest: near-duplicate embedding detected (cosine similarity > %). '
                                'Use reinforce() to update an existing lesson instead of inserting a duplicate.',
                                _dedup_threshold;
            END IF;
        END IF;
    END IF;

    -- Q5: compute content_hash to detect upcoming bitemporal close (dedup observability)
    -- Replicates GENERATED ALWAYS AS formula from agent_lesson.content_hash column.
    _content_hash := MD5(
        COALESCE(p_role, '')        || '|' ||
        COALESCE(p_topic, '')       || '|' ||
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
        p_confidence
    ) RETURNING id INTO new_id;

    -- Q5: RAISE NOTICE if bitemporal close+create fired (trigger trg_agent_lesson_bitemporal_close)
    IF _prior_count > 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: bitemporal close+create fired — closed % prior version(s) '
                     '(content_hash=%). New lesson_id=%. '
                     'Prior row(s) now have t_valid_to=NOW().',
                     _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB, REAL) IS
    'Validated public write API (v0.7.0). '
    'F: Three new pre-insert guards: '
    '  (1) min-signal: RAISE EXCEPTION if lesson_text < 20 chars or topic < 3 chars. '
    '  (2) repetition-collapse: RAISE EXCEPTION if lesson_text contains repeated patterns (≥8 chars, ≥3×). '
    '      Guard is fail-open on PG < 15 (no regexp_count). '
    '  (3) embedding dedup: RAISE EXCEPTION if near-duplicate embedding exists '
    '      (cosine > pgmnemo.embedding_dedup_threshold, default 0.99). Use reinforce() instead. '
    '      Gated: threshold = 0.0 skips dedup check entirely. '
    'F: p_confidence REAL DEFAULT 0.5 — seed confidence for new lesson. '
    'Q5 (v0.6.0): RAISE NOTICE when bitemporal close+create fires. '
    'R5 (v0.5.0): Truncates p_lesson_text to pgmnemo.max_query_text_chars with RAISE NOTICE.';

-- ─────────────────────────────────────────────────────────────────────────────
-- G: stats() — confidence distribution extension
-- Return type changes (14 → 17 cols) → must DROP before CREATE OR REPLACE.
-- Adds: avg_confidence REAL, p50_confidence REAL, lessons_needing_reinforcement INT
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                         TEXT,
    lesson_count                    BIGINT,
    embedded_count                  BIGINT,
    embedding_coverage_pct          DOUBLE PRECISION,
    tsv_coverage_pct                DOUBLE PRECISION,
    mem_edge_count                  BIGINT,
    recency_weight                  DOUBLE PRECISION,
    ef_search                       INT,
    importance_weight               DOUBLE PRECISION,
    hybrid_enabled                  BOOLEAN,
    recall_hybrid_available         BOOLEAN,
    oldest_lesson_age_days          INT,
    orphan_count                    BIGINT,
    ghost_count                     BIGINT,
    avg_confidence                  REAL,         -- G: v0.7.0 — mean confidence of active lessons
    p50_confidence                  REAL,         -- G: v0.7.0 — median confidence of active lessons
    lessons_needing_reinforcement   INT           -- G: v0.7.0 — active lessons with confidence < 0.3
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
        -- orphan_count: pgmnemo-schema functions not owned by the extension
        (SELECT COUNT(*)::BIGINT
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         LEFT JOIN pg_depend d
             ON d.objid = p.oid AND d.deptype = 'e'
            AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
         WHERE n.nspname = 'pgmnemo'
           AND p.proname NOT LIKE '\_%' ESCAPE '\'
           AND d.objid IS NULL)                                                    AS orphan_count,
        -- ghost_count (v0.6.0): active lessons without provenance (Agency RFC Q4)
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count,
        -- avg_confidence (v0.7.0 G): mean confidence of currently-active lessons
        (SELECT COALESCE(AVG(confidence), 0.5)::REAL
         FROM pgmnemo.agent_lesson
         WHERE is_active)                                                           AS avg_confidence,
        -- p50_confidence (v0.7.0 G): median confidence of currently-active lessons
        (SELECT COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY confidence), 0.5)::REAL
         FROM pgmnemo.agent_lesson
         WHERE is_active)                                                           AS p50_confidence,
        -- lessons_needing_reinforcement (v0.7.0 G): active lessons with confidence < 0.3
        (SELECT COUNT(*)::INT
         FROM pgmnemo.agent_lesson
         WHERE is_active
           AND confidence < 0.3)                                                   AS lessons_needing_reinforcement;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.7.0 diagnostic health-check. Adds confidence distribution stats (G): '
    'avg_confidence: mean confidence of active lessons (REAL, default population 0.5). '
    'p50_confidence: median confidence via PERCENTILE_CONT(0.5). '
    'lessons_needing_reinforcement: active lessons with confidence < 0.3 (candidates for reinforce()). '
    'v0.6.0: ghost_count (Agency RFC Q4) — active lessons without provenance. '
    'v0.4.1: diagnostic health-check (Agency RFC R3). '
    'Single-row summary; <50ms on N=10k corpus.';
