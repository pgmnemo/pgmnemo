-- pgmnemo v0.6.2 — incremental upgrade from v0.6.1
-- SPDX-License-Identifier: Apache-2.0
--
-- Changes:
--   F1: RRF Fix-A (sparse-safe) — Cormack et al. 2009 proper RRF semantics.
--       Root cause of v0.6.1 regression (-22.44pp): ROW_NUMBER() over all candidates
--       assigned arbitrary bm25_rank to zero-BM25 items. For small corpora (~48 segs/session),
--       high-cosine/no-BM25 answers ranked below BM25-matching non-answers.
--       Fix: CASE WHEN bm25_score > 0 THEN RANK() OVER (PARTITION BY ...) ELSE NULL END
--       → absent items get sentinel rank = n_candidates + 1 (excluded from BM25 list).
--       Only rrf_ranked and scored CTEs change; no new params; no CTE structural changes.
--
--   F2 (as_of_ts bitemporal recall) and F3 (stress test) already shipped in v0.6.1.

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.6.2'" to upgrade. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- F1: recall_hybrid() — sparse-safe proper RRF (v0.6.2 Fix-A)
--
-- Signature unchanged (8 params) — use CREATE OR REPLACE (no DROP needed).
-- Changes vs v0.6.1:
--   rrf_ranked CTE: +n_candidates (COUNT(*) OVER ()), bm25_rank_sparse (CASE WHEN > 0 THEN RANK() PARTITION)
--   scored CTE: rrf_sparse formula replaces rrf_diag as output; uses COALESCE(bm25_rank_sparse, n_candidates+1)
--   anchors CTE: ORDER BY rrf_sparse (was fusion_score)
--   Final SELECT: score = rrf_sparse + _aux_scale*aux; rrf_score = rrf_sparse (was rrf_diag)
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
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
    -- v0.6.1 F1: A-scale constant — keeps max(aux) ≈ 0.0026 < adjacent RRF delta
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
    'Hybrid recall v0.6.2 — F1 sparse-safe RRF (Cormack 2009) + F2 as_of_ts bitemporal filter. '
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
