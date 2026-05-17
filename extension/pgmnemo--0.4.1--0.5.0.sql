-- pgmnemo--0.4.1--0.5.0.sql
-- Migration: v0.4.1 → v0.5.0
--
-- Scope:
--   §A  R10 — Remove 4-arg traverse_causal_chain() overload (deprecated v0.4.1)
--   §B  H-06 — pgmnemo.temporal_boost GUC + get_temporal_boost() helper
--   §C  R5  — pgmnemo.max_query_text_chars GUC
--   §D  recall_lessons() — H-06 temporal_boost + R5 query_text truncation
--   §E  H-07 — Bitemporality (t_valid_from/t_valid_to/content_hash + trigger + view + as_of)
--   §F  ingest() — R5 lesson_text truncation guard
--   §G  R6  — pgmnemo.add_edge() idempotent edge upsert helper
--
-- All DDL is idempotent (IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS).
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- §A  R10: Remove 4-arg traverse_causal_chain() overload (deprecated v0.4.1)
--
-- The 4-arg form traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN) was
-- superseded by the 5-arg form (direction parameter added in v0.2.1).
-- Formally deprecated in v0.4.1; removed here in v0.5.0.
-- The 5-arg form traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN, TEXT)
-- is unchanged and remains the canonical interface.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);

-- ─────────────────────────────────────────────────────────────────────────────
-- §B  H-06: pgmnemo.temporal_boost GUC + get_temporal_boost() helper
--
-- pgmnemo.temporal_boost (FLOAT, default 1.0, range 0.0–5.0):
--   Score multiplier for the recency component of recall_lessons().
--   effective_γ = pgmnemo.recency_weight × pgmnemo.temporal_boost
--   Default: 0.05 × 1.0 = 0.05 — backward compatible with v0.4.1.
--   H-06 optimal (cell C6): SET pgmnemo.temporal_boost = '10.0'
--     to reach effective_γ ≈ 0.5 with default recency_weight=0.05.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM set_config('pgmnemo.temporal_boost', '1.0', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

CREATE OR REPLACE FUNCTION pgmnemo.get_temporal_boost()
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _v DOUBLE PRECISION;
BEGIN
    _v := COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    );
    RETURN GREATEST(0.0, LEAST(20.0, _v));
END;
$$;

COMMENT ON FUNCTION pgmnemo.get_temporal_boost() IS
    'Returns pgmnemo.temporal_boost GUC (default 1.0, range 0.0–20.0). '
    'Score multiplier: effective_γ = recency_weight × temporal_boost. '
    'H-06 optimal (C6): boost=10 with rw=0.05 → effective_γ=0.5; max boost=20 for aggressive recency. '
    'H-06 (v0.5.0).';

-- ─────────────────────────────────────────────────────────────────────────────
-- §C  R5: pgmnemo.max_query_text_chars GUC
--
-- Limits query_text in recall_lessons() and lesson_text in ingest().
-- Default 2000 chars. Long text is truncated with RAISE NOTICE.
-- Set to 0 or negative to disable truncation entirely.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM set_config('pgmnemo.max_query_text_chars', '2000', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §D  recall_lessons() — H-06 temporal_boost + R5 query_text cap
--
-- Changes from v0.4.1:
--   H-06: effective_γ = pgmnemo.recency_weight × pgmnemo.temporal_boost
--         (backward-compatible default 0.05 × 1.0 = 0.05).
--   R5:   query_text truncated to pgmnemo.max_query_text_chars (default 2000)
--         before ts_query/embedding use; RAISE NOTICE on truncation.
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
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
BEGIN
    -- R5: clamp query_text to pgmnemo.max_query_text_chars (default 2000).
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

    IF NOT _disable_hybrid
       AND _query_text IS NOT NULL
       AND length(trim(_query_text)) > 0
       AND query_embedding IS NOT NULL THEN
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
            _query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,
            0.4,
            60
        ) h;
        RETURN;
    END IF;

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

    -- Base recency weight γ (backward compat default 0.05).
    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.05
    );

    -- H-06: effective_γ = _gamma × temporal_boost (range 0.0–20.0, default 1.0).
    _temporal_boost := GREATEST(0.0, LEAST(20.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    )));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

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
    'v0.5.0 hybrid router with temporal_boost GUC (H-06) and query_text cap (R5). '
    'Routes to recall_hybrid() when query_text non-empty AND embedding present '
    'AND pgmnemo.disable_hybrid is FALSE/unset. '
    'R5: query_text truncated to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'H-06: effective_γ = recency_weight × temporal_boost (defaults 0.05 × 1.0 = 0.05). '
    'Diagnostic cols: vec_score=cosine; bm25_score/rrf_score=NULL on vector-only path.';

