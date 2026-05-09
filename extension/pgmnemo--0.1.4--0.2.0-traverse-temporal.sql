-- pgmnemo upgrade: 0.1.4 → 0.2.0-traverse-temporal
-- Adds traverse_temporal_window() SP (RFC §5): co-temporal episode discovery.
-- Requires: pgmnemo.mem_edge table (delivered by 0.2.0-mem-edge step).
-- SPDX-License-Identifier: Apache-2.0

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
    time_delta_sec  DOUBLE PRECISION,   -- abs(created_at - start.created_at) in seconds
    linked          BOOLEAN,            -- TRUE if any mem_edge exists to/from start_id
    edge_weight     REAL,               -- mem_edge.weight if linked, else NULL
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
    -- Reference anchor: read created_at for start_id (RFC §5.3 rule 1)
    SELECT al.created_at INTO _start_ts
    FROM pgmnemo.agent_lesson al
    WHERE al.id = start_id;

    -- Fail-safe: start_id not found → return zero rows
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Ghost-lesson exclusion: honour pgmnemo.include_unverified GUC (RFC §5.3 rule 7)
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
          -- Time window: ±window_interval around anchor (RFC §5.3 rule 2)
          AND al.created_at BETWEEN (_start_ts - window_interval)
                                AND (_start_ts + window_interval)
          -- Ghost-lesson exclusion (RFC §5.3 rule 7)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          -- Optional filters (RFC §5.3 rule 6)
          AND (role_filter         IS NULL OR al.role       = role_filter)
          AND (project_id_filter   IS NULL OR al.project_id = project_id_filter)
    ),
    -- Edges in either direction between start_id and each candidate (RFC §5.3 rule 3)
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
    -- include_unlinked=FALSE: only rows with an explicit edge (RFC §5.3 rule 4)
    WHERE include_unlinked OR e.weight IS NOT NULL
    -- Closest in time first, then highest importance (RFC §5.3 rule 5)
    ORDER BY c.delta_sec ASC, c.importance DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_temporal_window(BIGINT, INTERVAL, BOOLEAN, TEXT, INT, INT) IS
    'RFC §5 v0.2.0: return up to k agent_lesson rows whose created_at falls within '
    '±window_interval of start_id. linked=TRUE when any active mem_edge exists (either '
    'direction) between that row and start_id. include_unlinked=FALSE restricts to '
    'explicitly connected lessons. Ghost-lesson exclusion via pgmnemo.include_unverified '
    'GUC (default off). Returns zero rows if start_id missing.';
