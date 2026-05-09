-- pgmnemo v0.2.0 step4: hybrid recall_lessons() with graph_proximity mixin
-- PGMNEMO-V020-4: integrates graph traversal into recall_lessons() scoring
-- SPDX-License-Identifier: Apache-2.0
--
-- ⚠️  SUPPLEMENTAL / OPTIONAL SCRIPT — NOT PART OF THE STANDARD UPGRADE PATH
-- This file is intentionally excluded from the Makefile DATA field.
-- It is NOT a valid pgxs extension upgrade script (non-standard naming convention).
-- To apply the graph_proximity mixin to recall_lessons(), run this script manually:
--   psql -d <your_db> -f extension/pgmnemo--0.2.0-step4-recall-mixin.sql
-- Requires: pgmnemo v0.2.0 or later (mem_edge table must exist).
-- Future versions will incorporate this mixin into a properly named upgrade script.
--
-- Formula: 0.4*cosine + 0.2*importance + γ*recency + 0.1*prov_strength + δ*graph_proximity
--   graph_proximity = COALESCE(MAX(1.0 - depth/max_depth), 0)
--                     over causal+temporal traversal from top-5 cosine anchors
-- GUC: pgmnemo.graph_proximity_weight (default 0.2, range 0.0–0.5)
-- Requires: pgmnemo.mem_edge table (v0.2.0 mem_edge step)

-- ─────────────────────────────────────────────────────────────────────────────
-- GUC documentation comment (PostgreSQL does not have CREATE GUC in SQL;
-- callers set via: SET pgmnemo.graph_proximity_weight = '0.3';)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    -- Seed the GUC into pg_settings so it is visible after first SET.
    -- This is a no-op if already set; harmless on repeated upgrade runs.
    PERFORM set_config('pgmnemo.graph_proximity_weight', '0.2', FALSE);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- recall_lessons() — graph-proximity mixin (replaces v0.1.2 definition)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding  vector(1024),
    k                INT     DEFAULT 10,
    role_filter      TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    query_text       TEXT    DEFAULT NULL
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
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
BEGIN
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
        0.2
    );

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    -- Clamp to declared range [0.0, 0.5]
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
    -- Top-5 cosine anchors used as traversal seeds
    anchors AS (
        SELECT id
        FROM candidates
        ORDER BY vec_score DESC
        LIMIT 5
    ),
    -- BFS through causal + temporal edges from anchors (depth-limited)
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
    -- Best proximity per reached lesson (MAX = closest anchor path)
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
    'Hybrid recall v0.2.0-step4 — formula: '
    '0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity. '
    'graph_proximity = MAX(1 - depth/max_depth) over causal+temporal+derives_from BFS '
    'from top-5 cosine anchors (max_depth=5). '
    'γ = pgmnemo.recency_weight (default 0.2). '
    'δ = pgmnemo.graph_proximity_weight (default 0.2, range 0.0–0.5). '
    'prov_strength: 1.0=commit+verified, 0.4=commit-only, 0.0=no provenance. '
    'role=NULL returns all roles pooled.';
