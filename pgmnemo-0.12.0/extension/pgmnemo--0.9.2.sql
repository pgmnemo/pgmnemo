-- pgmnemo--0.9.2.sql
-- Flat install: pgmnemo v0.9.2
-- SPDX-License-Identifier: Apache-2.0
--
-- Squashes the full upgrade chain 0.0.1 → 0.9.2 into a single idempotent DDL file.
-- v0.9.2: D1 reinforce() base-rate-adjusted deltas (+0.02/-0.12) + GUC-configurable;
--         I1 flag-gated confidence-weighted recall ranking (pgmnemo.confidence_boost_weight).
-- v0.9.1: navigate_expand + navigate_locate graph traversal fix (P0):
--         relation_type filter replaces broken edge_kind filter,
--         bidirectional BFS, threshold 0.7→0.5, valid_until sentinel,
--         navigate_locate topic_tsv stored column for BM25.
-- v0.9.0: #1 budget-counter fix, #1b project_id_filter on navigate_locate,
--         #2 NULL-embedding auto-verify, #3 content_type/blob_ref/doc_ref columns,
--         #4 recall_hybrid two bounded CTEs (O(k log n)).
-- v0.8.0: Token-economy navigation API (navigate_locate, navigate_expand) +
--         maintenance primitives (reembed, reembed_batch, recompute_content) +
--         source_type + embedding_at columns.
-- v0.7.1: BUG-1 match_confidence fix, batch reinforce, graph COMMENT.
-- Generated 2026-06-17 — do not edit manually; maintain via upgrade scripts.
-- ─────────────────────────────────────────────────────────────────────────────
\echo Use "CREATE EXTENSION pgmnemo" to load this file. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- Trigger helper: updated_at
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo._set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Trigger helper: provenance gate
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo._enforce_provenance_gate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    _gate TEXT;
BEGIN
    IF NEW.commit_sha IS NOT NULL OR NEW.artifact_hash IS NOT NULL THEN
        RETURN NEW;
    END IF;

    BEGIN
        _gate := lower(trim(coalesce(current_setting('pgmnemo.gate_strict', TRUE), '')));
        IF _gate = '' THEN
            _gate := 'enforce';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        _gate := 'enforce';
    END;

    CASE _gate
        WHEN 'enforce' THEN
            RAISE EXCEPTION
                'pgmnemo provenance gate [enforce]: INSERT rejected — '
                'commit_sha or artifact_hash is required. '
                'Recommended: supply a provenance field (the write then succeeds in any '
                'mode and keeps provenance). To relax the gate instead: '
                'SET pgmnemo.gate_strict = ''warn'' (accept with an audit warning) '
                'or ''off'' (skip the check entirely). '
                'See docs/SQL_REFERENCE.md "Disabling the provenance gate".';
        WHEN 'warn' THEN
            RAISE WARNING
                'pgmnemo provenance gate [warn]: INSERT accepted without commit_sha or artifact_hash. '
                'Row will be a ghost lesson (verified_at IS NULL) and excluded from recall by default.';
            RETURN NEW;
        ELSE
            RETURN NEW;
    END CASE;
END;
$$;

COMMENT ON FUNCTION pgmnemo._enforce_provenance_gate() IS
    'Provenance gate trigger: rejects INSERTs where both commit_sha and artifact_hash are NULL. '
    'Controlled by GUC pgmnemo.gate_strict (enforce|warn|off, default enforce).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Core table: agent_lesson (all columns from v0.0.1 through v0.3.0)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE pgmnemo.agent_lesson (
    id               BIGSERIAL    PRIMARY KEY,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- Lesson content
    role             TEXT         NOT NULL,
    project_id       INT,
    topic            TEXT         NOT NULL,
    lesson_text      TEXT         NOT NULL,
    importance       SMALLINT     NOT NULL DEFAULT 3 CHECK (importance BETWEEN 1 AND 5),

    -- Rich metadata
    metadata         JSONB,

    -- Origin (v0.0.1: TEXT; v0.1.4 index added for BIGINT semantics on source_task_id)
    source_run_id    TEXT,

    -- Provenance gate
    commit_sha       TEXT,
    artifact_hash    TEXT,
    verified_at      TIMESTAMPTZ,

    -- Full-text search vectors (generated)
    topic_tsv        TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(topic, ''))) STORED,
    lesson_tsv       TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(lesson_text, ''))) STORED,
    full_text        TSVECTOR GENERATED ALWAYS AS (
                         setweight(to_tsvector('english', coalesce(topic, '')), 'A') ||
                         setweight(to_tsvector('english', coalesce(lesson_text, '')), 'B')
                     ) STORED,

    -- Dense vector embedding (pgvector, 1024-dim)
    embedding        vector(1024),

    -- Soft-delete
    is_active        BOOLEAN      NOT NULL DEFAULT TRUE,
    resolved_at      TIMESTAMPTZ,

    -- v0.1.3: verifier provenance
    verifier_role    TEXT,

    -- v0.1.4: lifecycle state machine
    state            TEXT         NOT NULL DEFAULT 'draft'
                         CHECK (state IN ('draft','candidate','validated','canonical',
                                          'deprecated','superseded','archived','rejected','conflicted')),
    state_changed_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- v0.1.4: external-system FK (soft references, no REFERENCES constraint)
    source_task_id   BIGINT,

    -- v0.1.4: TTL
    expires_at       TIMESTAMPTZ,

    -- v0.9.0: multimodal schema (#3)
    content_type     TEXT,
    blob_ref         TEXT,
    doc_ref          TEXT
);

COMMENT ON TABLE pgmnemo.agent_lesson IS
    'Durable, provenance-gated agent lessons. '
    'Rows with verified_at IS NULL are ghost lessons excluded from recall_lessons() by default. '
    'Provenance gate enforces commit_sha OR artifact_hash presence on INSERT.';

COMMENT ON COLUMN pgmnemo.agent_lesson.metadata IS
    'Arbitrary structured context: tags, source agent config, model version, run metadata, etc.';
COMMENT ON COLUMN pgmnemo.agent_lesson.commit_sha IS
    'Git commit SHA that generated or justified this lesson.';
COMMENT ON COLUMN pgmnemo.agent_lesson.artifact_hash IS
    'SHA-256 hex of an external artifact when no git commit applies.';
COMMENT ON COLUMN pgmnemo.agent_lesson.verified_at IS
    'Timestamp at which commit_sha or artifact_hash was successfully verified. '
    'NULL = ghost lesson, excluded from recall by default.';
COMMENT ON COLUMN pgmnemo.agent_lesson.full_text IS
    'Weighted tsvector: topic (weight A) || lesson_text (weight B). '
    'Used by recall_lessons() for full-text scoring component.';
COMMENT ON COLUMN pgmnemo.agent_lesson.embedding IS
    '1024-dim dense vector embedding for semantic recall via pgvector cosine similarity.';
COMMENT ON COLUMN pgmnemo.agent_lesson.verifier_role IS
    'Role that verified the lesson (e.g. PI, automated, founder, peer). NULL = unverified or unknown.';
COMMENT ON COLUMN pgmnemo.agent_lesson.source_run_id IS
    'External run identifier (text); soft reference, no FK constraint.';
COMMENT ON COLUMN pgmnemo.agent_lesson.source_task_id IS
    'External-system FK; not REFERENCES-constrained (allows extension to be portable across host schemas).';
COMMENT ON COLUMN pgmnemo.agent_lesson.expires_at IS
    'Optional hard expiry. NULL = never expires. Rows with expires_at < NOW() are stale.';

-- ── Indexes ──────────────────────────────────────────────────────────────────

CREATE INDEX pgmnemo_agent_lesson_metadata_idx
    ON pgmnemo.agent_lesson USING GIN (metadata)
    WHERE is_active AND metadata IS NOT NULL;

CREATE INDEX pgmnemo_agent_lesson_full_text_idx
    ON pgmnemo.agent_lesson USING GIN (full_text)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_topic_tsv_idx
    ON pgmnemo.agent_lesson USING GIN (topic_tsv)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_lesson_tsv_idx
    ON pgmnemo.agent_lesson USING GIN (lesson_tsv)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_role_proj_time_idx
    ON pgmnemo.agent_lesson (role, project_id, created_at DESC)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_role_idx
    ON pgmnemo.agent_lesson (role)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_project_idx
    ON pgmnemo.agent_lesson (project_id)
    WHERE is_active AND project_id IS NOT NULL;

CREATE INDEX pgmnemo_agent_lesson_verified_idx
    ON pgmnemo.agent_lesson (verified_at)
    WHERE is_active AND verified_at IS NOT NULL;

-- HNSW index (upgraded from ivfflat in v0.1.0)
CREATE INDEX pgmnemo_agent_lesson_embedding_idx
    ON pgmnemo.agent_lesson USING hnsw (embedding vector_cosine_ops)
    WITH (m=16, ef_construction=64)
    WHERE is_active AND embedding IS NOT NULL;

-- v0.1.4 indexes for source provenance columns
CREATE INDEX ix_pgmnemo_lesson_source_task
    ON pgmnemo.agent_lesson (source_task_id)
    WHERE source_task_id IS NOT NULL;

-- v0.1.4 TTL index
CREATE INDEX ix_pgmnemo_agent_lesson_expires
    ON pgmnemo.agent_lesson (expires_at)
    WHERE expires_at IS NOT NULL;

-- ── Triggers ─────────────────────────────────────────────────────────────────

CREATE TRIGGER agent_lesson_updated_at
    BEFORE UPDATE ON pgmnemo.agent_lesson
    FOR EACH ROW EXECUTE FUNCTION pgmnemo._set_updated_at();

CREATE TRIGGER enforce_provenance_gate
    BEFORE INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW EXECUTE FUNCTION pgmnemo._enforce_provenance_gate();

-- ─────────────────────────────────────────────────────────────────────────────
-- v0.1.4: State machine — allowed-transition table
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE pgmnemo.agent_lesson_state_transition (
    from_state TEXT NOT NULL,
    to_state   TEXT NOT NULL,
    PRIMARY KEY (from_state, to_state)
);

COMMENT ON TABLE pgmnemo.agent_lesson_state_transition IS
    'Allowed state transitions for pgmnemo.agent_lesson.state lifecycle.';

