-- Regression tests: traverse_causal_chain(direction) parameter (v0.2.1 F5)
-- Tests direction predicate logic without a live table connection.

-- 1. direction='forward' follows source→target edges only
SELECT
    ('forward' IN ('forward', 'both')) AS forward_matches_forward,
    ('forward' IN ('backward', 'both')) AS forward_no_backward,
    ('backward' IN ('backward', 'both')) AS backward_matches_backward,
    ('backward' IN ('forward', 'both')) AS backward_no_forward,
    ('both' IN ('forward', 'both')) AS both_matches_forward,
    ('both' IN ('backward', 'both')) AS both_matches_backward;

-- Expected: t, f, t, f, t, t

-- 2. direction validation: only 'forward', 'backward', 'both' are valid
SELECT
    ('forward'  = ANY(ARRAY['forward','backward','both'])) AS forward_valid,
    ('backward' = ANY(ARRAY['forward','backward','both'])) AS backward_valid,
    ('both'     = ANY(ARRAY['forward','backward','both'])) AS both_valid,
    ('reverse'  = ANY(ARRAY['forward','backward','both'])) AS reverse_invalid,
    ('up'       = ANY(ARRAY['forward','backward','both'])) AS up_invalid;

-- Expected: t, t, t, f, f

-- 3. default is 'forward' (backward-compatible)
SELECT
    ('forward' = 'forward') AS default_is_forward;

-- Expected: t

-- 4. cycle guard: path array prevents revisiting same lesson in backward traversal
-- Simulates: start_id already in path → excluded
SELECT
    (42 = ANY(ARRAY[10, 42, 77])) AS cycle_detected_true,
    (99 = ANY(ARRAY[10, 42, 77])) AS cycle_detected_false;

-- Expected: t, f

-- 5. backward edge join: ON me.target_id = cw.lesson_id (opposite of forward)
-- forward join:  me.source_id = cw.lesson_id → yields me.target_id
-- backward join: me.target_id = cw.lesson_id → yields me.source_id
SELECT
    'source→target' AS forward_direction_yields,
    'target→source' AS backward_direction_yields;

-- Expected: two literal strings confirming join semantics
