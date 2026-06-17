-- confidence_boost_guc.sql
-- pg_regress tests for pgmnemo v0.9.2 I1: confidence-weighted recall ranking
--
-- Coverage:
--   T1: GUC default (unset → function reads 0.0 = OFF)
--   T2: GUC ON (0.003) — high-confidence lesson (0.9) ranks first
--   T3: Cold-start (0.5) gets zero boost — ranking position unchanged
--   T4: Flag OFF regression — GUC=0.0 ordering identical to GUC unset
--   T5: Score spread with GUC ON is materially larger than with GUC OFF

-- Prerequisites: pgmnemo installed. Uses text-only recall (NULL embedding).
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

ALTER EXTENSION pgmnemo UPDATE TO '0.9.2';

-- =============================================================================
-- Setup: three lessons with identical text but different confidence.
-- Text-only path avoids needing real embeddings.
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence)
VALUES
    ('tc_i1', 'boost_test', 'confidence boost guc integration test xylophone zebra alpha bravo charlie delta echo', 0.9),
    ('tc_i1', 'boost_test', 'confidence boost guc integration test xylophone zebra alpha bravo charlie delta echo', 0.1),
    ('tc_i1', 'boost_test', 'confidence boost guc integration test xylophone zebra alpha bravo charlie delta echo', 0.5);

-- =============================================================================
-- T1: GUC default — unset returns empty string (function defaults to 0.0)
-- =============================================================================

RESET pgmnemo.confidence_boost_weight;
SELECT current_setting('pgmnemo.confidence_boost_weight', TRUE) IS NULL
    OR current_setting('pgmnemo.confidence_boost_weight', TRUE) = ''
    AS guc_default_is_unset;

-- =============================================================================
-- T2: GUC ON (0.003) — top result has confidence 0.9
-- =============================================================================

SET pgmnemo.confidence_boost_weight = '0.003';
SELECT (s.confidence = 0.9) AS top_is_high_confidence
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'confidence boost guc integration test xylophone zebra',
    1, 'tc_i1', NULL
) s;

-- T2b: bottom result (of 3) has confidence 0.1
SELECT (s.confidence = 0.1) AS bottom_is_low_confidence
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'confidence boost guc integration test xylophone zebra',
    3, 'tc_i1', NULL
) s
ORDER BY s.score ASC
LIMIT 1;

RESET pgmnemo.confidence_boost_weight;

-- =============================================================================
-- T3: Cold-start (0.5) score unchanged by GUC activation
-- Use a single transaction to freeze NOW() for recency comparison.
-- =============================================================================

BEGIN;
    -- Score with GUC OFF
    RESET pgmnemo.confidence_boost_weight;
    CREATE TEMP TABLE _t3_off AS
    SELECT score FROM pgmnemo.recall_hybrid(
        NULL::vector(1024),
        'confidence boost guc integration test xylophone zebra',
        3, 'tc_i1', NULL
    ) s WHERE s.confidence = 0.5;

    -- Score with GUC ON
    SET LOCAL pgmnemo.confidence_boost_weight = '0.003';
    CREATE TEMP TABLE _t3_on AS
    SELECT score FROM pgmnemo.recall_hybrid(
        NULL::vector(1024),
        'confidence boost guc integration test xylophone zebra',
        3, 'tc_i1', NULL
    ) s WHERE s.confidence = 0.5;

    SELECT (a.score = b.score) AS coldstart_score_identical
    FROM _t3_off a, _t3_on b;

    DROP TABLE _t3_off;
    DROP TABLE _t3_on;
COMMIT;

-- =============================================================================
-- T4: Flag OFF regression — ordering with GUC=0.0 same as GUC unset
-- =============================================================================

BEGIN;
    RESET pgmnemo.confidence_boost_weight;
    CREATE TEMP TABLE _t4_unset AS
    SELECT score, confidence FROM pgmnemo.recall_hybrid(
        NULL::vector(1024),
        'confidence boost guc integration test xylophone zebra',
        3, 'tc_i1', NULL
    ) s ORDER BY s.confidence;

    SET LOCAL pgmnemo.confidence_boost_weight = '0.0';
    CREATE TEMP TABLE _t4_zero AS
    SELECT score, confidence FROM pgmnemo.recall_hybrid(
        NULL::vector(1024),
        'confidence boost guc integration test xylophone zebra',
        3, 'tc_i1', NULL
    ) s ORDER BY s.confidence;

    SELECT bool_and(a.score = b.score) AS flag_off_scores_identical
    FROM _t4_unset a
    JOIN _t4_zero b ON a.confidence = b.confidence;

    DROP TABLE _t4_unset;
    DROP TABLE _t4_zero;
COMMIT;

-- =============================================================================
-- T5: Score spread with GUC ON is materially larger than with GUC OFF
-- At w=0.003, high-vs-low delta should increase by ~0.0024 (>>0.001 threshold)
-- =============================================================================

BEGIN;
    RESET pgmnemo.confidence_boost_weight;
    CREATE TEMP TABLE _t5_off AS
    SELECT MAX(score) - MIN(score) AS spread FROM pgmnemo.recall_hybrid(
        NULL::vector(1024),
        'confidence boost guc integration test xylophone zebra',
        3, 'tc_i1', NULL
    ) s;

    SET LOCAL pgmnemo.confidence_boost_weight = '0.003';
    CREATE TEMP TABLE _t5_on AS
    SELECT MAX(score) - MIN(score) AS spread FROM pgmnemo.recall_hybrid(
        NULL::vector(1024),
        'confidence boost guc integration test xylophone zebra',
        3, 'tc_i1', NULL
    ) s;

    SELECT (b.spread - a.spread) > 0.001 AS boost_materially_increases_spread
    FROM _t5_off a, _t5_on b;

    DROP TABLE _t5_off;
    DROP TABLE _t5_on;
COMMIT;

-- =============================================================================
-- Cleanup
-- =============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_i1';
