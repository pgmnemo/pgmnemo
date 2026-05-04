-- pgmnemo upgrade: 0.1.4 → 0.2.0-traverse-temporal
-- Adds traverse_temporal_window() SP for temporal-edge traversal within a time window.
-- SPDX-License-Identifier: Apache-2.0

CREATE OR REPLACE FUNCTION pgmnemo.traverse_temporal_window(
    start_id         BIGINT,
    window_interval  INTERVAL DEFAULT INTERVAL '7 days',
    include_unlinked BOOLEAN  DEFAULT FALSE,
    role_filter      TEXT     DEFAULT NULL
)
RETURNS TABLE (
    lesson_id      BIGINT,
    time_delta_sec DOUBLE PRECISION,
    edge_weight    DOUBLE PRECISION,
    linked         BOOLEAN
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _capped_interval INTERVAL;
    _anchor_ts       TIMESTAMPTZ;
BEGIN
    -- Hard cap: window_interval may not exceed 30 days.
    _capped_interval := LEAST(window_interval, INTERVAL '30 days');

    SELECT al.created_at
    INTO   _anchor_ts
    FROM   pgmnemo.agent_lesson al
    WHERE  al.id = start_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        al.id                                                         AS lesson_id,
        ABS(EXTRACT(EPOCH FROM (al.created_at - _anchor_ts)))::DOUBLE PRECISION AS time_delta_sec,
        e.weight                                                      AS edge_weight,
        (e.weight IS NOT NULL)                                        AS linked
    FROM pgmnemo.agent_lesson al
    LEFT JOIN pgmnemo.mem_edge e
           ON e.edge_type = 'temporal'
          AND (   (e.source_id = start_id AND e.target_id = al.id)
               OR (e.target_id = start_id AND e.source_id = al.id))
    WHERE al.id <> start_id
      AND al.is_active
      AND al.created_at BETWEEN (_anchor_ts - _capped_interval)
                             AND (_anchor_ts + _capped_interval)
      AND (role_filter IS NULL OR al.role = role_filter)
      AND (include_unlinked OR e.weight IS NOT NULL);
END;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_temporal_window(BIGINT, INTERVAL, BOOLEAN, TEXT) IS
    'v0.2.0: return lessons connected via temporal edges within window_interval of start_id. Window capped at 30 days.';
