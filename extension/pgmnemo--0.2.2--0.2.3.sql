-- pgmnemo upgrade: 0.2.2 → 0.2.3
-- HyperMem Stage-1 topic-tier coarse routing (PAPER C-2 restore).
-- Adds mem_topic table, topic_id FK on agent_lesson, classify_topic(),
-- recompute_topic_centroids(), assign_lesson_topics(), and updates
-- recall_lessons() with Stage-1 coarse-routing + global fallback.
-- SPDX-License-Identifier: Apache-2.0
--
-- Migration: v0.2.3_001
-- Task: RESTORE-C2-HYPERMEM
--
-- Design:
--   Stage-1: classify_topic(query_embedding) → topic_id via nearest centroid.
--   If topic_id found, restrict ANN candidates to that topic partition.
--   If no match (distance > threshold, empty mem_topic, or NULL embedding),
--   fall back to global search (no partition filter).
--   Centroids are recomputed nightly via recompute_topic_centroids() background job.
--
-- Evidence threshold: 10+ topics auto-discovered from corpus;
-- topic-restricted recall on cross-topic queries has higher precision than
-- global recall (partition filter eliminates cross-topic false positives).

-- ─────────────────────────────────────────────────────────────────────────────
-- S1: mem_topic table — topic centroids for coarse routing
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgmnemo.mem_topic (
    id                  SERIAL       PRIMARY KEY,
    topic_name          TEXT         NOT NULL,
    centroid            vector(1024),
    lesson_count        INT          NOT NULL DEFAULT 0,
    last_recomputed_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT uq_mem_topic_name UNIQUE (topic_name)
);

COMMENT ON TABLE pgmnemo.mem_topic IS
    'Topic centroids for HyperMem Stage-1 coarse routing. '
    'Each row represents a discovered topic cluster: centroid is the mean '
    'embedding of all active lessons sharing that topic string. '
    'Repopulated by recompute_topic_centroids() (run nightly). '
    'classify_topic() uses cosine distance from query to centroid to route '
    'recall_lessons() into a topic partition (or fall back to global search).';

COMMENT ON COLUMN pgmnemo.mem_topic.topic_name IS
    'Canonical topic string — matches agent_lesson.topic (case-sensitive).';
COMMENT ON COLUMN pgmnemo.mem_topic.centroid IS
    'Mean embedding of all active lessons in this topic. NULL until first recompute.';
COMMENT ON COLUMN pgmnemo.mem_topic.lesson_count IS
    'Number of active lessons contributing to this centroid.';
COMMENT ON COLUMN pgmnemo.mem_topic.last_recomputed_at IS
    'Timestamp of the last centroid recompute for this topic.';

CREATE INDEX IF NOT EXISTS ix_mem_topic_centroid
    ON pgmnemo.mem_topic USING hnsw (centroid vector_cosine_ops)
    WITH (m=8, ef_construction=32)
    WHERE centroid IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- S2: Add topic_id FK column to agent_lesson
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'pgmnemo'
          AND table_name   = 'agent_lesson'
          AND column_name  = 'topic_id'
    ) THEN
        ALTER TABLE pgmnemo.agent_lesson
            ADD COLUMN topic_id INT
                REFERENCES pgmnemo.mem_topic(id) ON DELETE SET NULL;
    END IF;
END;
$$;

COMMENT ON COLUMN pgmnemo.agent_lesson.topic_id IS
    'FK to pgmnemo.mem_topic.id — assigned by assign_lesson_topics(). '
    'NULL = not yet classified or no matching topic centroid. '
    'Used by recall_lessons() Stage-1 to restrict ANN to topic partition.';

CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_topic_id
    ON pgmnemo.agent_lesson (topic_id)
    WHERE topic_id IS NOT NULL AND is_active;

-- ─────────────────────────────────────────────────────────────────────────────
-- S3: classify_topic() — nearest centroid lookup, returns topic_id or NULL
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.classify_topic(
    query_embedding  vector(1024),
    threshold        DOUBLE PRECISION DEFAULT 0.5
)
RETURNS INT
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _topic_id INT;
    _distance DOUBLE PRECISION;
BEGIN
    -- NULL embedding → no topic classification possible
    IF query_embedding IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT mt.id,
           (mt.centroid <=> query_embedding)::DOUBLE PRECISION
    INTO   _topic_id, _distance
    FROM   pgmnemo.mem_topic mt
    WHERE  mt.centroid IS NOT NULL
    ORDER BY mt.centroid <=> query_embedding
    LIMIT 1;

    -- No topics in table, or nearest centroid too far → global fallback
    IF NOT FOUND OR _distance > threshold THEN
        RETURN NULL;
    END IF;

    RETURN _topic_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.classify_topic(vector, DOUBLE PRECISION) IS
    'Stage-1 coarse router: find the nearest mem_topic centroid by cosine distance. '
    'Returns topic_id when distance <= threshold (default 0.5); NULL otherwise. '
    'NULL return triggers global-search fallback in recall_lessons(). '
    'NULL query_embedding always returns NULL (safe no-op). '
    'GUC override: pgmnemo.topic_distance_threshold (applied by callers).';

