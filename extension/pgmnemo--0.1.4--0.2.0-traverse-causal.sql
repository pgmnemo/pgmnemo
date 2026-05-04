-- pgmnemo upgrade: 0.1.4 → 0.2.0-traverse-causal
-- Adds traverse_causal_chain() SP for recursive causal/derivation/contradiction traversal.
-- SPDX-License-Identifier: Apache-2.0

CREATE OR REPLACE FUNCTION pgmnemo.traverse_causal_chain(
    start_id  BIGINT,
    max_depth INT DEFAULT 5
)
RETURNS TABLE (
    depth      INT,
    lesson_id  BIGINT,
    edge_type  TEXT,
    weight     DOUBLE PRECISION
)
LANGUAGE SQL
STABLE
PARALLEL SAFE
AS $$
  WITH RECURSIVE chain AS (
    SELECT
        0                AS depth,
        source_id        AS lesson_id,
        NULL::TEXT       AS edge_type,
        1.0              AS weight
    FROM pgmnemo.agent_lesson
    WHERE id = start_id

    UNION ALL

    SELECT
        c.depth + 1,
        e.target_id,
        e.edge_type,
        e.weight
    FROM chain c
    JOIN pgmnemo.mem_edge e ON e.source_id = c.lesson_id
    WHERE e.edge_type IN ('causal', 'derives_from', 'contradicts')
      AND c.depth < CASE WHEN max_depth > 10 THEN 10 ELSE max_depth END
  )
  SELECT depth, lesson_id, edge_type, weight
  FROM chain
  WHERE depth > 0;
$$;

COMMENT ON FUNCTION pgmnemo.traverse_causal_chain(BIGINT, INT) IS
    'v0.2.0: traverse causal/derivation/contradiction edges from start_id up to max_depth.';