INSERT INTO pgmnemo.agent_lesson_state_transition (from_state, to_state) VALUES
    ('draft',      'candidate'),
    ('draft',      'rejected'),
    ('candidate',  'validated'),
    ('candidate',  'rejected'),
    ('candidate',  'conflicted'),
    ('validated',  'canonical'),
    ('validated',  'rejected'),
    ('canonical',  'deprecated'),
    ('canonical',  'superseded'),
    ('canonical',  'archived'),
    ('canonical',  'conflicted'),
    ('deprecated', 'archived'),
    ('deprecated', 'canonical'),
    ('superseded', 'archived'),
    ('conflicted', 'canonical'),
    ('conflicted', 'rejected'),
    ('conflicted', 'archived');

-- ─────────────────────────────────────────────────────────────────────────────
-- v0.3.0: edge_kind ENUM (MAGMA §3 — temporal + entity graph schema)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TYPE pgmnemo.edge_kind AS ENUM ('semantic', 'temporal', 'causal', 'entity');

COMMENT ON TYPE pgmnemo.edge_kind IS
    'MAGMA §3 top-level edge category. '
    'causal: cause-effect (edge_type: causal, derives_from, contradicts). '
    'temporal: time-ordered co-occurrence (edge_type: temporal). '
    'semantic: meaning/knowledge relation (edge_type: semantic, elaborates, supersedes). '
    'entity: entity co-membership/reference (edge_type: entity).';

-- ─────────────────────────────────────────────────────────────────────────────
-- v0.2.0: mem_edge — directed typed edges between agent_lesson rows
-- v0.3.0: includes edge_kind ENUM column (NOT NULL, no backfill needed for fresh install)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE pgmnemo.mem_edge (
    id              BIGSERIAL       PRIMARY KEY,
    source_id       BIGINT          NOT NULL
                        REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    target_id       BIGINT          NOT NULL
                        REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    relation_type   TEXT            NOT NULL,

    -- v0.3.0: MAGMA §3 top-level category (required on all fresh inserts)
    edge_kind       pgmnemo.edge_kind NOT NULL,

    valid_from      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    valid_until     TIMESTAMPTZ,

    weight          REAL            NOT NULL DEFAULT 1.0
                        CHECK (weight BETWEEN 0.0 AND 1.0),

    commit_sha      TEXT,
    metadata        JSONB,

    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_mem_edge UNIQUE (source_id, target_id, relation_type, valid_from),
    CONSTRAINT ck_no_self_loop CHECK (source_id <> target_id)
);

COMMENT ON TABLE pgmnemo.mem_edge IS
    'Multi-graph relations between lessons. '
    'v0.2.0: initial schema. v0.3.0: edge_kind ENUM (MAGMA §3) + per-kind partial indexes.';

COMMENT ON COLUMN pgmnemo.mem_edge.edge_kind IS
    'MAGMA §3 top-level category (semantic|temporal|causal|entity). '
    'Must be set on all new inserts — use the edge_type→edge_kind mapping in the RFC.';

-- ── Indexes on mem_edge ───────────────────────────────────────────────────────

CREATE INDEX pgmnemo_mem_edge_source_type_idx
    ON pgmnemo.mem_edge (source_id, relation_type)
    WHERE valid_until IS NULL;

CREATE INDEX pgmnemo_mem_edge_target_type_idx
    ON pgmnemo.mem_edge (target_id, relation_type)
    WHERE valid_until IS NULL;

CREATE INDEX pgmnemo_mem_edge_valid_range_idx
    ON pgmnemo.mem_edge (valid_from, valid_until);

-- v0.3.0: per-kind partial indexes (traversal-optimised)
CREATE INDEX ix_mem_edge_kind_causal
    ON pgmnemo.mem_edge (source_id, target_id, weight DESC)
    WHERE edge_kind = 'causal';

CREATE INDEX ix_mem_edge_kind_temporal
    ON pgmnemo.mem_edge (source_id, created_at DESC, target_id)
    WHERE edge_kind = 'temporal';

CREATE INDEX ix_mem_edge_kind_semantic
    ON pgmnemo.mem_edge (source_id, weight DESC, target_id)
    WHERE edge_kind = 'semantic';

CREATE INDEX ix_mem_edge_kind_entity
    ON pgmnemo.mem_edge (source_id, target_id)
    WHERE edge_kind = 'entity';

-- v0.3.0: GIN index on metadata for JSONB attribute queries scoped to any edge_kind
CREATE INDEX ix_mem_edge_metadata_gin
    ON pgmnemo.mem_edge USING GIN (metadata)
    WHERE metadata != '{}'::jsonb;

-- v0.3.0: composite index for mixed-kind queries
CREATE INDEX ix_pgmnemo_mem_edge_kind_time
    ON pgmnemo.mem_edge (edge_kind, created_at DESC);

CREATE TRIGGER mem_edge_updated_at
    BEFORE UPDATE ON pgmnemo.mem_edge
    FOR EACH ROW EXECUTE FUNCTION pgmnemo._set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- Functions
-- ─────────────────────────────────────────────────────────────────────────────

-- version() — always returns live extversion from pg_catalog
CREATE OR REPLACE FUNCTION pgmnemo.version()
RETURNS TEXT
LANGUAGE SQL
STABLE
PARALLEL SAFE
AS $$
    SELECT extversion FROM pg_extension WHERE extname = 'pgmnemo';
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the currently-installed pgmnemo version by querying pg_catalog.pg_extension.';

-- ingest() — validated public write API (v0.1.0)
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
    new_id BIGINT;
BEGIN
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
    'Validated public write API. Use this instead of raw INSERT.';

-- recall_lessons() — v0.3.0: BFS uses edge_kind ENUM (MAGMA §3 fix)
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
    -- BFS through causal + temporal edges (v0.3.0: uses edge_kind ENUM)
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

-- recall_lessons_pooled() — cross-role recall wrapper (v0.1.2)
CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons_pooled(
    query_embedding  vector(1024),
    k                INT  DEFAULT 10,
    app_id           INT  DEFAULT NULL
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
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT * FROM pgmnemo.recall_lessons(query_embedding, k, NULL, app_id, NULL);
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons_pooled(vector, INT, INT) IS
    'Cross-role recall wrapper: calls recall_lessons() with role=NULL (pooled — no role filter).';

-- transition_lesson() — state machine transition (v0.1.4)
CREATE OR REPLACE FUNCTION pgmnemo.transition_lesson(lesson_id BIGINT, new_state TEXT)
RETURNS pgmnemo.agent_lesson
LANGUAGE plpgsql
AS $$
DECLARE
    _lesson pgmnemo.agent_lesson;
BEGIN
    SELECT * INTO _lesson
    FROM pgmnemo.agent_lesson
    WHERE id = lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'lesson % not found', lesson_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pgmnemo.agent_lesson_state_transition
        WHERE from_state = _lesson.state AND to_state = new_state
    ) THEN
        RAISE EXCEPTION 'invalid state transition: % → %', _lesson.state, new_state;
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET state            = new_state,
        state_changed_at = NOW()
    WHERE id = lesson_id
    RETURNING * INTO _lesson;

    RETURN _lesson;
END;
$$;

COMMENT ON FUNCTION pgmnemo.transition_lesson(BIGINT, TEXT) IS
    'Advance a lesson to new_state; raises if the transition is not permitted.';

-- evict_expired_lessons() — TTL purge (v0.1.4)
CREATE OR REPLACE FUNCTION pgmnemo.evict_expired_lessons()
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    evicted INT;
BEGIN
    WITH deleted AS (
        DELETE FROM pgmnemo.agent_lesson
        WHERE expires_at IS NOT NULL
          AND expires_at < NOW()
        RETURNING 1
    )
    SELECT COUNT(*) INTO evicted FROM deleted;
    RETURN COALESCE(evicted, 0);
END;
$$;

COMMENT ON FUNCTION pgmnemo.evict_expired_lessons() IS
    'Deletes all lessons whose expires_at is non-NULL and in the past. '
    'Returns the number of rows removed. Safe to call frequently.';

