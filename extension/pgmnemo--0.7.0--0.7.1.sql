-- pgmnemo--0.7.0--0.7.1.sql
-- Incremental upgrade: pgmnemo 0.7.0 → 0.7.1
-- SPDX-License-Identifier: Apache-2.0
--
-- Changes:
--   BUG-1 (P0): recall_hybrid() match_confidence formula corrected.
--     Old: LEAST(1.0, GREATEST(0.0, final_score / 1.5))  -- wrong: RRF scale ≈ 0.008–0.05, not ~1.5
--     New: LEAST(1.0, GREATEST(0.0, v_score))            -- vec_score (cosine) is already [0,1]
--   MINOR-2: Add batch reinforce(BIGINT[], TEXT) overload — skips missing IDs, returns count.
--   MINOR-3: COMMENT on recall_hybrid updated: graph_proximity dormancy note + fix formula text.
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.7.1';
-- No schema changes (no new columns, no table DDL); function-only patch.

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.7.1'" to load this file. \quit

-- =============================================================================
-- BUG-1 + MINOR-3: recall_hybrid() — fix match_confidence, update COMMENT
-- DROP + CREATE required (return type has named columns; OR REPLACE alone is
-- safe here because the signature and return type are identical to 0.7.0,
-- but we follow the DROP pattern for consistency with prior upgrades).
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
        -- BUG-1 FIX (v0.7.1): use vec_score (cosine, [0,1]) not final_score/1.5.
        -- final_score is RRF-scale (~0.008-0.05); dividing by 1.5 produced ~0.005.
        -- vec_score is cosine similarity, already in [0,1] by pgvector guarantee.
        -- On text-only path (query_embedding IS NULL), vec_score = 0.0.
        LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence
    FROM final f
    ORDER BY f.final_score DESC
    LIMIT k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.7.1 -- match_confidence formula corrected (BUG-1), graph_proximity note added. '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Scoring: rrf_sparse + _aux_scale*(0.025*imp/5 + 0.025*conf + 0.05*recency + 0.05*prov) + delta*graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'graph_proximity contributes only when mem_edge is populated; with no edges the graph term is 0 (correct, not a bug). '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL).';

-- =============================================================================
-- MINOR-2: Batch reinforce(BIGINT[], TEXT) overload
-- Skips missing lesson_ids silently (no RAISE). Returns count of rows updated.
-- Unknown outcome string still raises (caller programming error, not data error).
-- Disambiguated from scalar reinforce(BIGINT, TEXT) by argument type.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_ids BIGINT[],
    p_outcome    TEXT
)
RETURNS INT
LANGUAGE plpgsql
AS $func$
DECLARE
    _id       BIGINT;
    _row      pgmnemo.agent_lesson%ROWTYPE;
    _new_conf REAL;
    _updated  INT := 0;
BEGIN
    -- Validate outcome up-front so the caller gets a clear error on bad input.
    IF p_outcome NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
            p_outcome;
    END IF;

    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    FOREACH _id IN ARRAY p_lesson_ids LOOP
        SELECT * INTO _row
        FROM pgmnemo.agent_lesson
        WHERE id = _id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- skip missing; no RAISE (bitemporal supersession / TTL normal)
        END IF;

        CASE p_outcome
            WHEN 'success' THEN
                _new_conf := LEAST(1.0, _row.confidence + 0.10);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    success_count   = _row.success_count + 1,
                    last_outcome    = 'success',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'failure' THEN
                _new_conf := GREATEST(0.0, _row.confidence - 0.15);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    fail_count      = _row.fail_count + 1,
                    last_outcome    = 'failure',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'neutral' THEN
                -- no-op; still counts as processed but does not increment _updated
                NULL;
        END CASE;
    END LOOP;

    RETURN _updated;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT[], TEXT) IS
    'Batch confidence update v0.7.1. Iterates p_lesson_ids; skips missing IDs silently (no RAISE). '
    'Returns count of rows actually updated (neutral outcome does not increment count). '
    'Unknown outcome string raises RAISE EXCEPTION (caller programming error). '
    'Empty or NULL array returns 0. '
    'success: +0.10, failure: -0.15, neutral: no-op. Clamped to [0.0, 1.0]. '
    'One round-trip vs N round-trips for per-id loop. '
    'Scalar form reinforce(BIGINT, TEXT) unchanged.';
