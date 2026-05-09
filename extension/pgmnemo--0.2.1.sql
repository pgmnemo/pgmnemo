-- pgmnemo 0.2.1 — flat install script (fresh CREATE EXTENSION target)
-- Squashes the full upgrade chain 0.0.1 → 0.2.1 into a single idempotent DDL file.
-- Upgrade path (ALTER EXTENSION … UPDATE TO '0.2.1') remains supported via the
-- individual pgmnemo--<from>--<to>.sql scripts.
-- SPDX-License-Identifier: Apache-2.0

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
                'Supply at least one provenance field, or SET pgmnemo.gate_strict = ''warn'' '
                'to allow unprovenanced writes with an audit warning.';
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
-- Core table: agent_lesson (all columns from v0.0.1 through v0.2.1)
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
    expires_at       TIMESTAMPTZ
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
-- v0.2.0: mem_edge — directed typed edges between agent_lesson rows
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE pgmnemo.mem_edge (
    id              BIGSERIAL       PRIMARY KEY,
    source_id       BIGINT          NOT NULL
                        REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    target_id       BIGINT          NOT NULL
                        REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    relation_type   TEXT            NOT NULL,

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
    'Directed typed edges between agent_lesson rows. '
    'Built-in relation_type vocabulary: CAUSED_BY, SUPERSEDES, CO_OCCURRED, DERIVED_FROM. '
    'User-defined types are allowed (no enum constraint). '
    'valid_until IS NULL = currently valid edge.';

CREATE INDEX pgmnemo_mem_edge_source_type_idx
    ON pgmnemo.mem_edge (source_id, relation_type)
    WHERE valid_until IS NULL;

CREATE INDEX pgmnemo_mem_edge_target_type_idx
    ON pgmnemo.mem_edge (target_id, relation_type)
    WHERE valid_until IS NULL;

CREATE INDEX pgmnemo_mem_edge_valid_range_idx
    ON pgmnemo.mem_edge (valid_from, valid_until);

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

-- recall_lessons() — v0.2.1: full graph-proximity mixin + ef_search GUC
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
    'Hybrid recall v0.2.1 — formula: '
    '0.4×cosine + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength + δ×graph_proximity. '
    'γ = pgmnemo.recency_weight (default 0.08). '
    'δ = pgmnemo.graph_proximity_weight (default 0.2, range 0.0–0.5). '
    'ef_search = pgmnemo.ef_search GUC (default 100, applied via SET LOCAL).';

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

-- traverse_causal_chain() — v0.2.1 with direction parameter
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
    'Cycle guard via path array. New in v0.2.1: direction parameter.';

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