-- traverse_causal_chain() — v0.3.0: uses edge_kind for causal traversal
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
        RAISE EXCEPTION
            'pgmnemo.traverse_causal_chain: direction must be ''forward'', ''backward'', or ''both'' — got: %',
            direction;
    END IF;

    RETURN QUERY
    WITH RECURSIVE causal_walk(lesson_id, depth, path, path_weight) AS (
        SELECT
            start_id,
            0,
            ARRAY[start_id],
            1.0::REAL

        UNION ALL

        -- Forward: source → target (causal kind, relation_type in relation_types)
        SELECT
            me.target_id,
            cw.depth + 1,
            cw.path || me.target_id,
            cw.path_weight * COALESCE(me.weight, 1.0)
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON me.source_id = cw.lesson_id
        WHERE direction IN ('forward', 'both')
          AND me.edge_kind = 'causal'
          AND me.relation_type = ANY(relation_types)
          AND cw.depth < max_depth
          AND NOT (me.target_id = ANY(cw.path))

        UNION ALL

        -- Backward: target → source (causal kind, relation_type in relation_types)
        SELECT
            me.source_id,
            cw.depth + 1,
            cw.path || me.source_id,
            cw.path_weight * COALESCE(me.weight, 1.0)
        FROM causal_walk cw
        JOIN pgmnemo.mem_edge me ON me.target_id = cw.lesson_id
        WHERE direction IN ('backward', 'both')
          AND me.edge_kind = 'causal'
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
    'BFS traversal of causal edges in pgmnemo.mem_edge (v0.3.0). '
    'Filters on edge_kind = ''causal'' + relation_type IN relation_types. '
    'Default relation_types: causal, derives_from, contradicts (MAGMA §3). '
    'direction: ''forward'' (source→target), ''backward'' (target→source), ''both''. '
    'Cycle guard via path array.';

-- traverse_temporal_window() — co-temporal episode discovery (v0.2.0)
CREATE OR REPLACE FUNCTION pgmnemo.traverse_temporal_window(
    start_id            BIGINT,
    window_interval     INTERVAL    DEFAULT INTERVAL '15 minutes',
    include_unlinked    BOOLEAN     DEFAULT TRUE,
    role_filter         TEXT        DEFAULT NULL,
    project_id_filter   INT         DEFAULT NULL,
    k                   INT         DEFAULT 20
)
RETURNS TABLE (
    lesson_id       BIGINT,
    time_delta_sec  DOUBLE PRECISION,
    linked          BOOLEAN,
    edge_weight     REAL,
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
DECLARE
    _start_ts           TIMESTAMPTZ;
    _include_unverified BOOLEAN;
BEGIN
    SELECT al.created_at INTO _start_ts
    FROM pgmnemo.agent_lesson al
    WHERE al.id = start_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    _include_unverified := COALESCE(
        (current_setting('pgmnemo.include_unverified', true) = 'on'),
        FALSE
    );

    RETURN QUERY
    WITH candidates AS (
        SELECT
            al.id,
            al.role,
            al.topic,
            al.lesson_text,
            al.importance,
            al.created_at,
            al.commit_sha,
            al.verified_at,
            ABS(EXTRACT(EPOCH FROM (al.created_at - _start_ts))) AS delta_sec
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.id <> start_id
          AND al.created_at BETWEEN (_start_ts - window_interval)
                                AND (_start_ts + window_interval)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter         IS NULL OR al.role       = role_filter)
          AND (project_id_filter   IS NULL OR al.project_id = project_id_filter)
    ),
    edges AS (
        SELECT e.target_id AS other_id, e.weight
        FROM pgmnemo.mem_edge e
        WHERE e.source_id = start_id
          AND e.valid_until IS NULL
        UNION ALL
        SELECT e.source_id AS other_id, e.weight
        FROM pgmnemo.mem_edge e
        WHERE e.target_id = start_id
          AND e.valid_until IS NULL
    )
    SELECT
        c.id                            AS lesson_id,
        c.delta_sec                     AS time_delta_sec,
        (e.weight IS NOT NULL)          AS linked,
        e.weight                        AS edge_weight,
        c.role,
        c.topic,
        c.lesson_text,
        c.importance,
        c.created_at,
        c.commit_sha,
        c.verified_at
    FROM candidates c
    LEFT JOIN edges e ON e.other_id = c.id
    WHERE include_unlinked OR e.weight IS NOT NULL
    ORDER BY c.delta_sec ASC, c.importance DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_temporal_window(BIGINT, INTERVAL, BOOLEAN, TEXT, INT, INT) IS
    'Return up to k agent_lesson rows whose created_at falls within ±window_interval of start_id. '
    'linked=TRUE when a mem_edge (any direction) exists between that row and start_id. '
    'include_unlinked=FALSE restricts output to explicitly connected lessons.';

-- ─────────────────────────────────────────────────────────────────────────────
-- v0.2.1: Row-Level Security (Q5)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM set_config('pgmnemo.ef_search',   '100', FALSE);
    PERFORM set_config('pgmnemo.recency_weight', '0.08', FALSE);
    PERFORM set_config('pgmnemo.tenant_id',   '', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

ALTER TABLE pgmnemo.agent_lesson ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_lesson_tenant_isolation
    ON pgmnemo.agent_lesson
    AS PERMISSIVE
    FOR ALL
    USING (
        COALESCE(current_setting('pgmnemo.tenant_id', TRUE), '') = ''
        OR
        project_id::TEXT = current_setting('pgmnemo.tenant_id', TRUE)
    );

COMMENT ON POLICY agent_lesson_tenant_isolation ON pgmnemo.agent_lesson IS
    'Multi-tenant row isolation by project_id. '
    'SET pgmnemo.tenant_id = ''<id>'' to restrict the session to that project. '
    'Empty or unset tenant_id bypasses the policy (service-account mode).';

ALTER TABLE pgmnemo.mem_edge ENABLE ROW LEVEL SECURITY;

CREATE POLICY mem_edge_tenant_isolation
    ON pgmnemo.mem_edge
    AS PERMISSIVE
    FOR ALL
    USING (
        COALESCE(current_setting('pgmnemo.tenant_id', TRUE), '') = ''
        OR
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
    'Empty / unset tenant_id bypasses the policy (service-account mode).';
-- pgmnemo 0.3.1 → 0.4.0 upgrade
--
-- THEME: Hybrid retrieval promoted to default in recall_lessons().
--
-- Bench evidence (real-DB, 2026-05-15):
--   LoCoMo session-level (DRAGON):
--     recall@10  0.7951 → 0.8409  (+4.15pp, p_corr=0.0156, SIGNIFICANT)
--     MRR        0.5569 → 0.6365  (+7.96pp, p_corr<0.0001, SIGNIFICANT)
--     open_domain/MRR: +9.79pp (p_corr=0.0009)
--     5 significant improvements, 0 regressions across 24 cells
--   LongMemEval-S (bge-m3):
--     recall@10  0.9334 → 0.9334  (+0.00pp, neutral — already saturated)
--     MRR        0.8472 → 0.8521  (+0.49pp, neutral)
--
-- Honest scope:
--   ✓ Significant lift on conversational dialog retrieval (LoCoMo paper-canonical)
--   ✓ No regression anywhere
--   ✗ Does NOT close the BM25 gap on LongMemEval (BM25=0.982, pgmnemo=0.9334)
--   ✗ Adopters with bge-m3-strength embeddings on multi-doc retrieval will see
--     no measurable change (which is fine; provenance gate is the real moat)
--
-- Migration design:
--   1. Idempotent install of recall_hybrid() + lesson_tsv prerequisites
--      (these may already exist if v0.2.2 hybrid opt-in was applied — CREATE
--      OR REPLACE / IF NOT EXISTS make re-application safe).
--   2. recall_lessons() rewritten as a thin router:
--        - If query_text present and pgmnemo.disable_hybrid is FALSE/unset:
--          delegate to recall_hybrid() and project to 12-column shape.
--        - Otherwise: original v0.3.0 vector-only body, unchanged.
--   3. Opt-out: SET pgmnemo.disable_hybrid = 'true' restores v0.3.0 behaviour.



-- ─────────────────────────────────────────────────────────────────────────────
-- S1: lesson_tsv column + trigger + GIN index (idempotent)
--     If already present from v0.2.2 hybrid opt-in: no-op.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS lesson_tsv tsvector;

CREATE OR REPLACE FUNCTION pgmnemo._update_lesson_tsv() RETURNS TRIGGER AS $$
BEGIN
    NEW.lesson_tsv := to_tsvector('english', COALESCE(NEW.lesson_text, ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS pgmnemo_agent_lesson_tsv_trg ON pgmnemo.agent_lesson;
CREATE TRIGGER pgmnemo_agent_lesson_tsv_trg
    BEFORE INSERT OR UPDATE OF lesson_text
    ON pgmnemo.agent_lesson
    FOR EACH ROW
    EXECUTE FUNCTION pgmnemo._update_lesson_tsv();

-- Backfill any rows with NULL lesson_tsv
UPDATE pgmnemo.agent_lesson
SET lesson_text = lesson_text
WHERE lesson_tsv IS NULL;

CREATE INDEX IF NOT EXISTS pgmnemo_agent_lesson_tsv_gin_idx
    ON pgmnemo.agent_lesson USING GIN (lesson_tsv);


-- ─────────────────────────────────────────────────────────────────────────────
-- S2: recall_hybrid() function (CREATE OR REPLACE — idempotent)
--     Body is identical to v0.2.2 EXPERIMENTAL opt-in.
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
STABLE
PARALLEL SAFE
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
    _ghost_count        INT;   -- F2: ghost guidance
    _fetch_k_vec        INT;   -- #4: bounded HNSW fetch
    _fetch_k_bm25       INT;   -- #4: bounded BM25 fetch
    _conf_boost_w       DOUBLE PRECISION;  -- I1: confidence boost weight
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
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding   -- HNSW index scan
        LIMIT _fetch_k_vec                           -- C2: GREATEST(k*4, _ef_search)
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
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY raw_bm25_score DESC
        LIMIT _fetch_k_bm25                          -- C2: GREATEST(k*4, 40)
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
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)   AS vec_rank,
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
    )
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
    ORDER BY f.final_score DESC, f.id ASC   -- C7: tie-breaker for determinism
    LIMIT k;

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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'v0.9.2 — I1: confidence-weighted ranking (additive, zero-centered). '
    'GUC pgmnemo.confidence_boost_weight (default 0.0 = OFF, range [0.0, 0.01]). '
    'When ON: final_score += w * (confidence - 0.5). Recommended w=0.003. '
    'Cold-start (confidence=0.5) gets zero boost. High-vs-low delta at w=0.003 ≈ 0.0024 ≈ 8-15 RRF positions. '
    'Activation gate: pending positive A/B validation. '
    'v0.8.2 — F2: NOTICE when 0 rows returned and ghost lessons exist in scope. '
    'Two-phase indexed retrieval: HNSW (pgvector) + GIN (BM25) → RRF fusion → graph proximity boost. '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'STABLE PARALLEL SAFE.';


-- ─────────────────────────────────────────────────────────────────────────────
-- S3: recall_lessons() — REWRITTEN as router
--
--     query_text present + hybrid not disabled → delegate to recall_hybrid()
--     otherwise                                → original vector-only body
--
--     Adopters needing strict v0.3.0 behaviour: SET pgmnemo.disable_hybrid='true'
-- ─────────────────────────────────────────────────────────────────────────────

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
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
BEGIN
    -- v0.4.0: route to recall_hybrid() when query_text present and not disabled
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
            h.created_at
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

    -- Vector-only path: unchanged from v0.3.0 body
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
    -- BFS through causal + temporal edges (v0.3.0: uses edge_kind ENUM)
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
    'Hybrid retrieval router v0.4.0. '
    'When query_text is non-empty and embedding is present (and disable_hybrid GUC '
    'is FALSE/unset), delegates to recall_hybrid() with default weights '
    '(vec_weight=0.4, bm25_weight=0.4, rrf_k=60). Otherwise uses v0.3.0 vector-only '
    'body unchanged. SET pgmnemo.disable_hybrid = ''true'' restores strict '
    'vector-only behaviour.';

-- Bench evidence summary stored as table comment for adopter visibility
COMMENT ON COLUMN pgmnemo.agent_lesson.lesson_tsv IS
    'tsvector populated by pgmnemo_agent_lesson_tsv_trg trigger. '
    'GIN-indexed for BM25 retrieval via ts_rank_cd in recall_hybrid(). '
    'Required as of v0.4.0 (was opt-in in v0.2.2).';
-- pgmnemo 0.4.0 → 0.4.1 upgrade
--
-- THEME: Production hardening per first external
--        production-user feedback). Operational observability + safe deprecation.
--
-- Bench evidence (real-DB, expected 2026-05-21 after Phase 2):
--   LoCoMo session    : neutral expected — R1 default change 0.08 → 0.05 may
--                       cause near-threshold drift; OVERALL r@10 = 0.8409 hold
--   LoCoMo segment    : neutral expected — router unchanged
--   LongMemEval-S     : neutral expected — hybrid neutral on bge-m3 saturated
--   Prod corpus       : recall@10 gate must hold after
--                       default change (harness rerun post-ship)
--
-- Honest scope:
--   ✓ pgmnemo.stats() one-query health check (R3)
--   ✓ vec_score / bm25_score / rrf_score in recall_lessons output (R4)
--   ✓ recency_weight default 0.08 → 0.05 per an internal ablation (R1 code part)
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



-- ─────────────────────────────────────────────────────────────────────────────
-- S1: pgmnemo.stats() — diagnostic health-check SP
-- RFC R3 + maintainer additions (recall_hybrid_available,
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
    'v0.4.1 diagnostic health-check (RFC R3). Single-row summary of '
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
        0.05  -- v0.4.1: default lowered from 0.08 per an internal ablation (R1)
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
    'pgmnemo.recency_weight (default 0.05 since v0.4.1 per an internal ablation). '
    'Diagnostic columns (v0.4.1, R4): vec_score = raw cosine; bm25_score / '
    'rrf_score = NULL on vector-only path, populated on hybrid path. '
    'Opt-out: SET pgmnemo.disable_hybrid = ''true''.';


-- ─────────────────────────────────────────────────────────────────────────────
-- S4: traverse_causal_chain — 4-arg deprecation with NOTICE (RFC R10)
--
-- v0.4.0 ships only the 5-arg form with direction DEFAULT 'forward'. To support
-- existing 4-arg callers AND add a deprecation
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
    'DEPRECATED in v0.4.1 (RFC R10). Wrapper around 5-arg form with '
    'direction=''forward''. Emits RAISE NOTICE on every call. Will be REMOVED '
    'in v0.5.0; update callers to pass direction explicitly.';


-- ─────────────────────────────────────────────────────────────────────────────
-- pgmnemo 0.5.0 additions (applied over 0.4.1 base above)
-- ─────────────────────────────────────────────────────────────────────────────

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
    k                 INT           DEFAULT 10,
    role_filter       TEXT          DEFAULT NULL,
    project_id_filter INT           DEFAULT NULL,
    query_text        TEXT          DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ   DEFAULT NULL  -- v0.6.1 F2: point-in-time recall
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
#variable_conflict use_column
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

        -- v0.6.1 F2: propagate as_of_ts to recall_hybrid() via GUC (transaction-local)
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

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

    -- Vector-only path
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

    -- H-06: recency decay coefficient = recency_weight × temporal_boost
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
          -- v0.6.1 F2: point-in-time filter on vector-only path
          AND (as_of_ts IS NULL OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts))
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

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.6.3 — R1 AmbiguousColumn fix (#variable_conflict use_column). '
    'v0.6.2 hybrid router with as_of_ts point-in-time parameter (F2). '
    'as_of_ts DEFAULT NULL preserves v0.5.1/v0.6.0 behavior at existing call sites. '
    'When as_of_ts IS NOT NULL: propagates to recall_hybrid() via pgmnemo.as_of_timestamp GUC '
    '  (transaction-local SET, TRUE flag = local to transaction); '
    '  vector-only path applies filter directly in candidates CTE WHERE clause. '
    'R5: query_text truncated to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'H-06: recency decay = max(0, 1 - age_days/90); coeff=recency_weight×temporal_boost. '
    'Diagnostic cols: vec_score=cosine; bm25_score/rrf_score=NULL on vector-only path.';


-- ─────────────────────────────────────────────────────────────────────────────
-- Update recall_lessons_pooled() to call 6-arg recall_lessons()
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons_pooled(
    query_embedding  vector(1024),
    k                INT  DEFAULT 10,
    app_id           INT  DEFAULT NULL
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
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT lesson_id, score, role, project_id, topic, lesson_text,
           importance, metadata, commit_sha, artifact_hash, verified_at, created_at
    FROM pgmnemo.recall_lessons(query_embedding, k, NULL::TEXT, app_id, NULL::TEXT, NULL::TIMESTAMPTZ);
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons_pooled(vector, INT, INT) IS
    'Cross-role recall wrapper: calls recall_lessons() with role=NULL (pooled — no role filter). '
    'v0.6.2: calls 6-arg recall_lessons() with NULL as_of_ts.';

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
-- pgmnemo 0.5.1 → 0.6.0 upgrade migration
-- Changes:
--   §3  pgmnemo.stats()   — add ghost_count BIGINT column
--   §4  pgmnemo.ingest()  — RAISE NOTICE when bitemporal close+create fires (Q5 dedup obs.)
-- Backward compatibility: zero breaking changes (see PLAN_V060.md §2 audit).
-- Prerequisites: pgmnemo 0.5.1 installed. Requires pgvector.
-- Apply: ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';

-- ─────────────────────────────────────────────────────────────────────────────
-- §1, §2 (recall_hybrid + recall_lessons changes) deferred to v0.6.1.
--
-- The original v0.6.0 plan added bitemporal `as_of_ts` parameter to
-- recall_lessons() and made recall_hybrid() read pgmnemo.as_of_timestamp
-- GUC for temporal filtering. Implementation introduced a CTE refactor
-- that caused two runtime regressions (AmbiguousColumn on `role`,
-- UndefinedTable on `graph_walk`) caught by scripts/smoke_recall_hybrid.py.
--
-- Decision: ship v0.6.0 with the additive, side-effect-free items only
-- (ghost_count, NOTICE, recall_stats view, docs). recall_hybrid() and
-- recall_lessons() remain byte-identical to v0.5.1 — Δ=0 confirmed.
--
-- Bitemporal recall returns in v0.6.1 alongside the corrected RRF
-- variant (A-scale) after real-DB benchmark validation.
-- See spec/v060/INVESTIGATION_FIX_A_REGRESSION.md for context.

-- §3  pgmnemo.stats() — add ghost_count BIGINT (RFC Q4)
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
        -- ghost_count (v0.6.0): active lessons without provenance (RFC Q4)
        -- Definition: t_valid_to = 'infinity' (authoritative active-row indicator) AND verified_at IS NULL.
        -- NOTE: the RFC Q4 spec says "is_active = TRUE"; implementation uses t_valid_to = 'infinity'
        -- because _bitemporal_close_prior() trigger does NOT update is_active when closing rows.
        -- t_valid_to = 'infinity' is the correct semantic equivalent of "currently active".
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.6.0 diagnostic health-check. Adds ghost_count (RFC Q4). '
    'ghost_count: active lessons where verified_at IS NULL — no commit_sha AND no artifact_hash. '
    'Distinct from orphan_count (functions not owned by extension). '
    'Use ghost_count to track provenance migration progress: target < 5% of lesson_count '
    'before switching pgmnemo.include_unverified = off. '
    'Single-row summary; <50ms on N=10k corpus.';


-- ─────────────────────────────────────────────────────────────────────────────
-- §4  pgmnemo.ingest() — RAISE NOTICE on bitemporal close+create (RFC Q5)
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

-- ─── R9: recall hit-count metric view ────────────────────────────────────────
-- RFC R9 (deferred from v0.4.1). Requires track_functions = 'pl' or
-- 'all' in postgresql.conf; rows only appear after the first call post-reset.

CREATE OR REPLACE VIEW pgmnemo.recall_stats AS
SELECT
    n.nspname   AS schema,
    p.proname   AS function_name,
    s.calls,
    s.total_time,
    s.self_time,
    NOW()       AS observed_at
FROM pg_stat_user_functions s
JOIN pg_proc      p ON p.oid = s.funcid
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname IN ('recall_lessons', 'recall_hybrid', 'ingest');

COMMENT ON VIEW pgmnemo.recall_stats IS
    'Observability view for recall/ingest call counts (R9, v0.6.0). '
    'Requires track_functions = ''pl'' or ''all'' in postgresql.conf. '
    'Rows appear only after first call following a pg_stat_reset().';

-- =============================================================================
-- v0.7.0 additions (outcome-learning loop + footgun remediation)
-- =============================================================================

-- pgmnemo--0.6.3--0.7.0.sql
-- Incremental upgrade: v0.6.3 → v0.7.0
--
-- Theme: Outcome-learning loop + footgun remediation
--
-- A) Schema: confidence REAL, success_count INT, fail_count INT,
--            last_outcome TEXT, last_outcome_at TIMESTAMPTZ on agent_lesson
-- B) pgmnemo.reinforce(lesson_id, outcome) — asymmetric confidence update
-- C) recall_lessons() + recall_hybrid() — confidence in scoring + output
-- D) Footgun guard: RAISE NOTICE when embedding missing (recall_lessons vector-only path)
-- E) match_confidence [0,1] interpretable recall-match score in output
-- F) Ingestion guards: min-length reject, token-repetition reject, embedding dedup warn+return
-- G) stats() extension: confidence distribution columns (19 cols total, was 14)
--
-- Backward compatibility:
--   Named-column callers of recall_lessons/recall_hybrid: unaffected.
--   Positional callers: re-audit for new trailing cols (confidence, match_confidence).
--   ingest() signature unchanged (9 params).
--   stats() gains 5 columns -- named-column callers unaffected.
--
-- SPDX-License-Identifier: Apache-2.0

