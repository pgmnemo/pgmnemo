-- reinforce_delta_guc.sql
-- pg_regress tests for pgmnemo v0.9.2 D1: base-rate-adjusted reinforce() deltas + GUC
--
-- Coverage:
--   T1: Default success delta = +0.02 (not legacy +0.10); result in [0.51, 0.53]
--   T2: Default fail delta = -0.12 (not legacy -0.15); result in [0.37, 0.39]
--   T3: GUC override: pgmnemo.reinforce_success_delta = 0.10 -> result in [0.59, 0.61]
--   T4: GUC override: pgmnemo.reinforce_fail_delta = 0.30 -> result in [0.19, 0.21]
--   T5: Batch reinforce() respects default delta (count=1, confidence in [0.51, 0.53])
--   T6: Delta clamped to [0.001, 0.5] -- setting 0.99 clamped to 0.5; 0.5+0.5=1.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

-- =============================================================================
-- T1: Default success delta = +0.02 (base-rate-adjusted; legacy was +0.10)
-- =============================================================================

RESET pgmnemo.reinforce_success_delta;

WITH ins AS (
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_d1', 'delta_default',
            'reinforce delta guc default success test alpha bravo charlie delta echo unique')
    RETURNING id
),
res AS (SELECT pgmnemo.reinforce(id, 'success') AS c FROM ins)
SELECT c > 0.51 AND c < 0.53 AS success_default_near_0_02 FROM res;

-- =============================================================================
-- T2: Default fail delta = -0.12 (base-rate-adjusted; legacy was -0.15)
-- =============================================================================

RESET pgmnemo.reinforce_fail_delta;

WITH ins AS (
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_d1', 'delta_default',
            'reinforce delta guc default fail test foxtrot golf hotel india juliet unique')
    RETURNING id
),
res AS (SELECT pgmnemo.reinforce(id, 'failure') AS c FROM ins)
SELECT c > 0.37 AND c < 0.39 AS fail_default_near_0_12 FROM res;

-- =============================================================================
-- T3: GUC override: pgmnemo.reinforce_success_delta = 0.10
-- =============================================================================

SET pgmnemo.reinforce_success_delta = '0.10';

WITH ins AS (
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_d1', 'delta_override',
            'reinforce delta guc override success test kilo lima mike november oscar unique')
    RETURNING id
),
res AS (SELECT pgmnemo.reinforce(id, 'success') AS c FROM ins)
SELECT c > 0.59 AND c < 0.61 AS success_guc_override_works FROM res;

RESET pgmnemo.reinforce_success_delta;

-- =============================================================================
-- T4: GUC override: pgmnemo.reinforce_fail_delta = 0.30
-- =============================================================================

SET pgmnemo.reinforce_fail_delta = '0.30';

WITH ins AS (
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_d1', 'delta_override',
            'reinforce delta guc override fail test papa quebec romeo sierra tango unique')
    RETURNING id
),
res AS (SELECT pgmnemo.reinforce(id, 'failure') AS c FROM ins)
SELECT c > 0.19 AND c < 0.21 AS fail_guc_override_works FROM res;

RESET pgmnemo.reinforce_fail_delta;

-- =============================================================================
-- T5: Batch reinforce() respects default delta (+0.02)
-- =============================================================================

RESET pgmnemo.reinforce_success_delta;

WITH ins AS (
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_d1', 'batch_delta',
            'reinforce batch delta guc test uniform victor whiskey xray yankee unique')
    RETURNING id
),
batch AS (
    SELECT pgmnemo.reinforce(ARRAY[id], 'success') AS cnt, id FROM ins
)
SELECT
    batch.cnt = 1                                  AS batch_count_correct,
    al.confidence > 0.51 AND al.confidence < 0.53 AS batch_delta_near_0_02
FROM batch
JOIN pgmnemo.agent_lesson al ON al.id = batch.id;

-- =============================================================================
-- T6: Delta clamped to [0.001, 0.5] -- 0.99 clamped to 0.5; 0.5+0.5=1.0
-- =============================================================================

SET pgmnemo.reinforce_success_delta = '0.99';

WITH ins AS (
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, confidence)
    VALUES ('tc_d1', 'delta_clamp',
            'reinforce delta guc clamp test zulu alpha bravo charlie foxtrot golf unique',
            0.5)
    RETURNING id
),
res AS (SELECT pgmnemo.reinforce(id, 'success') AS c FROM ins)
SELECT c = 1.0::REAL AS success_delta_clamped_to_0_5 FROM res;

RESET pgmnemo.reinforce_success_delta;

-- =============================================================================
-- Cleanup
-- =============================================================================

DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_d1';
