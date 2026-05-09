-- pgmnemo upgrade: 0.2.1 → 0.3.0 (MAGMA §3 — temporal + entity graph schema)
-- Extends mem_edge with edge_kind ENUM (semantic|temporal|causal|entity),
-- per-kind partial indexes, and backfills existing rows from edge_type.
-- SPDX-License-Identifier: Apache-2.0
--
-- Migration: v0.3.0_001
-- RFC: spec/v2/pgmnemo/PGMNEMO_V0.3.0_MAGMA_RFC.md
--
-- Operator notes:
--   No manual actions required post-upgrade.
--   edge_kind is backfilled automatically based on edge_type mapping.
--   For empty mem_edge tables the backfill UPDATE is a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- S1: Create edge_kind ENUM
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pgmnemo' AND t.typname = 'edge_kind'
    ) THEN
        CREATE TYPE pgmnemo.edge_kind AS ENUM ('semantic', 'temporal', 'causal', 'entity');
    END IF;
END;
$$;

COMMENT ON TYPE pgmnemo.edge_kind IS
    'MAGMA §3 top-level edge category. '
    'causal: cause-effect (edge_type: causal, derives_from, contradicts). '
    'temporal: time-ordered co-occurrence (edge_type: temporal). '
    'semantic: meaning/knowledge relation (edge_type: semantic, elaborates, supersedes). '
    'entity: entity co-membership/reference (edge_type: entity).';

-- ─────────────────────────────────────────────────────────────────────────────
-- S2: Add edge_kind column (nullable initially for backfill)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'pgmnemo'
          AND table_name   = 'mem_edge'
          AND column_name  = 'edge_kind'
    ) THEN
        ALTER TABLE pgmnemo.mem_edge
            ADD COLUMN edge_kind pgmnemo.edge_kind;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- S3: Backfill edge_kind from edge_type
--     Mapping (MAGMA §3 Table 1):
--       causal      → causal
--       derives_from→ causal
--       contradicts → causal
--       temporal    → temporal
--       semantic    → semantic
--       elaborates  → semantic
--       supersedes  → semantic
--       entity      → entity
--       (fallback)  → semantic  -- safe default for any future edge_type values
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE pgmnemo.mem_edge
SET edge_kind = CASE
    WHEN edge_type IN ('causal', 'derives_from', 'contradicts') THEN 'causal'::pgmnemo.edge_kind
    WHEN edge_type = 'temporal'                                  THEN 'temporal'::pgmnemo.edge_kind
    WHEN edge_type IN ('semantic', 'elaborates', 'supersedes')   THEN 'semantic'::pgmnemo.edge_kind
    WHEN edge_type = 'entity'                                    THEN 'entity'::pgmnemo.edge_kind
    ELSE                                                              'semantic'::pgmnemo.edge_kind
END
WHERE edge_kind IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- S4: Enforce NOT NULL + add CHECK-backed default for future inserts
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE pgmnemo.mem_edge
    ALTER COLUMN edge_kind SET NOT NULL;

COMMENT ON COLUMN pgmnemo.mem_edge.edge_kind IS
    'MAGMA §3 top-level category (semantic|temporal|causal|entity). '
    'Backfilled from edge_type in v0.3.0_001. '
    'Must be set on all new inserts — use the edge_type→edge_kind mapping in the RFC.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S5: Per-kind partial indexes (traversal-optimised)
--
-- Each index is scoped to a single edge_kind value, making index-only scans
-- possible for the most common graph-walk patterns:
--   causal   : forward/backward causal chain traversal
--   temporal : time-window BFS (source_id + created_at ordering)
--   semantic : similarity/elaboration fan-out (source + weight)
--   entity   : entity co-membership lookup
--
-- Note: a GIN index on metadata JSONB is also added for per-kind attribute
-- filtering (e.g. querying edge metadata properties within a kind).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS ix_mem_edge_kind_causal
    ON pgmnemo.mem_edge (source_id, target_id, weight DESC)
    WHERE edge_kind = 'causal';

CREATE INDEX IF NOT EXISTS ix_mem_edge_kind_temporal
    ON pgmnemo.mem_edge (source_id, created_at DESC, target_id)
    WHERE edge_kind = 'temporal';

CREATE INDEX IF NOT EXISTS ix_mem_edge_kind_semantic
    ON pgmnemo.mem_edge (source_id, weight DESC, target_id)
    WHERE edge_kind = 'semantic';

CREATE INDEX IF NOT EXISTS ix_mem_edge_kind_entity
    ON pgmnemo.mem_edge (source_id, target_id)
    WHERE edge_kind = 'entity';

-- GIN index on metadata for JSONB attribute queries scoped to any edge_kind
CREATE INDEX IF NOT EXISTS ix_mem_edge_metadata_gin
    ON pgmnemo.mem_edge USING GIN (metadata)
    WHERE metadata != '{}'::jsonb;