-- =============================================================================
-- A) Schema additions (idempotent via ADD COLUMN IF NOT EXISTS)
-- =============================================================================

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS confidence      REAL        NOT NULL DEFAULT 0.5
        CONSTRAINT ck_agent_lesson_confidence CHECK (confidence BETWEEN 0.0 AND 1.0),
    ADD COLUMN IF NOT EXISTS success_count   INT         NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS fail_count      INT         NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_outcome    TEXT,
    ADD COLUMN IF NOT EXISTS last_outcome_at TIMESTAMPTZ;

-- Partial index for monitoring at-risk (low-confidence) lessons
CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_confidence_low
    ON pgmnemo.agent_lesson (confidence ASC)
    WHERE is_active AND confidence < 0.3;

COMMENT ON COLUMN pgmnemo.agent_lesson.confidence IS
    'Outcome-track-record confidence score [0.0, 1.0]. '
    'Default 0.5 (cold-start neutral). '
    'Updated by pgmnemo.reinforce(): success +pgmnemo.reinforce_success_delta (default 0.02), '
    'failure -pgmnemo.reinforce_fail_delta (default 0.12), neutral no-op. '
    'Clamped to [0.0, 1.0] by CHECK constraint + reinforce() logic. '
    'Defaults base-rate-adjusted for 83.5% base success rate.';

COMMENT ON COLUMN pgmnemo.agent_lesson.success_count IS
    'Cumulative count of successful recall outcomes recorded via reinforce().';

COMMENT ON COLUMN pgmnemo.agent_lesson.fail_count IS
    'Cumulative count of failure outcomes recorded via reinforce().';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome IS
    'Most recent outcome string from reinforce(): success | failure (neutral is a no-op).';

