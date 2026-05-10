-- pgmnemo upgrade: 0.3.0 → 0.3.1 (MAGMA-3 — Adaptive Traversal Policy)
-- Adds pgmnemo.classify_query_intent() + wires intent routing into recall_lessons().
-- SPDX-License-Identifier: Apache-2.0
--
-- Migration: v0.3.1_001
-- Task: MAGMA-3 — query intent classifier + per-graph routing
--
-- Design:
--   1. query_intent ENUM  : factual | temporal | causal | entity
--   2. intent_prototype   : one centroid row per intent class (1024-dim)
--   3. classify_query_intent(vector) : nearest-centroid cosine, fallback='factual'
--   4. recall_lessons() updated:
--        factual  → graph_weight=0.0, gamma unchanged, no BFS
--        temporal → gamma×2 (cap 0.4), graph_weight unchanged, edge_kinds={temporal}
--        causal   → graph_weight×1.5 (cap 0.5), gamma unchanged, edge_kinds={causal}
--        entity   → all unchanged, edge_kinds={causal,temporal,entity}

-- ─────────────────────────────────────────────────────────────────────────────
-- S1: query_intent ENUM
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pgmnemo' AND t.typname = 'query_intent'
    ) THEN
        CREATE TYPE pgmnemo.query_intent AS ENUM ('factual', 'temporal', 'causal', 'entity');
    END IF;
END;
$$;

COMMENT ON TYPE pgmnemo.query_intent IS
    'MAGMA-3 query intent class. '
    'factual: single/multi-hop fact lookup — no graph traversal. '
    'temporal: time-ordering/duration/recency — gamma boosted, temporal edges only. '
    'causal: cause-effect/counterfactual/chain — graph_weight boosted, causal edges only. '
    'entity: entity attribute/relationship — all edge kinds traversed.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S2: intent_prototype table — one centroid per intent class
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgmnemo.intent_prototype (
    intent      pgmnemo.query_intent PRIMARY KEY,
    centroid    vector(1024)         NOT NULL,
    description TEXT,
    updated_at  TIMESTAMPTZ          NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE pgmnemo.intent_prototype IS
    'MAGMA-3: one centroid embedding per query_intent class. '
    'Populated by operator via INSERT or the seed script. '
    'classify_query_intent() selects the intent with minimum cosine distance to query_embedding.';

CREATE INDEX IF NOT EXISTS ix_intent_prototype_intent
    ON pgmnemo.intent_prototype (intent);

-- ─────────────────────────────────────────────────────────────────────────────
-- S3: classify_query_intent() — nearest-centroid with 'factual' fallback
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.classify_query_intent(
    query_embedding vector(1024)
)
RETURNS pgmnemo.query_intent
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT COALESCE(
        (
            SELECT intent
            FROM pgmnemo.intent_prototype
            ORDER BY centroid <=> query_embedding ASC
            LIMIT 1
        ),
        'factual'::pgmnemo.query_intent
    )
$$;

COMMENT ON FUNCTION pgmnemo.classify_query_intent(vector) IS
    'MAGMA-3 nearest-centroid intent classifier. '
    'Selects the intent_prototype row with minimum cosine distance (pgvector <=> operator) to query_embedding. '
    'Falls back to ''factual'' when intent_prototype table is empty (safe default — no graph overhead). '
    'Accuracy target: ≥70% on 10-query LongMemEval-style benchmark (MAGMA-3 acceptance criterion). '
    'Caller: recall_lessons() uses this to route _graph_weight, _gamma, and edge_kind filter.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S4: recall_lessons() v0.3.1 — intent-adaptive traversal routing
--     Builds on v0.3.0 (edge_kind ENUM BFS fix).
--     New: classify_query_intent() call + per-intent weight/edge routing.
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
    _intent             pgmnemo.query_intent;
    _edge_kinds         pgmnemo.edge_kind[];
    _max_depth          CONSTANT INT := 5;
BEGIN
    -- ef_search GUC
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

    -- include_unverified GUC
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- recency_weight GUC
    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.08
    );

    -- graph_proximity_weight GUC
    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    -- ── MAGMA-3: classify intent and route traversal parameters ──────────────
    _intent := pgmnemo.classify_query_intent(query_embedding);

    CASE _intent
        WHEN 'factual' THEN
            -- No graph traversal for fact lookups; BFS would add noise.
            _graph_weight := 0.0;
            _edge_kinds   := ARRAY[]::pgmnemo.edge_kind[];

        WHEN 'temporal' THEN
            -- Boost recency signal; restrict traversal to time-ordered edges.
            _gamma      := LEAST(_gamma * 2.0, 0.4);
            _edge_kinds := ARRAY['temporal'::pgmnemo.edge_kind];

        WHEN 'causal' THEN
            -- Amplify graph signal for cause-effect chains; causal edges only.
            _graph_weight := LEAST(_graph_weight * 1.5, 0.5);
            _edge_kinds   := ARRAY['causal'::pgmnemo.edge_kind];

        WHEN 'entity' THEN
            -- Full multi-graph traversal; all edge kinds contribute.
            _edge_kinds := ARRAY['causal','temporal','entity']::pgmnemo.edge_kind[];

        ELSE
            -- Defensive fallback — treat as factual.
            _graph_weight := 0.0;
            _edge_kinds   := ARRAY[]::pgmnemo.edge_kind[];
    END CASE;
    -- ─────────────────────────────────────────────────────────────────────────

    -- query_text → tsquery
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
    -- BFS through intent-routed edge kinds (MAGMA-3: parameterised by _edge_kinds)
    -- When _edge_kinds is empty (factual intent), no rows pass the ANY() filter.
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id
        FROM anchors

        UNION ALL

        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind = ANY(_edge_kinds)
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
    'Hybrid recall v0.3.1 — MAGMA-3 adaptive traversal policy. '
    'Formula: 0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity. '
    'Intent routing via classify_query_intent(): '
    '  factual  → δ=0.0,          γ unchanged, no BFS. '
    '  temporal → δ unchanged,     γ=min(γ×2,0.4), BFS on temporal edges. '
    '  causal   → δ=min(δ×1.5,0.5), γ unchanged,  BFS on causal edges. '
    '  entity   → δ unchanged,     γ unchanged, BFS on causal+temporal+entity edges. '
    'γ = pgmnemo.recency_weight GUC (default 0.08). '
    'δ = pgmnemo.graph_proximity_weight GUC (default 0.2, range 0.0–0.5). '
    'ef_search = pgmnemo.ef_search GUC (default 100). '
    'Signature unchanged from v0.3.0 — full backward compatibility.';
