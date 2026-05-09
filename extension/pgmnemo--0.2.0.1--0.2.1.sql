-- pgmnemo upgrade: 0.2.0.1 → 0.2.1
-- Changes:
--   F1: recency_weight GUC default change (0.2 → 0.08, pending ablation confirmation)
--   F2: pgmnemo.ef_search GUC + SET LOCAL in recall_lessons() and recall_lessons_pooled()
--   F3: step4 graph_proximity mixin folded into standard upgrade path (was supplemental-only)
--   F5: traverse_causal_chain(direction) — P2, see note below
-- SPDX-License-Identifier: Apache-2.0
--
-- ⚠️  F5 (traverse_causal_chain direction parameter) is P2 — gated on mem_edge population.
--    If pgmnemo.mem_edge has 0 rows in production, defer F5 to v0.2.2.
--    F5 is included here as a CREATE OR REPLACE — it adds a parameter with a default,
--    so it is backwards-compatible and safe to apply even if mem_edge is unpopulated.
--
-- Operator actions required post-upgrade (not applied automatically):
--   ALTER SYSTEM SET pgmnemo.recency_weight = '0.08';  -- or ablation-confirmed value
--   ALTER SYSTEM SET pgmnemo.ef_search = '100';
--   SELECT pg_reload_conf();
--
-- NOTE: The content of pgmnemo--0.2.0-step4-recall-mixin.sql is incorporated here (F3).
-- That file is preserved on disk as a development reference only.