COMMENT ON COLUMN pgmnemo.agent_lesson.last_outcome_at IS
    'Timestamp of the most recent reinforce() call that changed this row (success or failure only).';

-- =============================================================================
-- B) pgmnemo.reinforce() -- GUC-configurable confidence update (v0.9.2/D1)
--    success: +pgmnemo.reinforce_success_delta (default 0.02)
--    failure: -pgmnemo.reinforce_fail_delta    (default 0.12)
--    neutral: no-op (no write)
--    Unknown outcome: RAISE EXCEPTION (exact case required)
--    Returns new confidence value (REAL).
--    Row-locked via SELECT ... FOR UPDATE for concurrent-safe update.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _row           pgmnemo.agent_lesson%ROWTYPE;
    _new_conf      REAL;
    _success_delta DOUBLE PRECISION;
    _fail_delta    DOUBLE PRECISION;
BEGIN
    -- D1: read reinforce deltas from GUC (base-rate-adjusted defaults)
    BEGIN
        _success_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
            0.02)));
    EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
    END;

    BEGIN
        _fail_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
            0.12)));
    EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
    END;

    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    CASE p_outcome
        WHEN 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                success_count   = _row.success_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                fail_count      = _row.fail_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            _new_conf := _row.confidence;

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    RETURN _new_conf;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'Outcome-learning update (v0.9.2/D1): adjusts confidence for lesson p_lesson_id. '
    'Exact case required: ''success'' | ''failure'' | ''neutral''. '
    'success: confidence += pgmnemo.reinforce_success_delta (default 0.02, clamped [0.001,0.5]). '
    'failure: confidence -= pgmnemo.reinforce_fail_delta    (default 0.12, clamped [0.001,0.5]). '
    'neutral: no-op -- returns current confidence without any write. '
    'Unknown outcome string: RAISE EXCEPTION. '
    'Row-locked (SELECT ... FOR UPDATE) for concurrent-safe update on hot lessons. '
    'Defaults base-rate-adjusted for 83.5% success workload.';

-- =============================================================================
-- B2) pgmnemo.reinforce(BIGINT[], TEXT) — batch form (v0.9.2/D1, was v0.7.1)
--     Skips missing lesson_ids silently (no RAISE). Returns count updated.
--     Unknown outcome: RAISE EXCEPTION (caller error).
--     Empty/NULL array: returns 0.
--     Both scalar and batch read GUC deltas (base-rate-adjusted defaults).
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_ids BIGINT[],
    p_outcome    TEXT
)
RETURNS INT
LANGUAGE plpgsql
AS $func$
DECLARE
    _id            BIGINT;
    _row           pgmnemo.agent_lesson%ROWTYPE;
    _new_conf      REAL;
    _updated       INT := 0;
    _success_delta DOUBLE PRECISION;
    _fail_delta    DOUBLE PRECISION;
BEGIN
    -- Validate outcome up-front so the caller gets a clear error on bad input.
    IF p_outcome NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
            p_outcome;
    END IF;

    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    -- D1: read reinforce deltas from GUC (base-rate-adjusted defaults)
    BEGIN
        _success_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
            0.02)));
    EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
    END;

    BEGIN
        _fail_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
            0.12)));
    EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
    END;

    FOREACH _id IN ARRAY p_lesson_ids LOOP
        SELECT * INTO _row
        FROM pgmnemo.agent_lesson
        WHERE id = _id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- skip missing; no RAISE (bitemporal supersession / TTL normal)
        END IF;

        CASE p_outcome
            WHEN 'success' THEN
                _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    success_count   = _row.success_count + 1,
                    last_outcome    = 'success',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'failure' THEN
                _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    fail_count      = _row.fail_count + 1,
                    last_outcome    = 'failure',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'neutral' THEN
                NULL;  -- no-op; does not increment _updated
        END CASE;
    END LOOP;

    RETURN _updated;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT[], TEXT) IS
    'Batch confidence update v0.9.2/D1. Iterates p_lesson_ids; skips missing IDs silently (no RAISE). '
    'Returns count of rows actually updated (neutral outcome does not increment count). '
    'Unknown outcome string raises RAISE EXCEPTION (caller programming error). '
    'Empty or NULL array returns 0. '
    'success: +pgmnemo.reinforce_success_delta (default 0.02), failure: -pgmnemo.reinforce_fail_delta (default 0.12). '
    'Scalar form reinforce(BIGINT, TEXT) unchanged (same GUC reads).';

-- =============================================================================
-- C + D + E) recall_hybrid() v0.7.1
-- Return-type changes (new trailing cols) require DROP + CREATE.
-- New output columns appended at end: confidence REAL, match_confidence REAL
-- Scoring change: aux term = 0.025*(imp/5) + 0.025*confidence + 0.05*recency + 0.05*prov
-- match_confidence = LEAST(1.0, GREATEST(0.0, v_score))::REAL  [v0.7.1: vec_score not final_score/1.5]
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
    rrf_k             INT              DEFAULT 60
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
STABLE
PARALLEL SAFE
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
    _raw_blend_weight   DOUBLE PRECISION;  -- v0.8.1 F2: cardinal raw score blend
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
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);  -- same order as max RRF per signal

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
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
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

    RETURN QUERY
    WITH RECURSIVE
    raw_candidates AS (
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
            al.confidence,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            -- v0.8.1 F3: topic in BM25 — setweight(topic, 'A') || lesson_tsv
            CASE
                WHEN _has_text AND (al.lesson_tsv @@ _tsquery
                     OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND (al.lesson_tsv @@ _tsquery
               OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery))
          )
    ),
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)   AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                           AS bm25_rank_sparse
        FROM raw_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at, r.confidence,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            -- v0.8.1 F2: ordinal RRF + cardinal raw score blend (absolute match strength survives)
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
            -- v0.8.1 F1: graph is multiplicative re-rank (tie-breaker, not driver)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    )
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
        -- BUG-1 FIX (v0.7.1): use vec_score (cosine, [0,1]) not final_score/1.5.
        -- final_score is RRF-scale (~0.008-0.05); dividing by 1.5 produced ~0.005.
        -- vec_score is cosine similarity, already in [0,1] by pgvector guarantee.
        -- On text-only path (query_embedding IS NULL), vec_score = 0.0.
        LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence
    FROM final f
    ORDER BY f.final_score DESC
    LIMIT k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.7.1 -- match_confidence formula corrected (BUG-1), graph_proximity note added. '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Scoring: rrf_sparse + _aux_scale*(0.025*imp/5 + 0.025*conf + 0.05*recency + 0.05*prov) + delta*graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'graph_proximity contributes only when mem_edge is populated; with no edges the graph term is 0 (correct, not a bug). '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL).';

-- =============================================================================
-- C + D + E) recall_lessons() v0.7.0
-- Return-type changes (new trailing cols) require DROP + CREATE.
-- New output columns appended at end: confidence REAL, match_confidence REAL
-- Scoring change (vector-only): 0.2*(imp/5) => 0.15*(imp/5) + 0.15*confidence
-- D footgun: RAISE NOTICE when query_embedding IS NULL and _has_text
-- match_confidence = LEAST(1.0, GREATEST(0.0, score / 1.5))::REAL
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
    as_of_ts          TIMESTAMPTZ DEFAULT NULL
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
STABLE
PARALLEL SAFE
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
            role_filter, project_id_filter, 0.4, 0.4, 60
        ) h;
        RETURN;
    END IF;

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
    )
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
    LIMIT k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.7.0 -- confidence integration + footgun guard + match_confidence. '
    'Scoring (vector path): 0.5*vec + 0.15*imp/5 + 0.15*confidence + gamma*recency + 0.1*prov + delta*graph. '
    'confidence: outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, GREATEST(0.0, score/1.5)) -- interpretable [0,1] quality indicator. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL and text-only fallback active. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL). '
    'Named-column callers unaffected; positional callers: re-audit for 2 new trailing cols.';

-- =============================================================================
-- F) Ingestion guards -- CREATE OR REPLACE (signature unchanged, 9 params)
-- F1: lesson_text < 20 chars -> RAISE EXCEPTION
-- F2: most-frequent token > 80% of all tokens -> RAISE EXCEPTION (repetitive content)
-- F3: cosine similarity > 0.98 to existing active lesson (same project_id) ->
--     RAISE WARNING + RETURN existing lesson_id (no new insert)
-- =============================================================================

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
LANGUAGE plpgsql AS $func$
DECLARE
    new_id             BIGINT;
    _content_hash      TEXT;
    _prior_count       INT;
    _dedup_id          BIGINT;
    _dedup_sim         DOUBLE PRECISION;
    _tokens            TEXT[];
    _token             TEXT;
    _token_counts      JSONB;
    _max_freq          INT;
    _total_tokens      INT;
    _trimmed_text      TEXT;
BEGIN
    -- F1: minimum length guard (fires BEFORE provenance gate trigger)
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) < 20 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars)';
    END IF;

    -- F2: token-frequency repetition guard
    _trimmed_text := trim(p_lesson_text);
    _tokens := regexp_split_to_array(
        regexp_replace(_trimmed_text, '\s+', ' ', 'g'), ' ');
    _total_tokens := array_length(_tokens, 1);

    IF _total_tokens > 0 THEN
        _token_counts := '{}'::JSONB;
        FOREACH _token IN ARRAY _tokens LOOP
            _token_counts := jsonb_set(
                _token_counts,
                ARRAY[_token],
                to_jsonb(COALESCE((_token_counts->>_token)::INT, 0) + 1)
            );
        END LOOP;

        SELECT MAX(value::INT)
        INTO _max_freq
        FROM jsonb_each_text(_token_counts);

        IF _max_freq::DOUBLE PRECISION / _total_tokens::DOUBLE PRECISION > 0.8 THEN
            RAISE EXCEPTION 'pgmnemo.ingest: lesson_text appears to be repetitive content';
        END IF;
    END IF;

    -- Embedding dimension guard
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch -- expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- F3: near-duplicate embedding guard (cosine > 0.98, same project_id)
    IF p_embedding IS NOT NULL THEN
        SELECT id, (1.0 - (embedding <=> p_embedding))
        INTO _dedup_id, _dedup_sim
        FROM pgmnemo.agent_lesson
        WHERE is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
          AND embedding IS NOT NULL
          AND project_id = p_project_id
          AND (1.0 - (embedding <=> p_embedding)) > 0.98
        ORDER BY embedding <=> p_embedding
        LIMIT 1;

        IF FOUND THEN
            RAISE WARNING
                'pgmnemo.ingest: near-duplicate detected -- cosine similarity % > 0.98 '
                'to existing lesson_id=% (project_id=%). Returning existing lesson_id.',
                ROUND(_dedup_sim::NUMERIC, 4), _dedup_id, p_project_id;
            RETURN _dedup_id;
        END IF;
    END IF;

    -- Bitemporal dedup observability
    _content_hash := MD5(
        COALESCE(p_role, '')  || '|' ||
        COALESCE(p_topic, '') || '|' ||
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
        -- v0.9.0 #2: verified_at = NOW() for ALL lessons passing quality gates.
        -- NULL-embedding lessons are text-only (BM25 path); must not be ghost-excluded.
        NOW()
    ) RETURNING id INTO new_id;

    IF _prior_count > 0 THEN
        RAISE NOTICE
            'pgmnemo.ingest: bitemporal close+create fired -- closed % prior version(s) '
            '(content_hash=%). New lesson_id=%.',
            _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API v0.9.0. '
    'F1 (min-length): RAISE EXCEPTION when lesson_text < 20 chars. '
    'F2 (repetition): RAISE EXCEPTION when most-frequent token > 80%% of all tokens. '
    'F3 (dedup-warn): RAISE WARNING + RETURN existing lesson_id when cosine_sim > 0.98. '
    'v0.9.0: verified_at = NOW() for all lessons passing quality gates (NULL-embedding != ghost). '
    'Provenance tier (commit_sha, artifact_hash) still contributes to ranking aux score.';