-- ─────────────────────────────────────────────────────────────────────────────
-- S4: recompute_topic_centroids() — background job; groups lessons by topic
--     string and upserts the mean embedding into mem_topic
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.recompute_topic_centroids()
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    _count INT;
BEGIN
    WITH topic_stats AS (
        SELECT
            al.topic                  AS topic_name,
            COUNT(*)::INT             AS lesson_count,
            AVG(al.embedding)         AS centroid
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.embedding IS NOT NULL
        GROUP BY al.topic
    )
    INSERT INTO pgmnemo.mem_topic (topic_name, centroid, lesson_count, last_recomputed_at)
    SELECT topic_name, centroid, lesson_count, NOW()
    FROM   topic_stats
    ON CONFLICT (topic_name) DO UPDATE
        SET centroid           = EXCLUDED.centroid,
            lesson_count       = EXCLUDED.lesson_count,
            last_recomputed_at = NOW();

    GET DIAGNOSTICS _count = ROW_COUNT;
    RETURN COALESCE(_count, 0);
END;
$$;

COMMENT ON FUNCTION pgmnemo.recompute_topic_centroids() IS
    'Recomputes topic centroids: groups active lessons by topic string, '
    'computes mean embedding per group, upserts into mem_topic. '
    'Returns the number of topics upserted. '
    'Intended as a nightly background job (pg_cron or external scheduler). '
    'Safe to call at any time; no lock escalation beyond row-level.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S5: assign_lesson_topics() — bulk-assign topic_id to existing lessons
--     using current classify_topic() logic
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.assign_lesson_topics(
    threshold DOUBLE PRECISION DEFAULT 0.5
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    _count INT;
BEGIN
    UPDATE pgmnemo.agent_lesson
    SET    topic_id = pgmnemo.classify_topic(embedding, threshold)
    WHERE  is_active
      AND  embedding IS NOT NULL;

    GET DIAGNOSTICS _count = ROW_COUNT;
    RETURN COALESCE(_count, 0);
END;
$$;

COMMENT ON FUNCTION pgmnemo.assign_lesson_topics(DOUBLE PRECISION) IS
    'Bulk-assigns topic_id to all active lessons that have an embedding. '
    'Calls classify_topic() per lesson — run after recompute_topic_centroids(). '
    'Returns the number of lessons updated (including those set to NULL). '
    'threshold parameter forwarded to classify_topic (default 0.5).';

-- ─────────────────────────────────────────────────────────────────────────────
-- S6: GUC: pgmnemo.topic_distance_threshold (default 0.5)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM set_config('pgmnemo.topic_distance_threshold', '0.5', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- S7: recall_lessons() — add Stage-1 topic routing (v0.2.3)
--     Stage-1: classify_topic(query_embedding) → _routed_topic_id
--     When _routed_topic_id IS NOT NULL: restrict candidates to topic partition.
--     Fallback: _routed_topic_id IS NULL → global search (no partition filter).
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
    _ef_search            INT;
    _include_unverified   BOOLEAN;
    _tsquery              TSQUERY;
    _has_text             BOOLEAN;
    _gamma                DOUBLE PRECISION;
    _graph_weight         DOUBLE PRECISION;
    _topic_threshold      DOUBLE PRECISION;
    _routed_topic_id      INT;
    _max_depth            CONSTANT INT := 5;
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

    -- Stage-1: classify query into a topic partition (coarse routing)
    BEGIN
        _topic_threshold := COALESCE(
            NULLIF(current_setting('pgmnemo.topic_distance_threshold', TRUE), '')::DOUBLE PRECISION,
            0.5
        );
    EXCEPTION WHEN OTHERS THEN
        _topic_threshold := 0.5;
    END;

    _routed_topic_id := pgmnemo.classify_topic(query_embedding, _topic_threshold);
    -- NULL → global fallback (no partition restriction)

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
                WHEN al.embedding IS NOT NULL AND query_embedding IS NOT NULL
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
          AND (recall_lessons.role_filter        IS NULL OR al.role       = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter  IS NULL OR al.project_id = recall_lessons.project_id_filter)
          -- Stage-1: topic partition filter; NULL _routed_topic_id = global fallback
          AND (_routed_topic_id IS NULL OR al.topic_id = _routed_topic_id)
          AND (al.embedding IS NOT NULL OR _has_text)
    ),
    anchors AS (
        SELECT id
        FROM candidates
        ORDER BY vec_score DESC
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
    'Hybrid recall v0.2.3 — HyperMem Stage-1 topic routing (C-2 restore). '
    'Stage-1: classify_topic(query_embedding, topic_distance_threshold) → topic_id. '
    'When topic_id is found: candidates restricted to that topic partition (higher precision). '
    'When topic_id is NULL (no match or empty mem_topic): global search (full fallback). '
    'Score formula: 0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity. '
    'γ = pgmnemo.recency_weight (default 0.08). '
    'δ = pgmnemo.graph_proximity_weight (default 0.2, range 0.0–0.5). '
    'topic_distance_threshold = pgmnemo.topic_distance_threshold GUC (default 0.5). '
    'ef_search = pgmnemo.ef_search GUC (default 100, applied via SET LOCAL). '
    'Run recompute_topic_centroids() + assign_lesson_topics() to populate topic partitions.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S8: Version bump
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.version()
RETURNS TEXT
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT '0.2.3'::TEXT;
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the installed pgmnemo extension version. '
    'v0.2.3: HyperMem Stage-1 topic-tier coarse routing (PAPER C-2 restore).';