-- ─────────────────────────────────────────────────────────────────────────────
-- §E  H-07: Bitemporality primitive on agent_lesson (v0.5.0)
--
-- Adds valid-time columns (t_valid_from, t_valid_to) + computed dedup key
-- (content_hash) to pgmnemo.agent_lesson.  All DDL is idempotent.
-- Active rows: t_valid_to = 'infinity'.
-- On INSERT of a row with the same content_hash, trigger closes the prior.
-- pgmnemo.mem_item: active-only view alias.
-- pgmnemo.as_of(ts): point-in-time query.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS t_valid_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS t_valid_to    TIMESTAMPTZ NOT NULL DEFAULT 'infinity'::TIMESTAMPTZ;

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS content_hash  TEXT GENERATED ALWAYS AS (
        MD5(
            COALESCE(role,        '') || '|' ||
            COALESCE(topic,       '') || '|' ||
            COALESCE(commit_sha, COALESCE(artifact_hash, ''))
        )
    ) STORED;

COMMENT ON COLUMN pgmnemo.agent_lesson.t_valid_from IS
    'Valid-time start. Defaults to row creation; backfilled to created_at for pre-H-07 rows. H-07 (v0.5.0).';
COMMENT ON COLUMN pgmnemo.agent_lesson.t_valid_to IS
    '''infinity'' = currently active row. Set to now() by trigger on conflicting insert. H-07 (v0.5.0).';
COMMENT ON COLUMN pgmnemo.agent_lesson.content_hash IS
    'MD5(role|topic|commit_sha_or_artifact_hash). Computed dedup key for bitemporal trigger. H-07 (v0.5.0).';

-- Backfill: existing rows get t_valid_from = created_at.
-- WHERE guard: only rows whose t_valid_from was just set to now() by the ADD COLUMN DEFAULT.
UPDATE pgmnemo.agent_lesson
SET    t_valid_from = created_at
WHERE  t_valid_from >= (now() - INTERVAL '1 second');

CREATE INDEX IF NOT EXISTS ix_agent_lesson_valid_range
    ON pgmnemo.agent_lesson (t_valid_from, t_valid_to)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_hash_active
    ON pgmnemo.agent_lesson (content_hash)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION pgmnemo._bitemporal_close_prior()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.content_hash IS NOT NULL THEN
        UPDATE pgmnemo.agent_lesson
        SET    t_valid_to = now()
        WHERE  content_hash = NEW.content_hash
          AND  t_valid_to   = 'infinity'::TIMESTAMPTZ
          AND  id           <> NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_agent_lesson_bitemporal_close ON pgmnemo.agent_lesson;
CREATE TRIGGER trg_agent_lesson_bitemporal_close
    AFTER INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW
    EXECUTE FUNCTION pgmnemo._bitemporal_close_prior();

CREATE OR REPLACE VIEW pgmnemo.mem_item AS
    SELECT * FROM pgmnemo.agent_lesson
    WHERE  t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON VIEW pgmnemo.mem_item IS
    'Active-only alias for pgmnemo.agent_lesson (t_valid_to = infinity). H-07 (v0.5.0).';

CREATE OR REPLACE FUNCTION pgmnemo.as_of(ts TIMESTAMPTZ)
RETURNS SETOF pgmnemo.agent_lesson
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT *
    FROM   pgmnemo.agent_lesson
    WHERE  t_valid_from <= ts
      AND  t_valid_to   >  ts;
$$;

COMMENT ON FUNCTION pgmnemo.as_of(TIMESTAMPTZ) IS
    'Time-travel: rows active at ts (t_valid_from <= ts < t_valid_to). H-07 (v0.5.0).';

-- ─────────────────────────────────────────────────────────────────────────────
-- §F  R5: ingest() — lesson_text truncation guard
--
-- Replaces v0.4.1 ingest() with R5 truncation on p_lesson_text.
-- NULL/empty lesson_text: RAISE NOTICE then proceed to DB constraint.
-- Truncation threshold: pgmnemo.max_query_text_chars (default 2000).
-- Set GUC to 0 or negative to disable.
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
    new_id      BIGINT;
    _max_chars  INT;
BEGIN
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

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
    ) RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API (v0.5.0 + R5). '
    'Truncates p_lesson_text to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'NULL/empty p_lesson_text: emits NOTICE, proceeds to DB constraint. '
    'Set GUC to 0 or negative to disable truncation. R5 (v0.5.0).';

-- ─────────────────────────────────────────────────────────────────────────────
-- §G  R6: pgmnemo.add_edge() — idempotent edge upsert helper (v0.5.0)
--
-- Convenience wrapper for INSERT ... ON CONFLICT on pgmnemo.mem_edge.
-- On conflict on (source_id, target_id, relation_type WHERE valid_until IS NULL),
-- updates weight and metadata per p_mode.
--
-- Parameters:
--   p_source_id     BIGINT  — FK → pgmnemo.agent_lesson.id (NOT NULL enforced by table)
--   p_target_id     BIGINT  — FK → pgmnemo.agent_lesson.id (NOT NULL enforced by table)
--   p_relation_type TEXT    — e.g. CAUSED_BY, CO_OCCURRED, DERIVED_FROM, ENTITY_LINK
--   p_weight        FLOAT8  — clamped to [0.0, 1.0], default 1.0
--   p_metadata      JSONB   — default '{}'
--   p_mode          TEXT    — 'replace' (default) | 'max' | 'avg'
--
-- edge_kind auto-derived from p_relation_type (SQL_REFERENCE §1.1 canonical mapping).
-- NULL p_source_id / p_target_id → NOT NULL constraint violation from mem_edge.
-- Unknown id → FK constraint violation from mem_edge.
-- ─────────────────────────────────────────────────────────────────────────────

-- Partial unique index enabling ON CONFLICT for active-edge upsert.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mem_edge_active
    ON pgmnemo.mem_edge (source_id, target_id, relation_type)
    WHERE valid_until IS NULL;

CREATE OR REPLACE FUNCTION pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}'::jsonb,
    p_mode          TEXT    DEFAULT 'replace'
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _edge_kind pgmnemo.edge_kind;
    _weight    REAL := GREATEST(0.0, LEAST(1.0, COALESCE(p_weight, 1.0)));
BEGIN
    _edge_kind := CASE
        WHEN p_relation_type IN ('CAUSED_BY', 'DERIVED_FROM', 'CONTRADICTS')
            THEN 'causal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('CO_OCCURRED', 'PRECEDED_BY')
            THEN 'temporal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('ENTITY_LINK', 'SHARED_TAG', 'IS_A', 'PART_OF')
            THEN 'entity'::pgmnemo.edge_kind
        ELSE 'semantic'::pgmnemo.edge_kind
    END;

    IF p_mode NOT IN ('replace', 'max', 'avg') THEN
        RAISE EXCEPTION
            'pgmnemo.add_edge: unknown mode ''%'' — valid values: replace, max, avg',
            p_mode;
    END IF;

    IF p_mode = 'max' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind,
             _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = GREATEST(pgmnemo.mem_edge.weight, EXCLUDED.weight),
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();

    ELSIF p_mode = 'avg' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind,
             _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = (pgmnemo.mem_edge.weight + EXCLUDED.weight) / 2.0,
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();

    ELSE
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind,
             _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = EXCLUDED.weight,
            metadata   = EXCLUDED.metadata,
            updated_at = now();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.add_edge(BIGINT, BIGINT, TEXT, FLOAT8, JSONB, TEXT) IS
    'Idempotent edge upsert helper (R6, v0.5.0). '
    'Inserts or updates a directed typed edge in pgmnemo.mem_edge. '
    'edge_kind auto-derived from p_relation_type (SQL_REFERENCE §1.1). '
    'Conflict on uq_mem_edge_active (source_id, target_id, relation_type WHERE valid_until IS NULL). '
    'p_mode: ''replace'' (last-writer-wins) | ''max'' (monotonic weight) | ''avg'' (running mean). '
    'p_weight clamped to [0.0, 1.0]. '
    'NULL source_id/target_id → NOT NULL violation; unknown id → FK violation. R6 (v0.5.0).';
