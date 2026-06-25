-- pgmnemo--0.9.5--0.9.6.sql
-- Upgrade: pgmnemo v0.9.5 → v0.9.6
-- R11/R12/R13: versioned skill items, DAG-scoped recall, migration ingest log
-- SPDX-License-Identifier: Apache-2.0
--
-- Changes:
--   A) Schema: item_kind TEXT, version_n INT, patch_count INT, source_dag_id TEXT
--      on pgmnemo.agent_lesson + sparse index on source_dag_id
--   B) New table: pgmnemo.memory_ingest_log — migration batch tracking
--   C) recall_hybrid() and recall_lessons(): new exclude_dag_id TEXT DEFAULT NULL
--      parameter; when set, suppresses lessons whose source_dag_id matches.

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.6'" to load this file. \quit

-- =============================================================================
-- A) Schema additions (idempotent via ADD COLUMN IF NOT EXISTS)
-- =============================================================================

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS item_kind     TEXT  NOT NULL DEFAULT 'note'
        CHECK (item_kind IN ('note','skill_md','template','script','reference','config','spec')),
    ADD COLUMN IF NOT EXISTS version_n     INT   NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS patch_count   INT   NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS source_dag_id TEXT  NULL;

-- Sparse index: only rows with a DAG origin (subset of corpus)
CREATE INDEX IF NOT EXISTS ix_pgmnemo_agent_lesson_source_dag_id
    ON pgmnemo.agent_lesson (source_dag_id)
    WHERE source_dag_id IS NOT NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.item_kind IS
    'Content category: note (free-form), skill_md (structured skill document), template, '
    'script (executable), reference (external doc link), config, spec. '
    'Default: note. CHECK constraint enforces the allowed set.';

COMMENT ON COLUMN pgmnemo.agent_lesson.version_n IS
    'Monotonically increasing version counter for this lesson. '
    'Incremented when lesson_text is substantially revised. Default 1.';

COMMENT ON COLUMN pgmnemo.agent_lesson.patch_count IS
    'Number of minor patch edits applied since the last version bump. '
    'Reset to 0 on each version_n increment. Default 0.';

COMMENT ON COLUMN pgmnemo.agent_lesson.source_dag_id IS
    'Opaque identifier of the workflow or pipeline run that produced this lesson. '
    'NULL = no workflow origin (manually ingested or from unknown source). '
    'Sparse index ix_pgmnemo_agent_lesson_source_dag_id covers non-NULL rows. '
    'Used by exclude_dag_id parameter in recall_hybrid() and recall_lessons() '
    'to suppress lessons originating from the calling workflow.';

-- =============================================================================
-- B) memory_ingest_log — migration batch tracking table
-- =============================================================================

CREATE TABLE IF NOT EXISTS pgmnemo.memory_ingest_log (
    id            BIGSERIAL    PRIMARY KEY,
    source_origin TEXT         NOT NULL,
    min_id        BIGINT,
    max_id        BIGINT,
    ingested_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    retired_at    TIMESTAMPTZ  NULL
);

COMMENT ON TABLE pgmnemo.memory_ingest_log IS
    'Migration batch log: tracks ingestion runs from legacy memory tables into pgmnemo.agent_lesson. '
    'Each row records one batch: source schema/table (source_origin), id range (min_id..max_id), '
    'and ingestion timestamp. Set retired_at when the source table is dropped or the window closes. '
    'Operators may DROP this table once the cutover window is complete.';

COMMENT ON COLUMN pgmnemo.memory_ingest_log.source_origin IS
    'Identifier for the source of the batch, e.g. ''mem.item'' or ''legacy.agent_memory''.';
COMMENT ON COLUMN pgmnemo.memory_ingest_log.min_id IS
    'Lowest source-table id ingested in this batch (inclusive). NULL = unknown.';
COMMENT ON COLUMN pgmnemo.memory_ingest_log.max_id IS
    'Highest source-table id ingested in this batch (inclusive). NULL = unknown.';
COMMENT ON COLUMN pgmnemo.memory_ingest_log.ingested_at IS
    'Timestamp when the ingest batch completed.';
COMMENT ON COLUMN pgmnemo.memory_ingest_log.retired_at IS
    'Timestamp when the source was retired / decommissioned. NULL = still active.';

-- =============================================================================
-- C) recall_hybrid() v0.9.6 — adds exclude_dag_id TEXT DEFAULT NULL
--    Must DROP the old 8-arg overload because we're adding a parameter.
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
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL
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
          -- R13: DAG-scoped exclusion (IS DISTINCT FROM handles NULL source_dag_id gracefully)
          AND (recall_hybrid.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
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
          -- R13: DAG-scoped exclusion
          AND (recall_hybrid.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT) IS
    'v0.9.6 — R13: exclude_dag_id TEXT DEFAULT NULL parameter. When set, suppresses lessons '
    'whose source_dag_id matches the given value (IS DISTINCT FROM semantics: NULL source_dag_id rows '
    'always pass). Allows a workflow to exclude its own output from recall during the same run. '
    'v0.9.5 — Recall-recency stamping: stamps last_recalled_at + recall_count on returned lessons '
    'via data-modifying CTE (runs atomically with the SELECT, no double-scan). '
    'GUC pgmnemo.track_recall_recency (bool, default ON): set to off to disable stamping. '
    'v0.9.2 — I1: confidence-weighted ranking (additive, zero-centered). '
    'GUC pgmnemo.confidence_boost_weight (default 0.0 = OFF, range [0.0, 0.01]). '
    'When ON: final_score += w * (confidence - 0.5). Recommended w=0.003. '
    'v0.8.2 — F2: NOTICE when 0 rows returned and ghost lessons exist in scope. '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Two-phase indexed retrieval: HNSW (pgvector) + GIN (BM25) → RRF fusion → graph proximity boost. '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    '17 output columns. VOLATILE (side-effects: recency stamp).';

-- =============================================================================
-- C.2) recall_lessons() v0.9.6 — adds exclude_dag_id TEXT DEFAULT NULL
--      Must DROP the old 6-arg overload because we're adding a parameter.
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
    as_of_ts          TIMESTAMPTZ DEFAULT NULL,
    exclude_dag_id    TEXT        DEFAULT NULL
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

    -- Hybrid path delegates to recall_hybrid (which handles stamping + exclude_dag_id)
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
            role_filter, project_id_filter, 0.4, 0.4, 60,
            exclude_dag_id
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
          -- R13: DAG-scoped exclusion (vector-only path)
          AND (exclude_dag_id IS NULL OR al.source_dag_id IS DISTINCT FROM exclude_dag_id)
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

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ, TEXT) IS
    'v0.9.6 — R13: exclude_dag_id TEXT DEFAULT NULL parameter. When set, suppresses lessons '
    'whose source_dag_id matches the given value (IS DISTINCT FROM semantics). '
    'On the hybrid path, exclude_dag_id is forwarded to recall_hybrid(). '
    'v0.9.5 — Recall-recency stamping on vector-only path (hybrid path delegates to recall_hybrid). '
    'GUC pgmnemo.track_recall_recency (bool, default ON): set to off to disable stamping. '
    'v0.8.2 — F2: NOTICE when 0 rows returned (vector-only path) and ghost lessons exist in scope. '
    'v0.7.0 -- confidence integration + footgun guard + match_confidence. '
    'Scoring (vector path): 0.5*vec + 0.15*imp/5 + 0.15*confidence + gamma*recency + 0.1*prov + delta*graph. '
    '17 output columns. VOLATILE (side-effects: recency stamp).';