-- =============================================================================
-- G) stats() v0.7.0 -- confidence distribution columns
-- Return-type change requires DROP + CREATE.
-- 5 new columns: confidence_mean, confidence_p10, confidence_p50, confidence_p90,
--                confidence_below_threshold_count (confidence < 0.3)
-- =============================================================================

DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                          TEXT,
    lesson_count                     BIGINT,
    embedded_count                   BIGINT,
    embedding_coverage_pct           DOUBLE PRECISION,
    tsv_coverage_pct                 DOUBLE PRECISION,
    mem_edge_count                   BIGINT,
    recency_weight                   DOUBLE PRECISION,
    ef_search                        INT,
    importance_weight                DOUBLE PRECISION,
    hybrid_enabled                   BOOLEAN,
    recall_hybrid_available          BOOLEAN,
    oldest_lesson_age_days           INT,
    orphan_count                     BIGINT,
    ghost_count                      BIGINT,
    confidence_mean                  REAL,
    confidence_p10                   REAL,
    confidence_p50                   REAL,
    confidence_p90                   REAL,
    confidence_below_threshold_count INT
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $func$
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
        (SELECT COUNT(*)::BIGINT
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         LEFT JOIN pg_depend d
             ON d.objid = p.oid AND d.deptype = 'e'
            AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
         WHERE n.nspname = 'pgmnemo'
           AND p.proname NOT LIKE '\_%' ESCAPE '\'
           AND d.objid IS NULL)                                                    AS orphan_count,
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count,
        (SELECT COALESCE(AVG(confidence), 0.5)::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_mean,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p10,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p50,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p90,
        (SELECT COUNT(*)::INT
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ
           AND confidence < 0.3)                                                   AS confidence_below_threshold_count;
$func$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.7.0 diagnostic health-check (19 columns, was 14). '
    'New columns: confidence_mean REAL, confidence_p10 REAL, confidence_p50 REAL, '
    'confidence_p90 REAL, confidence_below_threshold_count INT (lessons with confidence < 0.3). '
    'ghost_count: active lessons (t_valid_to=infinity) without provenance. '
    'orphan_count: pgmnemo-schema functions not owned by the extension. '
    'Single-row; <100ms on N=10k corpus.';

-- ─────────────────────────────────────────────────────────────────────────────
-- pgmnemo 0.7.2 → 0.8.0 delta (fresh-install inclusion)
-- ─────────────────────────────────────────────────────────────────────────────

-- S1: Schema additions — source_type + embedding_at
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS source_type TEXT
        DEFAULT 'auto_captured'
        CONSTRAINT ck_agent_lesson_source_type
            CHECK (source_type IN ('agent_authored', 'auto_captured', 'imported', 'system'));

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS embedding_at TIMESTAMPTZ;

-- Backfill embedding_at for rows that already have embeddings.
-- Use updated_at as a reasonable proxy for when the embedding was last set.
UPDATE pgmnemo.agent_lesson
SET embedding_at = updated_at
WHERE embedding IS NOT NULL
  AND embedding_at IS NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.source_type IS
    'Origin classification for this lesson. '
    'agent_authored: explicitly written by an agent. '
    'auto_captured: automatically generated from agent output (default). '
    'imported: loaded from an external system. '
    'system: created by pgmnemo internal processes.';

COMMENT ON COLUMN pgmnemo.agent_lesson.embedding_at IS
    'Timestamp of the most recent embedding update via reembed() or reembed_batch(). '
    'NULL for rows embedded before 0.8.0 (backfilled to updated_at on upgrade). '
    'Updated by reembed() and reembed_batch(); NOT updated by ingest() (use embedding_at '
    'IS NULL AND embedding IS NOT NULL to identify rows needing a refresh timestamp).';

-- ─────────────────────────────────────────────────────────────────────────────
-- S2: navigate_locate() — Budget-bounded LOCATE
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Algorithm:
--   1. raw_candidates: union of vector+BM25 candidates with JSONB predicate pushdown
--   2. rrf_ranked:     sparse-safe RRF ranks (Cormack 2009 — same as recall_hybrid)
--   3. scored:         rrf_sparse + aux(importance, recency, provenance) + graph_proximity
--   4. anchors/graph_walk/graph_proximity: BFS on causal+temporal edges (top-5 anchors)
--   5. budget_window:  SUM(length(lesson_text)) window; stop when cumulative > budget
--   6. Output:         id, score, tokens_consumed (cumulative chars up to this row),
--                      navigation_path ('vector'|'bm25'|'jsonb_gate')
--
-- navigation_path:
--   'jsonb_gate' when jsonb_filter is non-null (JSONB predicate gated the candidate set)
--   'vector'     when vec_rank <= effective_bm25_rank (vector was dominant signal)
--   'bm25'       otherwise (BM25 was dominant signal)
--
-- Budget semantics: the first row is always returned even if its length exceeds budget.
-- tokens_consumed is the cumulative char count INCLUDING the current row.
-- ─────────────────────────────────────────────────────────────────────────────

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
STABLE
PARALLEL SAFE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 2;  -- proximity scoring: 2-hop sufficient; deeper = navigate_expand
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _vec_weight         CONSTANT DOUBLE PRECISION := 0.4;
    _bm25_weight        CONSTANT DOUBLE PRECISION := 0.4;
    _raw_blend_weight   DOUBLE PRECISION;  -- v0.8.1 F2: cardinal raw score blend
BEGIN
    -- Validate: need at least one retrieval signal
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.navigate_locate: both query_embedding and query_text are NULL/empty';
    END IF;

    _rrf_k_f := 60.0;
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);  -- same order as max RRF per signal

    -- ef_search GUC
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- include_unverified GUC
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- as_of_ts GUC (bitemporal point-in-time filter)
    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN
        _as_of_ts := NULL;
    END;

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

    -- Parse query_text → tsquery
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
    -- Step 1: union candidates; JSONB predicate pushdown when jsonb_filter non-null
    raw_candidates AS (
        SELECT
            al.id,
            al.importance,
            al.created_at,
            al.commit_sha,
            al.verified_at,
            LEAST(length(al.lesson_text), 50)                                        AS text_len,
            -- vector score
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            -- P1-D fix: use stored generated columns (topic_tsv, lesson_tsv) — GIN-indexed.
            -- Was: inline to_tsvector('english', COALESCE(topic,'')) — O(n) seq-scan per row.
            -- topic_tsv GENERATED ALWAYS AS (to_tsvector('english', coalesce(topic,''))) STORED
            -- pgmnemo_agent_lesson_topic_tsv_idx GIN index on topic_tsv.
            CASE
                WHEN _has_text AND (al.lesson_tsv @@ _tsquery
                     OR al.topic_tsv @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(al.topic_tsv, 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          -- JSONB predicate pushdown — uses GIN index on metadata when non-null
          AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
          -- project_id_filter — uses B-tree index pgmnemo_agent_lesson_project_idx
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          -- bitemporal: active rows only (unless as_of_ts set)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
          -- union: matched by vector OR BM25 (including topic match)
          AND (
              (_has_vec  AND al.embedding  IS NOT NULL)
           OR (_has_text AND (al.lesson_tsv @@ _tsquery
               OR al.topic_tsv @@ _tsquery))
          )
    ),
    -- Step 2: sparse-safe RRF ranks (Cormack 2009)
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                                          AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)               AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                                       AS bm25_rank_sparse
        FROM raw_candidates
    ),
    -- Step 3: RRF score + aux tie-breaker (identical formula to recall_hybrid v0.6.2)
    scored AS (
        SELECT
            r.id,
            r.importance,
            r.created_at,
            r.commit_sha,
            r.verified_at,
            r.text_len,
            r.vec_rank,
            COALESCE(r.bm25_rank_sparse, r.n_candidates + 1) AS bm25_rank_eff,
            r.raw_vec_score,
            r.raw_bm25_score,
            -- v0.8.1 F2: ordinal RRF + cardinal raw score blend (absolute match strength survives)
            (_vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + _bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                   r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 _vec_weight  * r.raw_vec_score
               + _bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    -- Step 4: top-5 anchors for graph BFS
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    -- Step 5: BFS on active edges from top-5 anchors — BIDIRECTIONAL
    -- v0.9.1 fix: traverses ALL relation_types (was edge_kind IN causal/temporal)
    -- Bidirectional: discovers both forward and backward graph neighbors
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1,
               CASE WHEN me.source_id = gw.reached_id
                    THEN me.target_id
                    ELSE me.source_id
               END
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = gw.reached_id OR me.target_id = gw.reached_id
        )
        WHERE gw.depth < _max_depth
          -- v0.9.1 fix: handle both active-edge sentinels
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
    ),
    -- Step 6: proximity score from BFS depth
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    ),
    -- Step 7: final score = (rrf_sparse + aux) * (1 + graph); safety cap at 200 rows
    -- v0.8.1 F1: graph is multiplicative re-rank (tie-breaker, not driver)
    final_ranked AS (
        SELECT
            s.id,
            s.text_len,
            s.vec_rank,
            s.bm25_rank_eff,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0
                               )
                           )::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE                                                             0.0
                            END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
        ORDER BY (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0
                               )
                           )::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE                                                             0.0
                            END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
            DESC
        LIMIT 200  -- safety cap: prevents unbounded result sets for large corpora
    ),
    -- Step 8: budget window — cumulative char sum over score-descending order
    budget_window AS (
        SELECT
            fr.id,
            fr.final_score,
            fr.text_len,
            fr.vec_rank,
            fr.bm25_rank_eff,
            SUM(fr.text_len) OVER (
                ORDER BY fr.final_score DESC, fr.id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cum_chars,
            ROW_NUMBER() OVER (ORDER BY fr.final_score DESC, fr.id ASC) AS rn
        FROM final_ranked fr
    )
    SELECT
        bw.id                                                                         AS id,
        left(al.lesson_text, 50)                                                      AS preview,
        bw.final_score::FLOAT8                                                        AS score,
        bw.cum_chars::INT                                                             AS tokens_consumed,
        -- navigation_path: jsonb_gate if filter was applied, else dominant retrieval signal
        CASE
            WHEN jsonb_filter IS NOT NULL THEN 'jsonb_gate'
            WHEN bw.vec_rank <= bw.bm25_rank_eff THEN 'vector'
            ELSE 'bm25'
        END                                                                           AS navigation_path
    FROM budget_window bw
    JOIN pgmnemo.agent_lesson al ON al.id = bw.id
    WHERE bw.rn = 1                                    -- always return first row
       OR (bw.cum_chars - bw.text_len) < token_budget_chars   -- include while under budget
    ORDER BY bw.final_score DESC, bw.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT) IS
    'Token-economy navigation LOCATE (v0.9.1). '
    'Ranks lessons using the same hybrid RRF+aux+graph formula as recall_hybrid. '
    'v0.9.1 fixes: (1) graph_walk now traverses ALL relation_types bidirectionally '
    '(was edge_kind IN causal/temporal — missed production edges with edge_kind=semantic); '
    '(2) raw_candidates uses stored topic_tsv column (GIN-indexed) instead of inline '
    'to_tsvector recompute — eliminates O(n) seq-scan on topic for BM25 match. '
    'Returns id/preview/score/tokens_consumed/navigation_path — preview is first ~50 chars. '
    'token_budget_chars: cumulative Unicode character (code-point) limit on delivered previews; '
    'first row always returned regardless of budget. '
    'jsonb_filter: WHERE metadata @> jsonb_filter pushed into candidate scan (uses GIN index). '
    'project_id_filter: scopes candidates to a single project (uses B-tree index). '
    'navigation_path: ''jsonb_gate'' when filter applied; ''vector'' when vec dominant; ''bm25'' otherwise. '
    'Combine with navigate_expand() to retrieve content for chosen IDs.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S3: navigate_expand() — On-demand content + graph expansion
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Returns full lesson_text for caller-chosen IDs.
-- If expand_fields non-empty: projects those keys from metadata JSONB into expand_detail.
-- If graph_expand_depth >= 1: recursively follows edges from input IDs,
--   only traversing edges with weight >= graph_expand_threshold.
--   relation_types: NULL = traverse ALL active edges; or pass specific relation_type values.
--   Bidirectional BFS: discovers both forward and backward relations.
--   Neighbour rows get navigation_path='graph_expand'; direct rows get 'content'.
--   Deduplication: input IDs always take priority (navigation_path='content').
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand(
    ids                    BIGINT[],
    expand_fields          TEXT[]           DEFAULT '{}',
    graph_expand_depth     INT              DEFAULT 1,
    graph_expand_threshold FLOAT            DEFAULT 0.5,
    relation_types         TEXT[]           DEFAULT NULL
)
RETURNS TABLE (
    id                      BIGINT,
    content                 TEXT,
    expand_detail           JSONB,
    graph_neighbor_ids      BIGINT[],
    graph_neighbor_previews TEXT[],
    tokens_consumed         INT,
    navigation_path         TEXT
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
BEGIN
    IF ids IS NULL OR array_length(ids, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    -- Step 1: seed rows — the requested IDs
    seed_rows AS (
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, al.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE al.metadata ? f
                )
                ELSE NULL::JSONB
            END                                                            AS expand_detail,
            'content'::TEXT                                                AS navigation_path,
            0                                                              AS depth,
            ARRAY[al.id]                                                   AS path
        FROM pgmnemo.agent_lesson al
        WHERE al.id = ANY(ids)
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
    ),
    -- Step 2: BFS graph expansion — BIDIRECTIONAL, relation_type-gated, weight-gated
    graph_expand (node_id, lesson_text, metadata, depth, path) AS (
        -- Seed: input IDs
        SELECT
            sr.id,
            sr.lesson_text,
            sr.metadata,
            0,
            sr.path
        FROM seed_rows sr

        UNION ALL

        -- Recursive: traverse edges in BOTH directions, gated by relation_type + weight
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            ge.depth + 1,
            ge.path || al.id
        FROM graph_expand ge
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = ge.node_id OR me.target_id = ge.node_id
        )
        JOIN pgmnemo.agent_lesson al ON al.id = CASE
            WHEN me.source_id = ge.node_id THEN me.target_id
            ELSE me.source_id
        END
        WHERE graph_expand_depth >= 1
          AND ge.depth < graph_expand_depth
          -- B1 fix: filter by relation_type (the real discriminator)
          -- NULL relation_types = traverse ALL active edges (no type filter)
          AND (relation_types IS NULL OR me.relation_type = ANY(relation_types))
          -- Weight gate: configurable threshold (default 0.5)
          AND me.weight >= graph_expand_threshold::REAL
          -- B2 fix: handle both active-edge sentinel conventions
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
          -- Target lesson must be active
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          -- Cycle guard: prevent revisiting nodes already in path
          AND NOT (al.id = ANY(ge.path))
    ),
    -- Step 3: collect expanded rows (exclude IDs already in seed)
    expanded_rows AS (
        SELECT DISTINCT ON (ge.node_id)
            ge.node_id                                                         AS id,
            ge.lesson_text,
            ge.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, ge.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE ge.metadata ? f
                )
                ELSE NULL::JSONB
            END                                                                AS expand_detail,
            'graph_expand'::TEXT                                               AS navigation_path
        FROM graph_expand ge
        WHERE ge.depth > 0                         -- only expansion rows, not seeds
          AND NOT (ge.node_id = ANY(ids))          -- exclude original input IDs
        ORDER BY ge.node_id, ge.depth ASC          -- prefer shallower depth
    ),
    -- Step 4b: deduplicated BFS neighbors per seed (all depths)
    distinct_neighbors AS (
        SELECT DISTINCT ON (ge.path[1], ge.node_id)
            ge.path[1]                                     AS seed_id,
            ge.node_id,
            ge.depth,
            left(ge.lesson_text, 50)                       AS neighbor_preview
        FROM graph_expand ge
        WHERE ge.depth > 0
          AND NOT (ge.node_id = ANY(ids))
        ORDER BY ge.path[1], ge.node_id, ge.depth ASC
    ),
    -- Step 4c: aggregate neighbors per seed — positional correspondence guaranteed
    neighbor_summary AS (
        SELECT
            dn.seed_id,
            array_agg(dn.node_id ORDER BY dn.depth, dn.node_id)          AS neighbor_ids,
            array_agg(dn.neighbor_preview ORDER BY dn.depth, dn.node_id) AS neighbor_previews
        FROM distinct_neighbors dn
        GROUP BY dn.seed_id
    ),
    -- Step 5: union seed + expanded, seed takes priority on id collision
    combined AS (
        SELECT sr.id,
               sr.lesson_text                                  AS content,
               sr.expand_detail,
               ns.neighbor_ids                                 AS graph_neighbor_ids,
               ns.neighbor_previews                            AS graph_neighbor_previews,
               sr.navigation_path
        FROM seed_rows sr
        LEFT JOIN neighbor_summary ns ON ns.seed_id = sr.id

        UNION ALL

        SELECT er.id,
               er.lesson_text                                  AS content,
               er.expand_detail,
               NULL::BIGINT[]                                  AS graph_neighbor_ids,
               NULL::TEXT[]                                     AS graph_neighbor_previews,
               er.navigation_path
        FROM expanded_rows er
    )
    -- Step 6: attach cumulative tokens_consumed
    SELECT
        c.id,
        c.content,
        c.expand_detail,
        c.graph_neighbor_ids,
        c.graph_neighbor_previews,
        SUM(length(c.content)) OVER (
            ORDER BY c.id ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )::INT                                                 AS tokens_consumed,
        c.navigation_path
    FROM combined c
    ORDER BY c.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_expand(BIGINT[], TEXT[], INT, FLOAT, TEXT[]) IS
    'Token-economy navigation EXPAND (v0.9.1). '
    'Returns full lesson_text + JSONB expansion for caller-chosen IDs. '
    'v0.9.1 fixes: '
    '(B1) relation_type filter replaces broken edge_kind filter — production edges had '
    'edge_kind=semantic for ALL types due to unmapped relation_types in backfill; '
    '(B2) valid_until handles both NULL and infinity sentinel conventions; '
    '(B3) bidirectional BFS — agent can discover backward relations (e.g. find cause '
    'from an effect by traversing CAUSED_BY edges in reverse); '
    '(B4) relation_types TEXT[] param — NULL traverses all, or pass specific types. '
    'Threshold default lowered: 0.5 (was 0.7) — navigation should be permissive; '
    'agent decides which connections to follow. '
    'Combine with navigate_locate() for the locate→connections→expand loop.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S4: reembed() — Single-row embedding refresh
