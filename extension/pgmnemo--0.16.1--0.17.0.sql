-- pgmnemo 0.16.1 -> 0.17.0
-- Evidence and honest defaults release.
--
-- R2 (corrected): Reconcile graph_proximity_weight split-default bug.
--
-- Background: The OPT-IN decision (0.2 -> 0.0) was made in v0.10.1 based on the
-- graph-walk ablation (benchmarks/results/REPORT_graph_walk_ablation_20260622.md):
-- overlap@K=1.000 across 43 live queries, zero ranking change, +3-5ms P50 overhead.
-- It was partially applied. In the shipped 0.16.1 flat install, 4 active function
-- overloads still used 0.2 as their COALESCE fallback:
--   (a) navigate_locate(5p)  — COALESCE=0.2, exception already 0.0 (split)
--   (b) recall_hybrid(10p)   — COALESCE=0.2, exception=0.2 (both wrong)
--   (c) recall_hybrid(11p)   — COALESCE=0.2, exception=0.2 (both wrong)
--
-- recall_lessons(5p) is also recreated here (defensively) even though its last
-- definition in 0.16.1 (line 10957) already had COALESCE=0.0. The recreation is
-- harmless and ensures a single canonical body applies under all upgrade paths.
--
-- This upgrade recreates all four overloads with COALESCE=0.0 and exception=0.0.
-- All code paths now agree at 0.0 when the GUC is unset.
--
-- BEHAVIOUR BREAK for all four overloads — graph weighting defaulted to 0.2 in
-- normal (non-exception) code path for (a)-(d) above. After v0.17.0: 0.0.
-- Restore: SET pgmnemo.graph_proximity_weight = '0.2';
--
-- No schema changes. No new functions. No GUC additions.
-- Upgrade path: ALTER EXTENSION pgmnemo UPDATE TO '0.17.0';
-- Fresh install: pgmnemo--0.17.0.sql
-- SPDX-License-Identifier: Apache-2.0


-- ============================================================
-- Recreate function (line 1802 in 0.16.1 flat install)
-- ============================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    query_text        TEXT    DEFAULT NULL
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
    -- v0.4.1 diagnostic columns (R4):
    vec_score     DOUBLE PRECISION,
    bm25_score    DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
BEGIN
    -- Routing decision (v0.4.0): query_text + embedding + not disabled → hybrid
    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _disable_hybrid := FALSE;
    END;

    IF NOT _disable_hybrid
       AND query_text IS NOT NULL
       AND length(trim(query_text)) > 0
       AND query_embedding IS NOT NULL THEN
        -- Hybrid path: project 15 cols from recall_hybrid's 15-col output
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
            query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,    -- vec_weight
            0.4,    -- bm25_weight
            60      -- rrf_k
        ) h;
        RETURN;
    END IF;

    -- Vector-only path: unchanged formula, but populate diagnostic cols with
    -- vec_score = raw cosine (from formula), bm25_score = NULL, rrf_score = NULL.
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

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.05  -- v0.4.1: default lowered from 0.08 per an internal ablation (R1)
    );

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
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

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'v0.4.1 hybrid router with diagnostic columns. Routes to recall_hybrid() '
    'when query_text non-empty AND embedding present AND pgmnemo.disable_hybrid '
    'is FALSE/unset. Vector-only path uses §6.4 scoring with γ = '
    'pgmnemo.recency_weight (default 0.05 since v0.4.1 per an internal ablation). '
    'Diagnostic columns (v0.4.1, R4): vec_score = raw cosine; bm25_score / '
    'rrf_score = NULL on vector-only path, populated on hybrid path. '
    'Opt-out: SET pgmnemo.disable_hybrid = ''true''.';


-- ============================================================
-- Recreate function (line 8507 in 0.16.1 flat install)
-- ============================================================

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
            0.0
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', left(trim(query_text), 200));   -- Fix 4+1
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
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0  -- Fix 5
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
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0))::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE 0.0 END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.lesson_text,
            s.metadata
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    budget_consumed AS (
        SELECT
            fr.id,
            fr.final_score,
            fr.lesson_text,
            fr.metadata,
            fr.text_len,
            SUM(fr.text_len) OVER (ORDER BY fr.final_score DESC, fr.id ASC) AS cumulative_chars
        FROM final_ranked fr
    )
    SELECT
        bc.id,
        left(bc.lesson_text, 120)::TEXT  AS preview,
        bc.final_score                   AS score,
        bc.text_len::INT                 AS tokens_consumed,
        NULL::TEXT                       AS navigation_path
    FROM budget_consumed bc
    WHERE bc.cumulative_chars <= navigate_locate.token_budget_chars
    ORDER BY bc.final_score DESC, bc.id ASC;
END;
$$;


