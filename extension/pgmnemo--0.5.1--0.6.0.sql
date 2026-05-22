-- pgmnemo 0.5.1 → 0.6.0 upgrade migration
-- Changes:
--   §1  recall_hybrid()   — Fix-A: rrf_diag normalized to primary ranking signal (Option A-norm)
--                           + temporal filter from pgmnemo.as_of_timestamp GUC
--   §2  recall_lessons()  — add as_of_ts TIMESTAMPTZ DEFAULT NULL (6th param)
--   §3  pgmnemo.stats()   — add ghost_count BIGINT column
--   §4  pgmnemo.ingest()  — RAISE NOTICE when bitemporal close+create fires (Q5 dedup obs.)
-- Backward compatibility: zero breaking changes (see PLAN_V060.md §2 audit).
-- Prerequisites: pgmnemo 0.5.1 installed. Requires pgvector.
-- Apply: ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  recall_hybrid() — Fix-A + temporal filter
--
-- Fix-A: replace fusion_score ORDER BY with normalized rrf_diag
--        norm_denom = (vec_weight + bm25_weight) / (rrf_k + 1)
--        Normalizes rrf_diag to [0,1] so auxiliary terms stay at comparable scale.
--        Literature basis: Cormack et al. (SIGIR 2009).
-- Temporal: reads pgmnemo.as_of_timestamp GUC (set by recall_lessons() as_of_ts param).
-- No signature change → CREATE OR REPLACE sufficient.
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
    _rrf_k_f          DOUBLE PRECISION;
    _graph_weight     DOUBLE PRECISION;
    _max_depth        CONSTANT INT := 3;
    _include_unver    BOOLEAN;
    _as_of_ts         TIMESTAMPTZ;
    _rrf_norm_denom   DOUBLE PRECISION;  -- Fix-A: max possible rrf_diag value