-- ─────────────────────────────────────────────────────────────────────────────
--
-- UPDATE-only: bitemporal trigger (_close_prior_version) fires on INSERT only.
-- lesson_tsv trigger fires on UPDATE OF lesson_text only — not triggered here.
-- _set_updated_at trigger fires on UPDATE — updates updated_at correctly.
-- Does NOT create a new row, does NOT change lesson_text/content_hash/id.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reembed(
    p_lesson_id  BIGINT,
    p_new_vector vector(1024)
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_new_vector IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.reembed: p_new_vector must not be NULL';
    END IF;

    IF vector_dims(p_new_vector) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.reembed: expected 1024 dims, got %',
            vector_dims(p_new_vector);
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET embedding    = p_new_vector,
        embedding_at = now()
    WHERE id         = p_lesson_id
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reembed: lesson % not found or not active', p_lesson_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.reembed(BIGINT, vector) IS
    'Refresh the embedding for a single active lesson (v0.8.0). '
    'Updates embedding + embedding_at without creating a new bitemporal row. '
    'Safe to call concurrently with ingest(): UPDATE does not fire the INSERT-only '
    '_close_prior_version trigger. Raises if lesson not found or not active. '
    'For batch refresh see reembed_batch().';

-- ─────────────────────────────────────────────────────────────────────────────
-- S5: reembed_batch() — Batch embedding refresh
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Processes IDs in the order given. Caller SHOULD pass IDs in ascending order
-- to prevent deadlocks with other batch jobs.
-- FOR UPDATE SKIP LOCKED: skips rows locked by concurrent ingest()/reinforce().
-- Returns count of successfully updated rows (< input length if rows were skipped).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reembed_batch(
    p_lesson_ids  BIGINT[],
    p_new_vectors vector[]
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    _count  INT := 0;
    _i      INT;
    _locked BIGINT;
BEGIN
    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    IF array_length(p_lesson_ids, 1) <> array_length(p_new_vectors, 1) THEN
        RAISE EXCEPTION
            'pgmnemo.reembed_batch: ids length (%) differs from vectors length (%)',
            array_length(p_lesson_ids, 1),
            array_length(p_new_vectors, 1);
    END IF;

    FOR _i IN 1..array_length(p_lesson_ids, 1) LOOP
        -- Acquire row lock; skip rows held by concurrent writers
        SELECT id INTO _locked
        FROM pgmnemo.agent_lesson
        WHERE id         = p_lesson_ids[_i]
          AND is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
        FOR UPDATE SKIP LOCKED;

        IF FOUND THEN
            UPDATE pgmnemo.agent_lesson
            SET embedding    = p_new_vectors[_i],
                embedding_at = now()
            WHERE id = p_lesson_ids[_i];
            _count := _count + 1;
        END IF;
    END LOOP;

    RETURN _count;
END;
$$;

COMMENT ON FUNCTION pgmnemo.reembed_batch(BIGINT[], vector[]) IS
    'Batch embedding refresh for multiple lessons (v0.8.0). '
    'ids and vectors arrays must have the same length. '
    'Uses FOR UPDATE SKIP LOCKED: skips rows held by concurrent ingest()/reinforce(). '
    'Returns count of rows actually updated (may be < input length if rows were skipped). '
    'Lock ordering: pass IDs in ascending order to prevent deadlocks across concurrent batches. '
    'Each row processed independently — partial success is normal and expected under load.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S6: recompute_content() — In-place lesson_text update
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Automatic cascade on UPDATE OF lesson_text:
--   content_hash: GENERATED ALWAYS AS (MD5(...||lesson_text)) — PG recomputes automatically.
--   lesson_tsv:   pgmnemo_agent_lesson_tsv_trg fires on UPDATE OF lesson_text → refreshed.
--   updated_at:   _set_updated_at trigger fires on any UPDATE → refreshed.
-- Does NOT fire _close_prior_version (INSERT-only trigger).
-- Preserves: id, embedding, edges, provenance, confidence, source_type.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recompute_content(
    p_lesson_id BIGINT,
    p_new_text  TEXT
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_new_text IS NULL OR length(trim(p_new_text)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.recompute_content: p_new_text must be non-empty';
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET lesson_text = p_new_text
    WHERE id        = p_lesson_id
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'pgmnemo.recompute_content: lesson % not found or not active',
            p_lesson_id;
    END IF;
    -- content_hash recomputed automatically (GENERATED ALWAYS AS).
    -- lesson_tsv refreshed automatically (UPDATE OF lesson_text trigger).
    -- updated_at refreshed automatically (_set_updated_at trigger).
    -- No new row created (_close_prior_version is INSERT-only).
END;
$$;

COMMENT ON FUNCTION pgmnemo.recompute_content(BIGINT, TEXT) IS
    'In-place lesson_text update without bitemporal close+create churn (v0.8.0). '
    'Cascade: content_hash recomputed (GENERATED ALWAYS AS), lesson_tsv refreshed '
    '(pgmnemo_agent_lesson_tsv_trg), updated_at refreshed (_set_updated_at). '
    'Preserves: id, embedding, mem_edges, provenance, confidence, source_type. '
    'Raises if lesson not found or not active (t_valid_to = infinity). '
    'Note: embedding remains stale after this call; follow up with reembed() if needed.';

-- ============================================================
-- pgmnemo 0.8.2 upgrade: F1 + F2 (appended from 0.8.1--0.8.2)
-- ============================================================
-- pgmnemo upgrade script: 0.8.1 → 0.8.2
-- SPDX-License-Identifier: Apache-2.0
--
-- Fixes:
--   F1 — traverse_temporal_window: unify include_unverified parsing to
--         COALESCE(current_setting(...)::BOOLEAN, FALSE), matching all other
--         recall functions (accepts on/true/1/yes, not just 'on').
--   F2 — recall_lessons + recall_hybrid: RAISE NOTICE when 0 rows returned
--         but ghost lessons (verified_at IS NULL) exist in scope, guiding
--         adopters to SET pgmnemo.include_unverified = 'on'.
--
-- All changes are body-only; no schema changes; no scoring/ranking change.

-- =============================================================================
-- F1: traverse_temporal_window — fix include_unverified parsing
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.traverse_temporal_window(
    start_id            BIGINT,
    window_interval     INTERVAL    DEFAULT INTERVAL '15 minutes',
    include_unlinked    BOOLEAN     DEFAULT TRUE,
    role_filter         TEXT        DEFAULT NULL,
    project_id_filter   INT         DEFAULT NULL,
    k                   INT         DEFAULT 20
)
RETURNS TABLE (
    lesson_id       BIGINT,
    time_delta_sec  DOUBLE PRECISION,
    linked          BOOLEAN,
    edge_weight     REAL,
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
DECLARE
    _start_ts           TIMESTAMPTZ;
    _include_unverified BOOLEAN;
BEGIN
    SELECT al.created_at INTO _start_ts
    FROM pgmnemo.agent_lesson al
    WHERE al.id = start_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- F1 fix: use ::BOOLEAN cast (accepts on/true/1/yes) not string-compare = 'on'
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    RETURN QUERY
    WITH candidates AS (
        SELECT
            al.id,
            al.role,
            al.topic,
            al.lesson_text,
            al.importance,
            al.created_at,
            al.commit_sha,
            al.verified_at,
            ABS(EXTRACT(EPOCH FROM (al.created_at - _start_ts))) AS delta_sec
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.id <> start_id
          AND al.created_at BETWEEN (_start_ts - window_interval)
                                AND (_start_ts + window_interval)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter         IS NULL OR al.role       = role_filter)
          AND (project_id_filter   IS NULL OR al.project_id = project_id_filter)
    ),
    edges AS (
        SELECT e.target_id AS other_id, e.weight
        FROM pgmnemo.mem_edge e
        WHERE e.source_id = start_id
          AND e.valid_until IS NULL
        UNION ALL
        SELECT e.source_id AS other_id, e.weight
        FROM pgmnemo.mem_edge e
        WHERE e.target_id = start_id
          AND e.valid_until IS NULL
    )
    SELECT
        c.id                            AS lesson_id,
        c.delta_sec                     AS time_delta_sec,
        (e.weight IS NOT NULL)          AS linked,
        e.weight                        AS edge_weight,
        c.role,
        c.topic,
        c.lesson_text,
        c.importance,
        c.created_at,
        c.commit_sha,
        c.verified_at
    FROM candidates c
    LEFT JOIN edges e ON e.other_id = c.id
    WHERE include_unlinked OR e.weight IS NOT NULL
    ORDER BY c.delta_sec ASC, c.importance DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_temporal_window(BIGINT, INTERVAL, BOOLEAN, TEXT, INT, INT) IS
    'Return up to k agent_lesson rows whose created_at falls within ±window_interval of start_id. '
    'linked=TRUE when a mem_edge (any direction) exists between that row and start_id. '
    'include_unlinked=FALSE restricts output to explicitly connected lessons. '
    'v0.8.2 F1: include_unverified parsed via ::BOOLEAN (accepts on/true/1/yes).';


-- =============================================================================
-- F2: recall_hybrid — ghost guidance NOTICE when 0 rows returned
-- =============================================================================

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
STABLE
PARALLEL SAFE
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
    _ghost_count        INT;   -- F2: ghost guidance
    _fetch_k_vec        INT;   -- #4: bounded HNSW fetch
    _fetch_k_bm25       INT;   -- #4: bounded BM25 fetch
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
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding   -- HNSW index scan
        LIMIT _fetch_k_vec                           -- C2: GREATEST(k*4, _ef_search)
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
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY raw_bm25_score DESC
        LIMIT _fetch_k_bm25                          -- C2: GREATEST(k*4, 40)
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
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)   AS vec_rank,
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
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    )
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
    ORDER BY f.final_score DESC, f.id ASC   -- C7: tie-breaker for determinism
    LIMIT k;

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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.9.0 — two bounded CTEs: HNSW vec + GIN BM25 (O(k log n) not O(n)). '
    'vec arm: LIMIT GREATEST(k*4, ef_search). bm25 arm: LIMIT GREATEST(k*4, 40). '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Scoring: rrf_sparse + _aux_scale*(0.025*imp/5 + 0.025*conf + 0.05*recency + 0.05*prov) + delta*graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'graph_proximity contributes only when mem_edge is populated; with no edges the graph term is 0. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '#4 inclusion gated on host BENCHMARK; may revert to 0.9.1 by founder decision. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL).';


-- =============================================================================
-- F2: recall_lessons (v0.7.0, 6-arg) — ghost guidance NOTICE on vector-only path
-- Note: hybrid path delegates to recall_hybrid which issues its own notice;
--       ghost check here covers the vector-only path only (avoids double notice).
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
    as_of_ts          TIMESTAMPTZ DEFAULT NULL
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
STABLE
PARALLEL SAFE
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
    _ghost_count        INT;   -- F2: ghost guidance
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

    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        -- Hybrid path: delegate to recall_hybrid (which issues its own ghost notice on 0 rows)
        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60
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
    )
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
    LIMIT k;

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

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.8.2 — F2: NOTICE when 0 rows returned (vector-only path) and ghost lessons exist in scope. '
    'v0.7.0 -- confidence integration + footgun guard + match_confidence. '
    'Scoring (vector path): 0.5*vec + 0.15*imp/5 + 0.15*confidence + gamma*recency + 0.1*prov + delta*graph. '
    'confidence: outcome-track-record [0,1] from reinforce(). '
    'match_confidence: LEAST(1.0, GREATEST(0.0, score/1.5)) -- interpretable [0,1] quality indicator. '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL and text-only fallback active. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL). '
    'Named-column callers unaffected; positional callers: re-audit for 2 new trailing cols.';
