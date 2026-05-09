-- pgmnemo upgrade: 0.1.4.1 → 0.2.0
-- 0.1.4.1 is identical to 0.1.4 except for the role_filter rename in recall_lessons().
-- The 0.1.4 → 0.2.0 DDL is fully idempotent (IF NOT EXISTS guards), so this script
-- can safely duplicate it.
-- PGMNEMO-HOTFIX-1 (role_filter rename) is already applied at 0.1.4.1; no action needed here.
-- SPDX-License-Identifier: Apache-2.0
-- Delivers three v0.2.0 primitives (RFC §3–§5):
--   § 3 mem_edge DDL — directed typed edges between agent_lesson rows
--   § 4 traverse_causal_chain() — recursive CTE walk of CAUSED_BY graph
--   § 5 traverse_temporal_window() — co-temporal episode discovery
-- RFC reference: spec/v2/pgmnemo/PGMNEMO_V0.2.0_RFC.md
-- SPDX-License-Identifier: Apache-2.0

-- ─────────────────────────────────────────────────────────────────
-- § 3  pgmnemo.mem_edge DDL
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS pgmnemo.mem_edge (
    id              BIGSERIAL       PRIMARY KEY,
    source_id       BIGINT          NOT NULL
                        REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    target_id       BIGINT          NOT NULL
                        REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    relation_type   TEXT            NOT NULL,
    -- CAUSED_BY | SUPERSEDES | CO_OCCURRED | DERIVED_FROM | user-defined

    -- Bitemporality (mirrors Agency mem.mem_edge)
    valid_from      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    valid_until     TIMESTAMPTZ,               -- NULL = currently valid

    -- Edge strength/confidence [0.0, 1.0]
    weight          REAL            NOT NULL DEFAULT 1.0
                        CHECK (weight BETWEEN 0.0 AND 1.0),

    -- Provenance — required by extension gate discipline
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

-- Forward traversal: source → all outbound edges of a given type
CREATE INDEX IF NOT EXISTS pgmnemo_mem_edge_source_type_idx
    ON pgmnemo.mem_edge (source_id, relation_type)
    WHERE valid_until IS NULL;

-- Reverse traversal: target → all inbound edges
CREATE INDEX IF NOT EXISTS pgmnemo_mem_edge_target_type_idx
    ON pgmnemo.mem_edge (target_id, relation_type)
    WHERE valid_until IS NULL;

-- Temporal range scans (traverse_temporal_window)
CREATE INDEX IF NOT EXISTS pgmnemo_mem_edge_valid_range_idx
    ON pgmnemo.mem_edge (valid_from, valid_until);

CREATE TRIGGER mem_edge_updated_at
    BEFORE UPDATE ON pgmnemo.mem_edge
    FOR EACH ROW EXECUTE FUNCTION pgmnemo._set_updated_at();

-- ─────────────────────────────────────────────────────────────────
-- § 4  traverse_causal_chain()
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.traverse_causal_chain(
    start_id        BIGINT,
    max_depth       INT     DEFAULT 5,
    relation_types  TEXT[]  DEFAULT ARRAY['CAUSED_BY'],
    only_active     BOOLEAN DEFAULT TRUE
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
    -- Fail-safe: return zero rows if start_id does not exist
    IF NOT EXISTS (SELECT 1 FROM pgmnemo.agent_lesson WHERE id = start_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE chain AS (
        -- Base case: start node
        SELECT
            start_id            AS c_lesson_id,
            0                   AS c_depth,
            ARRAY[start_id]     AS c_path,
            1.0::REAL           AS c_path_weight
        UNION ALL
        -- Recursive step: follow outbound edges
        SELECT
            e.target_id,
            c.c_depth + 1,
            c.c_path || e.target_id,
            c.c_path_weight * e.weight
        FROM chain c
        JOIN pgmnemo.mem_edge e ON e.source_id = c.c_lesson_id
        WHERE e.relation_type = ANY(relation_types)
          AND (NOT only_active OR e.valid_until IS NULL)
          AND c.c_depth < max_depth
          AND NOT (e.target_id = ANY(c.c_path))  -- cycle guard
    )
    SELECT
        c.c_lesson_id,
        c.c_depth,
        c.c_path,
        c.c_path_weight,
        al.role,
        al.topic,
        al.lesson_text,
        al.importance,
        al.created_at,
        al.commit_sha,
        al.verified_at
    FROM chain c
    JOIN pgmnemo.agent_lesson al ON al.id = c.c_lesson_id
    WHERE c.c_lesson_id <> start_id
    ORDER BY c.c_depth, c.c_path_weight DESC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN) IS
    'Walk the directed CAUSED_BY (or caller-specified) edge graph from start_id up to max_depth hops. '
    'Returns all lessons in the chain excluding the start node. '
    'Cycle-safe via accumulated path array. Fail-safe: returns zero rows if start_id missing.';

-- ─────────────────────────────────────────────────────────────────
-- § 5  traverse_temporal_window()
-- ─────────────────────────────────────────────────────────────────

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
    -- Reference anchor: read created_at for start_id
    SELECT al.created_at INTO _start_ts
    FROM pgmnemo.agent_lesson al
    WHERE al.id = start_id;

    -- Fail-safe: start_id not found → return zero rows
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Ghost-lesson exclusion: honour pgmnemo.include_unverified GUC
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
    -- Edges in either direction between start_id and each candidate
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
    'Ghost-lesson exclusion controlled by pgmnemo.include_unverified GUC (default off). '
    'Returns zero rows if start_id is missing. Fail-safe: missing GUC treated as off.';