BEGIN
    _rrf_k_f := rrf_k::DOUBLE PRECISION;

    -- Fix-A normalization denominator: max rrf_diag = (vec_w + bm25_w) / (rrf_k + 1)
    -- Normalizes rrf_diag to [0, 1] so auxiliary terms stay at comparable scale.
    -- Default params (0.4+0.4)/61 ≈ 0.01311; result is scale-invariant.
    _rrf_norm_denom := (vec_weight + bm25_weight) / (_rrf_k_f + 1.0);

    -- as_of_ts: read from GUC (set by recall_lessons() or directly by caller via SET)
    _as_of_ts := NULLIF(
        current_setting('pgmnemo.as_of_timestamp', TRUE), ''
    )::TIMESTAMPTZ;

    -- graph_proximity_weight GUC (default 0.2)
    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
        _graph_weight := LEAST(GREATEST(_graph_weight, 0.0), 0.5);
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;

    -- include_unverified GUC
    BEGIN
        _include_unver := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unver := FALSE;
    END;

    RETURN QUERY
    WITH
    -- Step 1: union candidates from dense ANN + BM25 sparse
    raw_candidates AS (
        -- Dense branch
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at,
            1.0 - (al.embedding <=> query_embedding) AS raw_vec_score,
            0.0::DOUBLE PRECISION                     AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.embedding IS NOT NULL
          AND (role_filter       IS NULL OR al.role       = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          AND (_include_unver OR al.verified_at IS NOT NULL)
          -- as_of temporal filter (v0.6.0): restricts to lessons valid at _as_of_ts
          AND (
              _as_of_ts IS NULL
              OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts)
          )
          -- When no as_of_ts: use standard active-row filter
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT GREATEST(k * 5, 50)

        UNION ALL

        -- BM25 sparse branch
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at,
            0.0::DOUBLE PRECISION                      AS raw_vec_score,
            ts_rank_cd(al.lesson_tsv,
                       plainto_tsquery('english', query_text),
                       32)::DOUBLE PRECISION           AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.lesson_tsv @@ plainto_tsquery('english', query_text)
          AND (role_filter       IS NULL OR al.role       = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          AND (_include_unver OR al.verified_at IS NOT NULL)
          AND (
              _as_of_ts IS NULL
              OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts)
          )
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        LIMIT GREATEST(k * 5, 50)
    ),
    -- Step 2: aggregate per-id, compute RRF ranks
    deduped AS (
        SELECT
            id,
            role, project_id, topic, lesson_text,
            importance, metadata, commit_sha, artifact_hash,
            verified_at, created_at,
            MAX(raw_vec_score)  AS raw_vec_score,
            MAX(raw_bm25_score) AS raw_bm25_score
        FROM raw_candidates
        GROUP BY id, role, project_id, topic, lesson_text,
                 importance, metadata, commit_sha, artifact_hash,
                 verified_at, created_at
    ),
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST) AS vec_rank,
            ROW_NUMBER() OVER (ORDER BY raw_bm25_score DESC NULLS LAST) AS bm25_rank
        FROM deduped
    ),
    -- Step 3: compute rrf_diag (primary ranking signal, v0.6.0) + fusion_score (diagnostic)
    scored AS (
        SELECT
            r.id,
            r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            -- Fix-A: rrf_diag is now the PRIMARY ranking signal (normalized to [0,1])
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + r.bm25_rank::DOUBLE PRECISION))
                AS rrf_diag,
            -- fusion_score retained as diagnostic (was primary before v0.6.0)
            (vec_weight  * r.raw_vec_score
           + bm25_weight * r.raw_bm25_score)
                AS fusion_score
        FROM rrf_ranked r
    ),
    -- Step 4: anchor top-5 by rrf_diag (Fix-A: was fusion_score) for graph proximity walk
    anchors AS (
        SELECT id
        FROM scored
        ORDER BY (rrf_diag / _rrf_norm_denom) DESC   -- Fix-A: normalized rrf_diag
        LIMIT 5
    ),
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
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
        s.id          AS lesson_id,
        -- Final score: Fix-A normalized rrf_diag + auxiliary components
        (
            (s.rrf_diag / _rrf_norm_denom)               -- Fix-A: replaces s.fusion_score
          + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
          + 0.05 * GREATEST(0.0,
                       1.0 - LEAST(
                           EXTRACT(EPOCH FROM (
                               COALESCE(_as_of_ts, NOW()) - s.created_at
                           )) / (90.0 * 86400.0),
                           1.0
                       )
                   )::DOUBLE PRECISION
          + 0.05 * (CASE
                      WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                      WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                      ELSE                                                             0.0
                    END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )             AS score,
        s.v_score     AS vec_score,
        s.b_score     AS bm25_score,
        s.rrf_diag    AS rrf_score,   -- column name unchanged (callers already used rrf_score)
        s.role, s.project_id, s.topic, s.lesson_text,
        s.importance, s.metadata, s.commit_sha, s.artifact_hash,
        s.verified_at, s.created_at
    FROM scored s
    LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ORDER BY
        (
            (s.rrf_diag / _rrf_norm_denom)               -- Fix-A ORDER BY matches SELECT score
          + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
          + 0.05 * GREATEST(0.0,
                       1.0 - LEAST(
                           EXTRACT(EPOCH FROM (
                               COALESCE(_as_of_ts, NOW()) - s.created_at
                           )) / (90.0 * 86400.0),
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
    'Hybrid recall v0.6.0. '
    'Fix-A: rrf_diag promoted to primary ranking signal (Cormack 2009 RRF). '
    'Normalized via (vec_weight+bm25_weight)/(rrf_k+1) to preserve auxiliary-component balance. '
    'Temporal filter: reads pgmnemo.as_of_timestamp GUC (set by recall_lessons() as_of_ts param). '
    'rrf_score column = raw rrf_diag (was diagnostic-only before v0.6.0). '
    'fusion_score retained internally as diagnostic; not returned. '
    'Union retrieval: candidates from EITHER embedding cosine OR BM25 text match. '
    'graph_proximity_weight GUC (default 0.2). ef_search GUC (default 100). '
    'PARALLEL SAFE (current_setting read-only; set_config in recall_lessons not here).';


-- ─────────────────────────────────────────────────────────────────────────────
-- §2  recall_lessons() — add as_of_ts TIMESTAMPTZ DEFAULT NULL (6th param)
--
-- Return type unchanged (15 cols).
-- Existing callers with 5 positional args resolve to 6-arg form with as_of_ts=NULL.
-- PostgreSQL won't replace a function with different arg count → DROP old overload first.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT          DEFAULT 10,
    role_filter       TEXT         DEFAULT NULL,
    project_id_filter INT          DEFAULT NULL,
    query_text        TEXT         DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ  DEFAULT NULL    -- v0.6.0: point-in-time temporal scoping
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
PARALLEL UNSAFE   -- set_config() in body prevents parallel execution
AS $$
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
BEGIN
    -- v0.6.0: as_of_ts — set transaction-local GUC consumed by recall_hybrid()
    -- set_config(TRUE) = transaction-local; cleared after COMMIT/ROLLBACK (no pool leak).
    IF as_of_ts IS NOT NULL THEN
        PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
    END IF;

    -- R5: clamp query_text to pgmnemo.max_query_text_chars (default 2000)
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

    -- Route to recall_hybrid() when: text present + embedding present + hybrid not disabled
    IF NOT _disable_hybrid
       AND _query_text IS NOT NULL
       AND length(trim(_query_text)) > 0
       AND query_embedding IS NOT NULL THEN
        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score
        FROM pgmnemo.recall_hybrid(
            query_embedding,
            _query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,   -- vec_weight
            0.4,   -- bm25_weight
            60     -- rrf_k
        ) h;
        RETURN;
    END IF;

    -- Vector-only path: populate vec_score = raw cosine; bm25_score = NULL; rrf_score = NULL.
    -- v0.6.0: temporal filter added to candidates WHERE clause.
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT,
            100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
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
        0.05  -- v0.4.1: default lowered from 0.08 per Agency ablation (R1)
    );

    BEGIN
        _temporal_boost := COALESCE(
            NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
            1.0
        );
        IF _temporal_boost < 0.0 THEN _temporal_boost := 0.0; END IF;
    EXCEPTION WHEN OTHERS THEN
        _temporal_boost := 1.0;
    END;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
        _graph_weight := LEAST(GREATEST(_graph_weight, 0.0), 0.5);
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;

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
        WHERE al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          -- v0.6.0 temporal filter: restrict to lessons valid at as_of_ts
          AND (
              as_of_ts IS NULL
              OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts)
          )
          AND (as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
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
                EXTRACT(EPOCH FROM (COALESCE(as_of_ts, NOW()) - c.cand_created_at))
                / (90.0 * 86400.0), 1.0
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
            EXTRACT(EPOCH FROM (COALESCE(as_of_ts, NOW()) - c.cand_created_at))
            / (90.0 * 86400.0), 1.0
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
    'v0.6.0 hybrid router with as_of_ts temporal scoping and Fix-A RRF ranking. '
    'as_of_ts (default NULL = now): restricts candidates to lessons valid at ts '
    '(t_valid_from <= ts < t_valid_to). Sets pgmnemo.as_of_timestamp GUC (tx-local) '
    'consumed by recall_hybrid(). '
    'PARALLEL UNSAFE due to set_config(); not invoked inside parallel workers. '
    'Routes to recall_hybrid() when query_text + embedding present and disable_hybrid=false. '
    'Fix-A: recall_hybrid() now ranks by normalized rrf_diag (Cormack 2009 RRF).';


-- ─────────────────────────────────────────────────────────────────────────────
-- §3  pgmnemo.stats() — add ghost_count BIGINT (Agency RFC Q4)
--
-- Return type changes (13 → 14 cols) → must DROP before CREATE.
-- ghost_count: active lessons with verified_at IS NULL (no provenance).
-- Distinct from orphan_count (functions not owned by extension).
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
    ghost_count                BIGINT     -- NEW v0.6.0: active lessons without provenance
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
        -- Definition: verified_at IS NULL AND t_valid_to = 'infinity' (currently active)
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.6.0 diagnostic health-check. Adds ghost_count (Agency RFC Q4). '
    'ghost_count: active lessons where verified_at IS NULL — no commit_sha AND no artifact_hash. '
    'Distinct from orphan_count (functions not owned by extension). '
    'Use ghost_count to track provenance migration progress: target < 5% of lesson_count '
    'before switching pgmnemo.include_unverified = off. '
    'Single-row summary; <50ms on N=10k corpus.';


-- ─────────────────────────────────────────────────────────────────────────────
-- §4  pgmnemo.ingest() — RAISE NOTICE on bitemporal close+create (Agency RFC Q5)
--
-- Pre-insert content_hash check; RAISE NOTICE if dedup close fires.
-- content_hash formula matches GENERATED ALWAYS AS column:
--   MD5(COALESCE(role,'') || '|' || COALESCE(topic,'') || '|' || COALESCE(commit_sha, artifact_hash, ''))
-- No signature change → CREATE OR REPLACE sufficient.
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
    p_metadata      JSONB        DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id          BIGINT;
    _max_chars      INT;
    _content_hash   TEXT;
    _prior_count    INT;
BEGIN
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
        commit_sha, artifact_hash, metadata, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
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

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API (v0.6.0 + Q5). '
    'Q5: RAISE NOTICE when bitemporal close+create fires (dedup observability). '
    'Caller receives NOTICE "bitemporal close+create fired — closed N prior version(s)". '
    'On idempotent re-run (same args): NOTICE fires again if prior row was already closed+recreated. '
    'Truncates p_lesson_text to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'R5 (v0.5.0).';