-- ─────────────────────────────────────────────────────────────────────────────
-- F2: Seed pgmnemo.ef_search GUC default = 100
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM set_config('pgmnemo.ef_search', '100', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL; -- fail-open: harmless if GUC infra unavailable
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F1: Seed recency_weight GUC default change (0.2 → 0.08)
-- Pending ablation confirmation from REC-1 (γ ∈ {0.20, 0.10, 0.05, 0.00} × ef_search ∈ {40, 100})
-- If ablation yields a different optimum, operator should run:
--   ALTER SYSTEM SET pgmnemo.recency_weight = '<ablation-value>';
--   SELECT pg_reload_conf();
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM set_config('pgmnemo.recency_weight', '0.08', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL; -- fail-open
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F3 + F2: recall_lessons() with ef_search SET LOCAL + graph_proximity mixin
-- Folded from pgmnemo--0.2.0-step4-recall-mixin.sql (was supplemental-only)
-- Adds ef_search SET LOCAL at function entry (F2)
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
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
BEGIN
    -- F2: Read ef_search GUC and SET LOCAL before ANN candidate query
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT,
            100
        );
        -- Clamp to safe range [10, 500]
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL; -- fail-open: proceed with whatever ef_search is already set
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
    'Hybrid recall v0.2.1 — formula: '
    '0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity. '
    'graph_proximity = MAX(1 - depth/max_depth) over causal+temporal+derives_from BFS '
    'from top-5 cosine anchors (max_depth=5). '
    'γ = pgmnemo.recency_weight (default 0.08 in v0.2.1, was 0.2). '
    'ef_search = pgmnemo.ef_search GUC (default 100, applied via SET LOCAL). '
    'δ = pgmnemo.graph_proximity_weight (default 0.2, range 0.0–0.5). '
    'prov_strength: 1.0=commit+verified, 0.4=commit-only, 0.0=no provenance. '
    'role=NULL returns all roles pooled.';

-- ─────────────────────────────────────────────────────────────────────────────
-- F5: traverse_causal_chain(direction TEXT) — P2, backwards-compatible
-- Adds direction parameter with default 'forward' (existing behaviour unchanged)
-- Gate: useful only when pgmnemo.mem_edge has rows. Apply regardless — no harm if empty.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.traverse_causal_chain(
    start_id        BIGINT,
    max_depth       INT     DEFAULT 5,
    relation_types  TEXT[]  DEFAULT ARRAY['CAUSED_BY'],
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
        -- Seed: the starting lesson
        SELECT
            start_id,
            0,
            ARRAY[start_id],
            1.0::REAL

        UNION ALL

        -- Forward: source → target
        SELECT
            me.target_id,
            cw.depth + 1,
            cw.path || me.target_id,
            cw.path_weight * COALESCE(me.weight, 1.0)
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON me.source_id = cw.lesson_id
        WHERE direction IN ('forward', 'both')
          AND me.relation_type = ANY(relation_types)
          AND cw.depth < max_depth
          AND NOT (me.target_id = ANY(cw.path))

        UNION ALL

        -- Backward: target → source
        SELECT
            me.source_id,
            cw.depth + 1,
            cw.path || me.source_id,
            cw.path_weight * COALESCE(me.weight, 1.0)
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON me.target_id = cw.lesson_id
        WHERE direction IN ('backward', 'both')
          AND me.relation_type = ANY(relation_types)
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
    'BFS traversal of causal edges in pgmnemo.mem_edge. '
    'direction: ''forward'' (source→target), ''backward'' (target→source), ''both''. '
    'relation_types: edge types to follow (default CAUSED_BY). '
    'Cycle guard via path array. '
    'New in v0.2.1: direction parameter (backwards-compatible default ''forward'').';

-- ─────────────────────────────────────────────────────────────────────────────
-- Update step4 file header note (add note that content is now in v0.2.1)
-- This is a documentation-only comment; no SQL action needed.
-- Operator: optionally add the following comment to the top of
-- extension/pgmnemo--0.2.0-step4-recall-mixin.sql:
--   "NOTE: Content of this file is incorporated into pgmnemo--0.2.0.1--0.2.1.sql.
--    Preserved as development reference only. NOT part of the upgrade chain."
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Q5: Row-Level Security — multi-tenant isolation for agent_lesson + mem_edge
--
-- GUC  pgmnemo.tenant_id (TEXT, session-scoped)
--   SET pgmnemo.tenant_id = '9';           -- restrict to project_id = 9
--   SET pgmnemo.tenant_id = '';            -- or leave unset → no restriction (superuser/service)
--
-- agent_lesson policy:
--   USING: project_id::text = tenant_id, OR tenant_id IS NULL / empty (bypass)
--
-- mem_edge policy:
--   USING: at least one endpoint (source or target) belongs to the allowed tenant.
--   Implemented via an EXISTS sub-select against agent_lesson with the same policy.
--
-- Policies are PERMISSIVE (default) and apply to SELECT, INSERT, UPDATE, DELETE.
-- Superusers bypass RLS unconditionally (standard PostgreSQL behaviour).
-- Service accounts that must bypass RLS should use BYPASSRLS privilege or connect
-- as a superuser — do NOT set tenant_id to NULL in application code.
--
-- Operator actions required post-upgrade:
--   SELECT pg_reload_conf();   -- if using ALTER SYSTEM for tenant_id seed
-- ─────────────────────────────────────────────────────────────────────────────

-- Seed the GUC default (fail-open if GUC infrastructure unavailable)
DO $$
BEGIN
    PERFORM set_config('pgmnemo.tenant_id', '', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- ── agent_lesson RLS ─────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson ENABLE ROW LEVEL SECURITY;

-- Drop policy if it already exists (idempotent re-apply)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'pgmnemo'
          AND tablename  = 'agent_lesson'
          AND policyname = 'agent_lesson_tenant_isolation'
    ) THEN
        EXECUTE 'DROP POLICY agent_lesson_tenant_isolation ON pgmnemo.agent_lesson';
    END IF;
END;
$$;

CREATE POLICY agent_lesson_tenant_isolation
    ON pgmnemo.agent_lesson
    AS PERMISSIVE
    FOR ALL
    USING (
        -- tenant_id GUC not set / empty → no restriction (service-account bypass)
        COALESCE(current_setting('pgmnemo.tenant_id', TRUE), '') = ''
        OR
        -- project_id matches the session tenant
        project_id::TEXT = current_setting('pgmnemo.tenant_id', TRUE)
    );

COMMENT ON POLICY agent_lesson_tenant_isolation ON pgmnemo.agent_lesson IS
    'Multi-tenant row isolation by project_id. '
    'SET pgmnemo.tenant_id = ''<id>'' to restrict the session to that project. '
    'Empty or unset tenant_id bypasses the policy (service-account mode). '
    'Added in pgmnemo v0.2.1 (Q5).';

-- ── mem_edge RLS ─────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.mem_edge ENABLE ROW LEVEL SECURITY;

-- Drop policy if it already exists (idempotent re-apply)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'pgmnemo'
          AND tablename  = 'mem_edge'
          AND policyname = 'mem_edge_tenant_isolation'
    ) THEN
        EXECUTE 'DROP POLICY mem_edge_tenant_isolation ON pgmnemo.mem_edge';
    END IF;
END;
$$;

CREATE POLICY mem_edge_tenant_isolation
    ON pgmnemo.mem_edge
    AS PERMISSIVE
    FOR ALL
    USING (
        -- tenant_id GUC not set / empty → no restriction
        COALESCE(current_setting('pgmnemo.tenant_id', TRUE), '') = ''
        OR
        -- at least one endpoint belongs to a lesson the tenant may see
        EXISTS (
            SELECT 1 FROM pgmnemo.agent_lesson al
            WHERE al.id IN (source_id, target_id)
              AND (
                  COALESCE(current_setting('pgmnemo.tenant_id', TRUE), '') = ''
                  OR al.project_id::TEXT = current_setting('pgmnemo.tenant_id', TRUE)
              )
        )
    );

COMMENT ON POLICY mem_edge_tenant_isolation ON pgmnemo.mem_edge IS
    'Multi-tenant row isolation: visible when source or target lesson belongs to the session tenant. '
    'SET pgmnemo.tenant_id = ''<id>'' to restrict the session. '
    'Empty / unset tenant_id bypasses the policy (service-account mode). '
    'Added in pgmnemo v0.2.1 (Q5).';