-- ─────────────────────────────────────────────────────────────────────────────
-- S6: Update composite index to include edge_kind for mixed-kind queries
-- ─────────────────────────────────────────────────────────────────────────────
DROP INDEX IF EXISTS pgmnemo.ix_pgmnemo_mem_edge_type_time;
CREATE INDEX IF NOT EXISTS ix_pgmnemo_mem_edge_kind_time
    ON pgmnemo.mem_edge (edge_kind, created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- S7: recall_lessons() — fix BFS to use edge_kind (was incorrectly using
--     me.relation_type with uppercase CAUSED_BY/CO_OCCURRED/DERIVED_FROM
--     which never matched the edge_type CHECK values)
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
    _gamma              DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
BEGIN
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
        0.08
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
    WITH RECURSIVE
    candidates AS (
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
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL OR al.project_id = recall_lessons.project_id_filter)
          AND (al.embedding IS NOT NULL OR _has_text)
    ),
    anchors AS (
        SELECT id
        FROM candidates
        ORDER BY vec_score DESC
        LIMIT 5
    ),
    -- BFS through causal + temporal edges (v0.3.0: now uses edge_kind ENUM)
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id
        FROM anchors

        UNION ALL

        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT
            gw.reached_id                                                          AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION)  AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    )
    SELECT
        c.id                                                                  AS lesson_id,
        (
            0.4 * c.vec_score
          + 0.2 * (c.importance::DOUBLE PRECISION / 5.0)
          + _gamma * GREATEST(0.0,
                        1.0 - LEAST(
                            EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0),
                            1.0
                        )
                    )::DOUBLE PRECISION
          + 0.1 * (CASE
                     WHEN c.commit_sha IS NOT NULL AND c.verified_at IS NOT NULL THEN 1.0
                     WHEN c.commit_sha IS NOT NULL                               THEN 0.4
                     ELSE                                                             0.0
                   END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )                                                                     AS score,
        c.role,
        c.project_id,
        c.topic,
        c.lesson_text,
        c.importance,
        c.metadata,
        c.commit_sha,
        c.artifact_hash,
        c.verified_at,
        c.created_at
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.lesson_id = c.id
    ORDER BY
        (
            0.4 * c.vec_score
          + 0.2 * (c.importance::DOUBLE PRECISION / 5.0)
          + _gamma * GREATEST(0.0,
                        1.0 - LEAST(
                            EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0),
                            1.0
                        )
                    )::DOUBLE PRECISION
          + 0.1 * (CASE
                     WHEN c.commit_sha IS NOT NULL AND c.verified_at IS NOT NULL THEN 1.0
                     WHEN c.commit_sha IS NOT NULL                               THEN 0.4
                     ELSE                                                             0.0
                   END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) DESC,
        c.importance DESC,
        c.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'Hybrid recall v0.3.0 — formula: '
    '0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity. '
    'graph_proximity = MAX(1 - depth/max_depth) over causal+temporal BFS (edge_kind ENUM) '
    'from top-5 cosine anchors (max_depth=5). '
    'v0.3.0: BFS now uses edge_kind IN (''causal'',''temporal'') — fixes v0.2.x relation_type bug. '
    'γ = pgmnemo.recency_weight (default 0.08). '
    'ef_search = pgmnemo.ef_search GUC (default 100, applied via SET LOCAL). '
    'δ = pgmnemo.graph_proximity_weight (default 0.2, range 0.0–0.5).';

-- ─────────────────────────────────────────────────────────────────────────────
-- S8: traverse_causal_chain — update to use edge_kind for causal traversal
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.traverse_causal_chain(
    start_id        BIGINT,
    max_depth       INT     DEFAULT 5,
    relation_types  TEXT[]  DEFAULT ARRAY['causal', 'derives_from', 'contradicts'],
    only_active     BOOLEAN DEFAULT TRUE,
    direction       TEXT    DEFAULT 'forward'
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
        RAISE EXCEPTION 'pgmnemo.traverse_causal_chain: direction must be ''forward'', ''backward'', or ''both'' — got: %', direction;
    END IF;

    RETURN QUERY
    WITH RECURSIVE causal_walk(lesson_id, depth, path, path_weight) AS (
        SELECT
            start_id,
            0,
            ARRAY[start_id],
            1.0::REAL

        UNION ALL

        -- Forward: source → target (causal kind, edge_type in relation_types)
        SELECT
            me.target_id,
            cw.depth + 1,
            cw.path || me.target_id,
            cw.path_weight * COALESCE(me.weight, 1.0)
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON me.source_id = cw.lesson_id
        WHERE direction IN ('forward', 'both')
          AND me.edge_kind = 'causal'
          AND me.edge_type = ANY(relation_types)
          AND cw.depth < max_depth
          AND NOT (me.target_id = ANY(cw.path))

        UNION ALL

        -- Backward: target → source (causal kind, edge_type in relation_types)
        SELECT
            me.source_id,
            cw.depth + 1,
            cw.path || me.source_id,
            cw.path_weight * COALESCE(me.weight, 1.0)
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON me.target_id = cw.lesson_id
        WHERE direction IN ('backward', 'both')
          AND me.edge_kind = 'causal'
          AND me.edge_type = ANY(relation_types)
          AND cw.depth < max_depth
          AND NOT (me.source_id = ANY(cw.path))
    )
    SELECT
        al.id,
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
    'BFS traversal of causal edges in pgmnemo.mem_edge (v0.3.0). '
    'Filters on edge_kind = ''causal'' + edge_type IN relation_types. '
    'Default relation_types: causal, derives_from, contradicts (MAGMA §3). '
    'direction: ''forward'' (source→target), ''backward'' (target→source), ''both''. '
    'Cycle guard via path array.';

COMMENT ON TABLE pgmnemo.mem_edge IS
    'Multi-graph relations between lessons. '
    'v0.2.0: initial schema. v0.3.0: edge_kind ENUM (MAGMA §3) + per-kind partial indexes.';
