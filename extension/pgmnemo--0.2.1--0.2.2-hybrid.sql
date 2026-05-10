-- pgmnemo upgrade: 0.2.1 → 0.2.2-hybrid
-- Adds pgmnemo.recall_hybrid(): vector cosine + BM25 (ts_rank_cd) weighted fusion.
-- Existing recall_lessons() is UNCHANGED — full backward compatibility.
-- SPDX-License-Identifier: Apache-2.0
--
-- ⚠️  EXPERIMENTAL — pgmnemo.recall_hybrid() is an opt-in experimental function.
--     It is NOT the default retrieval path. recall_lessons() remains the stable API.
--     Benchmark evidence is simulation-based (TF-IDF proxy); real-DB confirmation
--     required before promotion to default. Use in production at your own risk.
--     Promotion criteria: see ROADMAP.md §H1 v0.2.2 "Promotion criteria".
--
-- Migration: v0.2.2_hybrid_001
-- Task: QUICK-B — Hypothesis B from 2026-05-09 strategy review
--
-- Design:
--   score = 0.4×vec_cosine + 0.4×ts_rank_cd(lesson_tsv, ..., 32)
--         + 0.05×(importance/5) + 0.05×recency_90d
--         + 0.05×prov_strength + 0.05×graph_proximity
--   Union retrieval: candidates matched by EITHER embedding cosine OR BM25.
--   rrf_score column (1/(60+vec_rank) + 1/(60+bm25_rank)) included for diagnostics.
--   Normalization option 32 on ts_rank_cd bounds BM25 score to [0,1].

-- ─────────────────────────────────────────────────────────────────────────────
-- recall_hybrid() — vector + BM25 weighted fusion (v0.2.2)
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
          -- Union: any candidate matched by vector OR BM25
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
          )
    ),
    -- Step 2: compute RRF ranks (for diagnostic rrf_score column)
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST) AS vec_rank,
            ROW_NUMBER() OVER (ORDER BY raw_bm25_score DESC NULLS LAST) AS bm25_rank
        FROM raw_candidates
    ),
    -- Step 3: compute weighted linear fusion score + diagnostic RRF score
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
            -- diagnostic RRF (not used for final ranking, returned for analysis)
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + r.bm25_rank::DOUBLE PRECISION))
                AS rrf_diag,
            -- primary fusion: weighted linear combination on normalized [0,1] scores
            (vec_weight  * r.raw_vec_score
           + bm25_weight * r.raw_bm25_score)
                AS fusion_score
        FROM rrf_ranked r
    ),
    -- Step 4: anchor top-5 by fusion_score for graph proximity walk
    anchors AS (
        SELECT id
        FROM scored
        ORDER BY fusion_score DESC
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
        -- Final score: weighted fusion + auxiliary components
        (
            s.fusion_score
          + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
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
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )                   AS score,
        s.v_score           AS vec_score,
        s.b_score           AS bm25_score,
        s.rrf_diag          AS rrf_score,
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
            s.fusion_score
          + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
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
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) DESC,
        s.importance DESC,
        s.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'EXPERIMENTAL — not the default retrieval path; recall_lessons() is the stable API. '
    'Hybrid recall v0.2.2 — weighted linear fusion of dense vector + BM25 sparse retrieval. '
    'Formula: score = vec_weight×cosine + bm25_weight×ts_rank_cd(lesson_tsv,q,32) '
    '               + 0.05×(importance/5) + 0.05×recency_90d '
    '               + 0.05×prov_strength + graph_proximity_weight×graph_proximity. '
    'Defaults: vec_weight=0.4, bm25_weight=0.4, rrf_k=60. '
    'Union retrieval: candidates from EITHER embedding cosine OR BM25 text match. '
    'rrf_score column = 1/(rrf_k+vec_rank) + 1/(rrf_k+bm25_rank) (diagnostic only). '
    'graph_proximity_weight = pgmnemo.graph_proximity_weight GUC (default 0.2, range 0.0–0.5). '
    'ef_search = pgmnemo.ef_search GUC (default 100). '
    'Backward-compatible: recall_lessons() unchanged.';
