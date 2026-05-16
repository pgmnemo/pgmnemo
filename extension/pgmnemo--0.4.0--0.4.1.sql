-- pgmnemo 0.4.0 → 0.4.1 upgrade
--
-- THEME: Production hardening per Agency RFC 2026-05-16 (first external
--        production-user feedback). Operational observability + safe deprecation.
--
-- Bench evidence (real-DB, expected 2026-05-21 after Phase 2):
--   LoCoMo session    : neutral expected — R1 default change 0.08 → 0.05 may
--                       cause near-threshold drift; OVERALL r@10 = 0.8409 hold
--   LoCoMo segment    : neutral expected — router unchanged
--   LongMemEval-S     : neutral expected — hybrid neutral on bge-m3 saturated
--   Agency corpus     : Architecture C gate (recall@10 ≥ 0.55) must hold after
--                       default change (Agency reruns harness post-ship per A5)
--
-- Honest scope:
--   ✓ pgmnemo.stats() one-query health check (R3)
--   ✓ vec_score / bm25_score / rrf_score in recall_lessons output (R4)
--   ✓ recency_weight default 0.08 → 0.05 per Agency ablation (R1 code part)
--   ✓ orphan_count signal in pgmnemo.stats() (R7)
--   ✓ traverse_causal_chain 4-arg overload restored with RAISE NOTICE (R10)
--   ✗ Recall algorithm itself unchanged — same router as v0.4.0
--   ✗ No new graph capabilities — mem_edge contract docs shipped 2026-05-16,
--     add_edge() helper SP scheduled v0.5.0
--
-- Migration design (5 steps):
--   S1: pgmnemo.stats() SP with 13 health-signal columns
--   S2: recall_lessons() router rewritten — 3 new diagnostic columns appended
--       (vec_score, bm25_score, rrf_score)
--   S3: recency_weight default 0.08 → 0.05 (R1 code part)
--   S4: traverse_causal_chain 4-arg overload with deprecation NOTICE (R10)
--   S5: COMMENT refreshes citing the new defaults

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.4.1'" to load this file.  \quit


-- ─────────────────────────────────────────────────────────────────────────────
-- S1: pgmnemo.stats() — diagnostic health-check SP
-- Agency RFC R3 + maintainer additions (recall_hybrid_available,
-- oldest_lesson_age_days, orphan_count for R7).
-- ─────────────────────────────────────────────────────────────────────────────

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
    orphan_count               BIGINT
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT
        pgmnemo.version() AS version,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.agent_lesson) AS lesson_count,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.agent_lesson WHERE embedding IS NOT NULL) AS embedded_count,
        (SELECT CASE WHEN COUNT(*) > 0
                     THEN ROUND(100.0 * SUM(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END)::NUMERIC / COUNT(*), 2)::DOUBLE PRECISION
                     ELSE 0.0::DOUBLE PRECISION END
         FROM pgmnemo.agent_lesson) AS embedding_coverage_pct,
        (SELECT CASE WHEN COUNT(*) > 0
                     THEN ROUND(100.0 * SUM(CASE WHEN lesson_tsv IS NOT NULL THEN 1 ELSE 0 END)::NUMERIC / COUNT(*), 2)::DOUBLE PRECISION
                     ELSE 0.0::DOUBLE PRECISION END
         FROM pgmnemo.agent_lesson) AS tsv_coverage_pct,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.mem_edge) AS mem_edge_count,
        COALESCE(NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION, 0.05) AS recency_weight,
        COALESCE(NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100) AS ef_search,
        COALESCE(NULLIF(current_setting('pgmnemo.importance_weight', TRUE), '')::DOUBLE PRECISION, 0.15) AS importance_weight,
        NOT COALESCE(current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE) AS hybrid_enabled,
        EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
        ) AS recall_hybrid_available,
        (SELECT COALESCE(
            EXTRACT(EPOCH FROM (NOW() - MIN(created_at))) / 86400.0,
            0
        )::INT FROM pgmnemo.agent_lesson) AS oldest_lesson_age_days,
        (
            SELECT COUNT(*)::BIGINT
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            LEFT JOIN pg_depend d
                ON d.objid = p.oid
               AND d.deptype = 'e'
               AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
            WHERE n.nspname = 'pgmnemo'
              AND p.proname NOT LIKE '\_%' ESCAPE '\'   -- exclude private _foo() helpers
              AND d.objid IS NULL
        ) AS orphan_count;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.4.1 diagnostic health-check (Agency RFC R3). Single-row summary of '
    'corpus size, embedding/tsvector coverage, GUC values, hybrid availability, '
    'and orphan-function count (functions in pgmnemo schema not owned by the '
    'extension — typically caused by intermediate manual SQL patches; see '
    'docs/MIGRATION.md §B.5 for recovery). Safe to call from monitoring loops; '
    '<50ms on N=10k corpus.';


-- ─────────────────────────────────────────────────────────────────────────────
-- S2: recall_lessons() router — adds 3 diagnostic columns (R4)
-- vec_score, bm25_score, rrf_score appended at end of return row.
-- Backward compatible for named-column callers; positional callers re-audit.
--
-- Return type changed (12 → 15 cols) → must DROP before CREATE OR REPLACE.
-- PostgreSQL refuses to alter the row-type of a function in-place.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT);

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
STABLE
PARALLEL SAFE
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
        0.05  -- v0.4.1: default lowered from 0.08 per Agency ablation (R1)
    );

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
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
    'pgmnemo.recency_weight (default 0.05 since v0.4.1 per Agency ablation). '
    'Diagnostic columns (v0.4.1, R4): vec_score = raw cosine; bm25_score / '
    'rrf_score = NULL on vector-only path, populated on hybrid path. '
    'Opt-out: SET pgmnemo.disable_hybrid = ''true''.';