-- ============================================================
-- Recreate function (line 8900 in 0.16.1 flat install)
-- ============================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL,
    p_content_types   text[]           DEFAULT NULL   -- P0.2: typed recall; NULL=all types
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
    -- 0.10.1 additions (#87)
    _lexical_text       TEXT;
    _bm25_budget_ms     INT;
    _bm25_timed_out     BOOLEAN := FALSE;
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
            0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default, reconciled in v0.17.0
    END;

    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
    END;

    BEGIN
        _bm25_budget_ms := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.bm25_budget_ms', TRUE), '')::INT, 250));
    EXCEPTION WHEN OTHERS THEN _bm25_budget_ms := 250;
    END;

    IF _has_text THEN
        _lexical_text := left(trim(query_text), 200);
        BEGIN
            _tsquery := websearch_to_tsquery('simple', _lexical_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', _lexical_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    BEGIN
        CREATE TEMP TABLE _pgmnemo_bm25_work (
            id             BIGINT         PRIMARY KEY,
            raw_bm25_score DOUBLE PRECISION NOT NULL DEFAULT 0.0
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_bm25_work;
    END;

    IF _has_text THEN
        BEGIN
            EXECUTE format('SET LOCAL statement_timeout = %s', _bm25_budget_ms);

            INSERT INTO _pgmnemo_bm25_work (id, raw_bm25_score)
            SELECT
                al.id,
                ts_rank_cd(al.full_text, _tsquery, 32)::DOUBLE PRECISION
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.full_text @@ _tsquery
              AND (_include_unverified OR al.verified_at IS NOT NULL)
              AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
              AND (recall_hybrid.project_id_filter IS NULL
                   OR al.project_id = recall_hybrid.project_id_filter)
              AND (recall_hybrid.exclude_dag_id IS NULL
                   OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
              -- P0.2: typed recall pushdown into BM25 subplan (ix_pgmnemo_content_type_active)
              AND (recall_hybrid.p_content_types IS NULL
                   OR al.content_type = ANY(recall_hybrid.p_content_types))
              AND (_as_of_ts IS NULL
                   OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
              AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY 2 DESC
            LIMIT _fetch_k_bm25;

            EXECUTE 'SET LOCAL statement_timeout = 0';

        EXCEPTION WHEN query_canceled THEN
            _bm25_timed_out := TRUE;
            _has_text       := FALSE;
            RAISE NOTICE
                'pgmnemo.recall_hybrid: BM25 signal exceeded %ms budget — degrading to '
                'vector-only recall. Tune pgmnemo.bm25_budget_ms or shorten query_text.',
                _bm25_budget_ms;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    vec_candidates AS (
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS raw_vec_score
        FROM pgmnemo.agent_lesson al
        WHERE _has_vec
          AND al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (recall_hybrid.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
          -- P0.2: typed recall pushdown into vector subplan (ix_pgmnemo_content_type_active)
          AND (recall_hybrid.p_content_types IS NULL
               OR al.content_type = ANY(recall_hybrid.p_content_types))
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT _fetch_k_vec
    ),
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM vec_candidates v
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        SELECT
            al.id, al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            bw.raw_bm25_score
        FROM _pgmnemo_bm25_work bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE bw.id NOT IN (SELECT id FROM vec_candidates)
    ),
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
        fr.lesson_id, fr.score, fr.vec_score, fr.bm25_score, fr.rrf_score,
        fr.role, fr.project_id, fr.topic, fr.lesson_text, fr.importance,
        fr.metadata, fr.commit_sha, fr.artifact_hash, fr.verified_at, fr.created_at,
        fr.confidence, fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[]) IS
    'v0.11.0 — RFC-001 §D2 / P0.2: typed recall. '
    'New param p_content_types text[] DEFAULT NULL (LAST, backward-compatible). '
    'NULL → unchanged behavior (all content types). '
    'non-NULL → pushes content_type = ANY(p_content_types) into BOTH subplans (vec + BM25) '
    'BEFORE RRF fusion — uses ix_pgmnemo_content_type_active (pushdown, not post-filter). '
    'Empty array ''{}'': zero rows returned (no silent fallback to all-types). '
    'Inherits all v0.10.1 (#87) fixes: query_text cap, indexed full_text BM25, '
    'bm25_budget_ms timeout, simple tsconfig. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'graph_proximity via mem_edge causal/temporal walk (depth ≤5). '
    'VOLATILE (side-effects: recency stamp, temp table _pgmnemo_bm25_work).';

-- ═══════════════════════════════════════════════════════════════════════════
-- pgmnemo 0.11.0 → 0.11.1 delta applied inline (typed recall hot-path)
-- ═══════════════════════════════════════════════════════════════════════════

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


-- ============================================================
-- Recreate function (line 10387 in 0.16.1 flat install)
-- ============================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL,
    p_content_types   text[]           DEFAULT NULL,
    p_min_score       REAL             DEFAULT NULL
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
    -- 0.10.1 additions (#87)
    _lexical_text       TEXT;
    _bm25_budget_ms     INT;
    _bm25_timed_out     BOOLEAN := FALSE;
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
            0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default, reconciled in v0.17.0
    END;

    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
    END;

    BEGIN
        _bm25_budget_ms := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.bm25_budget_ms', TRUE), '')::INT, 250));
    EXCEPTION WHEN OTHERS THEN _bm25_budget_ms := 250;
    END;

    IF _has_text THEN
        _lexical_text := left(trim(query_text), 200);
        BEGIN
            _tsquery := websearch_to_tsquery('simple', _lexical_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', _lexical_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    -- ── BM25 candidates (unchanged from v0.14.0) ──────────────────────────────
    BEGIN
        CREATE TEMP TABLE _pgmnemo_bm25_work (
            id             BIGINT          PRIMARY KEY,
            raw_bm25_score DOUBLE PRECISION NOT NULL DEFAULT 0.0
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_bm25_work;
    END;

    IF _has_text THEN
        BEGIN
            EXECUTE format('SET LOCAL statement_timeout = %s', _bm25_budget_ms);

            INSERT INTO _pgmnemo_bm25_work (id, raw_bm25_score)
            SELECT
                al.id,
                ts_rank_cd(al.full_text, _tsquery, 32)::DOUBLE PRECISION
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.full_text @@ _tsquery
              AND (_include_unverified OR al.verified_at IS NOT NULL)
              AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
              AND (recall_hybrid.project_id_filter IS NULL
                   OR al.project_id = recall_hybrid.project_id_filter)
              AND (recall_hybrid.exclude_dag_id IS NULL
                   OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
              AND (recall_hybrid.p_content_types IS NULL
                   OR al.content_type = ANY(recall_hybrid.p_content_types))
              AND (_as_of_ts IS NULL
                   OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
              AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY 2 DESC
            LIMIT _fetch_k_bm25;

            EXECUTE 'SET LOCAL statement_timeout = 0';

        EXCEPTION WHEN query_canceled THEN
            _bm25_timed_out := TRUE;
            _has_text       := FALSE;
            RAISE NOTICE
                'pgmnemo.recall_hybrid: BM25 signal exceeded %ms budget — degrading to '
                'vector-only recall. Tune pgmnemo.bm25_budget_ms or shorten query_text.',
                _bm25_budget_ms;
        END;
    END IF;

    -- ── Phase 1: vector candidates — executed as a standalone EXECUTE statement ──
    --
    -- FIX (v0.14.1): When LIMIT is a plpgsql local variable, PostgreSQL compiles
    -- the RETURN QUERY block with a generic, parameter-blind plan that does not
    -- know the LIMIT value.  Without a concrete small-limit hint, the cost model
    -- prefers Seq Scan + top-N heapsort over the HNSW index scan, causing 10–1000×
    -- latency regressions on large corpora (confirmed with EXPLAIN on 3000–7440
    -- row corpus: HNSW cost 448 vs SeqScan 413 in generic plan; SeqScan wins
    -- without a concrete LIMIT, but HNSW wins when the planner sees the value).
    --
    -- Embedding _fetch_k_vec as a literal integer in the SQL text (via format())
    -- lets the planner see the concrete value and reliably choose the HNSW index
    -- scan.  The temp table is ON COMMIT DROP; a duplicate-table exception (same
    -- transaction, re-entrant call) is handled by truncating before reuse.

    BEGIN
        CREATE TEMP TABLE _pgmnemo_vc (
            id             BIGINT,
            role           TEXT,
            project_id     INT,
            topic          TEXT,
            lesson_text    TEXT,
            importance     SMALLINT,
            metadata       JSONB,
            commit_sha     TEXT,
            artifact_hash  TEXT,
            verified_at    TIMESTAMPTZ,
            created_at     TIMESTAMPTZ,
            confidence     REAL,
            raw_vec_score  DOUBLE PRECISION
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_vc;
    END;

    IF _has_vec THEN
        EXECUTE format($vec_sql$
            INSERT INTO _pgmnemo_vc
            SELECT
                al.id,
                al.role,        al.project_id, al.topic,      al.lesson_text,
                al.importance,  al.metadata,   al.commit_sha, al.artifact_hash,
                al.verified_at, al.created_at, al.confidence,
                (1.0 - (al.embedding <=> $1))::DOUBLE PRECISION  AS raw_vec_score
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.embedding IS NOT NULL
              AND ($2 OR al.verified_at IS NOT NULL)
              AND ($3 IS NULL OR al.role = $3)
              AND ($4 IS NULL OR al.project_id = $4)
              AND ($5 IS NULL OR al.source_dag_id IS DISTINCT FROM $5)
              AND ($6 IS NULL OR al.content_type = ANY($6))
              AND ($7 IS NULL OR (al.t_valid_from <= $7 AND al.t_valid_to > $7))
              AND ($7 IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY al.embedding <=> $1   -- HNSW index scan (literal LIMIT below)
            LIMIT %s                        -- literal value: planner sees k*4 or ef_search
        $vec_sql$, _fetch_k_vec)
        USING query_embedding, _include_unverified, role_filter, project_id_filter,
              exclude_dag_id, p_content_types, _as_of_ts;
    END IF;
    -- If _has_vec = FALSE: _pgmnemo_vc remains empty; all_candidates UNION ALL
    -- below will only contain rows from _pgmnemo_bm25_work.

    RETURN QUERY
    WITH RECURSIVE
    -- Merge: vector candidates (temp table) LEFT JOIN bm25 results + anti-join UNION ALL
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM _pgmnemo_vc v                            -- temp table (was: vec_candidates CTE)
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        SELECT
            al.id, al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            bw.raw_bm25_score
        FROM _pgmnemo_bm25_work bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE bw.id NOT IN (SELECT id FROM _pgmnemo_vc)
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
        WHERE (p_min_score IS NULL
               OR LEAST(1.0, GREATEST(0.0, f.v_score))::REAL >= p_min_score)
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    ),
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
        fr.lesson_id, fr.score, fr.vec_score, fr.bm25_score, fr.rrf_score,
        fr.role, fr.project_id, fr.topic, fr.lesson_text, fr.importance,
        fr.metadata, fr.commit_sha, fr.artifact_hash, fr.verified_at, fr.created_at,
        fr.confidence, fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

    IF NOT FOUND AND p_min_score IS NULL THEN
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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[], REAL) IS
    'v0.14.1 — HNSW planner regression fix. Vector candidates now fetched via '
    'EXECUTE with a literal LIMIT so the planner always sees the concrete value '
    'and chooses the HNSW index scan instead of Seq Scan + top-N heapsort. '
    'Confirmed on 3000–7440 row corpus: HNSW cost 448 vs SeqScan 413 in generic plan; '
    'literal LIMIT restores HNSW selection. Scoring, RRF, and recency stamp unchanged. '
    'v0.13.0 — Outcome Loop v2: adds p_min_score REAL DEFAULT NULL (11th param). '
    'p_min_score: filter rows where match_confidence (= vec_score clamped to [0,1]) < p_min_score. '
    'NULL = no filter (backward-compatible). Ghost-lesson NOTICE fires only when p_min_score IS NULL. '
    'Inherits v0.11.0 (RFC-001 §D2 / P0.2: typed recall) and v0.10.1 (#87) fixes: '
    'query_text cap, indexed full_text BM25, bm25_budget_ms timeout, simple tsconfig. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'RRF fusion is sparse-safe per Cormack 2009: unmatched candidates rank n_candidates+1. '
    'graph_proximity via mem_edge causal/temporal walk (depth ≤5). '
    'VOLATILE (side-effects: recency stamp, temp tables _pgmnemo_bm25_work, _pgmnemo_vc).';

-- §7: recall_fast — add p_min_score (7th param)
--
-- Drop old 6-param overload to prevent ambiguous-function errors.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT, TEXT[]);

CREATE OR REPLACE FUNCTION pgmnemo.recall_fast(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    exclude_dag_id    TEXT    DEFAULT NULL,
    p_content_types   TEXT[]  DEFAULT NULL,
    p_min_score       REAL    DEFAULT NULL  -- NEW
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
    WHERE (p_min_score IS NULL OR fr.vec_score::REAL >= p_min_score)
    ORDER BY fr.vec_score DESC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT, TEXT[], REAL) IS
    'HNSW-only vector recall — O(k log n), no BM25/graph/RRF. '
    'Uses ORDER BY embedding <=> query LIMIT k to activate the HNSW index. '
    'score = cosine similarity (1 - distance). '
    'Respects include_unverified, ef_search, track_recall_recency GUCs. '
    'Filters: role_filter, project_id_filter, exclude_dag_id (same as recall_hybrid). '
    'v0.10.0: default MCP recall path. Use recall_hybrid for full 6-signal fusion. '
    'v0.10.1 #84: raises EXCEPTION when query_embedding IS NULL (no text-only fallback). '
    'v0.11.1: p_content_types TEXT[] DEFAULT NULL (6th param) — typed recall pushdown '
    'using ix_pgmnemo_content_type_active. NULL=all types (backward-compatible). '
    'Non-NULL restricts candidates to the given content_type values before HNSW ranking. '
    'v0.13.0: p_min_score REAL DEFAULT NULL (7th param) — post-rank filter on vec_score.';