-- ─────────────────────────────────────────────────────────────────────────────
-- S4: traverse_causal_chain — 4-arg deprecation with NOTICE (Agency RFC R10)
--
-- v0.4.0 ships only the 5-arg form with direction DEFAULT 'forward'. To support
-- Agency's existing 4-arg callers (v3_001_baseline.py) AND add a deprecation
-- NOTICE, we restructure both overloads:
--   - 5-arg: remove DEFAULT on direction (becomes explicit required parameter)
--   - 4-arg: new wrapper emitting RAISE NOTICE, delegating to 5-arg
--
-- This removes overload ambiguity (4-arg call → unambiguous match to 4-arg
-- wrapper) while preserving both call patterns.
--
-- Will be REMOVED in v0.5.0.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);

CREATE OR REPLACE FUNCTION pgmnemo.traverse_causal_chain(
    start_id        BIGINT,
    max_depth       INT,
    relation_types  TEXT[],
    only_active     BOOLEAN,
    direction       TEXT      -- v0.4.1: DEFAULT removed; required explicit value
)
RETURNS TABLE (
    lesson_id       BIGINT,
    depth           INT,
    path            BIGINT[],
    path_weight     REAL,
    role            TEXT,
    topic           TEXT,
    lesson_text     TEXT,
    importance      SMALLINT,
    created_at      TIMESTAMPTZ,
    commit_sha      TEXT,
    verified_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
BEGIN
    IF direction NOT IN ('forward', 'backward', 'both') THEN
        RAISE EXCEPTION
            'pgmnemo.traverse_causal_chain: direction must be ''forward'', ''backward'', or ''both'' — got: %',
            direction;
    END IF;

    RETURN QUERY
    WITH RECURSIVE causal_walk(lesson_id, depth, path, path_weight) AS (
        SELECT start_id, 0, ARRAY[start_id]::BIGINT[], 1.0::REAL
        UNION ALL
        SELECT
            CASE
                WHEN direction IN ('forward', 'both') AND me.source_id = cw.lesson_id THEN me.target_id
                WHEN direction IN ('backward', 'both') AND me.target_id = cw.lesson_id THEN me.source_id
            END,
            cw.depth + 1,
            cw.path ||
                CASE
                    WHEN direction IN ('forward', 'both') AND me.source_id = cw.lesson_id THEN me.target_id
                    WHEN direction IN ('backward', 'both') AND me.target_id = cw.lesson_id THEN me.source_id
                END,
            cw.path_weight * me.weight
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON (
            (direction IN ('forward', 'both') AND me.source_id = cw.lesson_id) OR
            (direction IN ('backward', 'both') AND me.target_id = cw.lesson_id)
        )
        WHERE cw.depth < max_depth
          AND me.relation_type = ANY(relation_types)
          AND NOT (
              CASE
                  WHEN direction IN ('forward', 'both') AND me.source_id = cw.lesson_id THEN me.target_id
                  WHEN direction IN ('backward', 'both') AND me.target_id = cw.lesson_id THEN me.source_id
              END = ANY(cw.path)
          )
    )
    SELECT
        cw.lesson_id,
        cw.depth,
        cw.path,
        cw.path_weight,
        al.role,
        al.topic,
        al.lesson_text,
        al.importance,
        al.created_at,
        al.commit_sha,
        al.verified_at
    FROM causal_walk cw
    JOIN pgmnemo.agent_lesson al ON al.id = cw.lesson_id
    WHERE cw.depth > 0
      AND (NOT only_active OR al.is_active)
    ORDER BY cw.depth, cw.path_weight DESC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN, TEXT) IS
    'v0.4.1 (canonical, since R10 deprecation cycle): BFS over mem_edge with '
    'explicit required direction (forward/backward/both). For callers from '
    'v0.4.0 or earlier that omitted direction (got DEFAULT ''forward'' silently), '
    'use the 4-arg deprecated wrapper or update calls to pass direction explicitly.';


-- 4-arg deprecation wrapper — emits NOTICE on every call.
CREATE OR REPLACE FUNCTION pgmnemo.traverse_causal_chain(
    start_id        BIGINT,
    max_depth       INT,
    relation_types  TEXT[],
    only_active     BOOLEAN
)
RETURNS TABLE (
    lesson_id       BIGINT,
    depth           INT,
    path            BIGINT[],
    path_weight     REAL,
    role            TEXT,
    topic           TEXT,
    lesson_text     TEXT,
    importance      SMALLINT,
    created_at      TIMESTAMPTZ,
    commit_sha      TEXT,
    verified_at     TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
BEGIN
    RAISE NOTICE 'pgmnemo.traverse_causal_chain 4-arg overload is DEPRECATED in v0.4.1 and will be REMOVED in v0.5.0. Use the 5-arg form: traverse_causal_chain(start_id, max_depth, relation_types, only_active, direction). See CHANGELOG [0.4.1] for migration guidance.';
    RETURN QUERY
    SELECT * FROM pgmnemo.traverse_causal_chain(start_id, max_depth, relation_types, only_active, 'forward'::TEXT);
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN) IS
    'DEPRECATED in v0.4.1 (Agency RFC R10). Wrapper around 5-arg form with '
    'direction=''forward''. Emits RAISE NOTICE on every call. Will be REMOVED '
    'in v0.5.0; update callers to pass direction explicitly.';
