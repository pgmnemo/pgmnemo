-- test_v092_reinforce.sql
-- pg_regress regression tests for pgmnemo v0.9.2 — D1: reinforce() GUC deltas
--
-- Coverage:
--   T1:  Default success delta +0.02: start 0.5 → expect 0.52
--   T2:  Default fail delta -0.12: start 0.5 → expect 0.38
--   T3:  GUC override reinforce_success_delta=0.10 → start 0.5 → expect 0.60
--   T4:  GUC override reinforce_fail_delta=0.20 → start 0.5 → expect 0.30
--   T5:  Ceiling clamp: start 0.99, success → 1.0 (not 1.01)
--   T6:  Floor clamp: start 0.05, failure → 0.0 (not negative)
--   T7:  Batch reinforce defaults: 2 lessons success, check counts + deltas
--   T8:  Neutral still no-op: start 0.5, neutral → 0.5, no row write
--   T9:  GUC clamp lower bound: reinforce_success_delta=0.0 → clamped to 0.001
--   T10: Batch failure GUC override: reinforce_fail_delta=0.25 → start 0.5 → 0.25
--
-- Prerequisites: pgmnemo 0.9.2 installed.
-- NOTE: Run with:
--   psql -v ON_ERROR_STOP=1 -f test_v092_reinforce.sql
-- or via pg_regress.

SET pgmnemo.include_unverified = 'on';
SET pgmnemo.gate_strict = 'off';

-- =============================================================================
-- Setup: insert test lessons
-- =============================================================================
-- role='tc_v092r' for easy cleanup. All start with confidence = 0.5 (default).

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_1_v092r',
    'D1 test lesson 1: default success delta baseline.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_defaults"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_2_v092r',
    'D1 test lesson 2: default fail delta baseline.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_defaults"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_3_v092r',
    'D1 test lesson 3: GUC override success delta.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_guc"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_4_v092r',
    'D1 test lesson 4: GUC override fail delta.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_guc"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_5_v092r',
    'D1 test lesson 5: ceiling clamp (start 0.99).',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_clamp"}'::jsonb
);
-- Set lesson_5 confidence to 0.99
UPDATE pgmnemo.agent_lesson SET confidence = 0.99 WHERE topic = 'lesson_5_v092r';

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_6_v092r',
    'D1 test lesson 6: floor clamp (start 0.05).',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_clamp"}'::jsonb
);
-- Set lesson_6 confidence to 0.05
UPDATE pgmnemo.agent_lesson SET confidence = 0.05 WHERE topic = 'lesson_6_v092r';

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_7a_v092r',
    'D1 test lesson 7a: batch default success.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_batch"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_7b_v092r',
    'D1 test lesson 7b: batch default success.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_batch"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_8_v092r',
    'D1 test lesson 8: neutral no-op.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_neutral"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_9_v092r',
    'D1 test lesson 9: GUC clamp lower bound (success_delta=0.0 → clamped 0.001).',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_clamp_guc"}'::jsonb
);

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, embedding, metadata)
VALUES (
    'tc_v092r', 'lesson_10_v092r',
    'D1 test lesson 10: batch GUC fail delta override 0.25.',
    ('[' || repeat('0.03125,', 1023) || '0.03125]')::vector(1024),
    '{"test": "v092r_batch_guc"}'::jsonb
);

SELECT 'setup: 10 lessons inserted for v0.9.2 reinforce GUC tests' AS setup_done;

-- =============================================================================
-- T1: Default success delta +0.02 → confidence 0.5 + 0.02 = 0.52
-- =============================================================================
SELECT 'T1: default success delta +0.02' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_1_v092r';
    PERFORM pgmnemo.reinforce(_id, 'success');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    success_count,
    last_outcome
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_1_v092r';

-- Expect: confidence_after=0.5200, success_count=1, last_outcome='success'

-- =============================================================================
-- T2: Default fail delta -0.12 → confidence 0.5 - 0.12 = 0.38
-- =============================================================================
SELECT 'T2: default fail delta -0.12' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_2_v092r';
    PERFORM pgmnemo.reinforce(_id, 'failure');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    fail_count,
    last_outcome
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_2_v092r';

-- Expect: confidence_after=0.3800, fail_count=1, last_outcome='failure'

-- =============================================================================
-- T3: GUC override reinforce_success_delta=0.10 → 0.5 + 0.10 = 0.60
-- =============================================================================
SELECT 'T3: GUC override success_delta=0.10' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_3_v092r';
    SET LOCAL pgmnemo.reinforce_success_delta = '0.10';
    PERFORM pgmnemo.reinforce(_id, 'success');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    success_count,
    last_outcome
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_3_v092r';

-- Expect: confidence_after=0.6000, success_count=1, last_outcome='success'

-- =============================================================================
-- T4: GUC override reinforce_fail_delta=0.20 → 0.5 - 0.20 = 0.30
-- =============================================================================
SELECT 'T4: GUC override fail_delta=0.20' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_4_v092r';
    SET LOCAL pgmnemo.reinforce_fail_delta = '0.20';
    PERFORM pgmnemo.reinforce(_id, 'failure');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    fail_count,
    last_outcome
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_4_v092r';

-- Expect: confidence_after=0.3000, fail_count=1, last_outcome='failure'

-- =============================================================================
-- T5: Ceiling clamp: start 0.99, success → 1.0 (not 1.01)
-- =============================================================================
SELECT 'T5: ceiling clamp at 1.0' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_5_v092r';
    PERFORM pgmnemo.reinforce(_id, 'success');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    (confidence <= 1.0) AS at_or_below_ceiling
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_5_v092r';

-- Expect: confidence_after=1.0000, at_or_below_ceiling=true

-- =============================================================================
-- T6: Floor clamp: start 0.05, failure → 0.0 (not negative)
-- =============================================================================
SELECT 'T6: floor clamp at 0.0' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_6_v092r';
    PERFORM pgmnemo.reinforce(_id, 'failure');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    (confidence >= 0.0) AS at_or_above_floor
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_6_v092r';

-- Expect: confidence_after=0.0000, at_or_above_floor=true

-- =============================================================================
-- T7: Batch default: 2 lessons success → both +0.02, count=2
-- =============================================================================
SELECT 'T7: batch default success delta' AS test;

DO $$
DECLARE _ids BIGINT[];
BEGIN
    SELECT ARRAY_AGG(id ORDER BY topic) INTO _ids
    FROM pgmnemo.agent_lesson
    WHERE topic IN ('lesson_7a_v092r', 'lesson_7b_v092r');
    PERFORM pgmnemo.reinforce(_ids, 'success');
END;
$$;

SELECT
    topic,
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    success_count
FROM pgmnemo.agent_lesson
WHERE topic IN ('lesson_7a_v092r', 'lesson_7b_v092r')
ORDER BY topic;

-- Expect: both rows confidence_after=0.5200, success_count=1

-- =============================================================================
-- T8: Neutral no-op: start 0.5, neutral → 0.5, no write (last_outcome NULL)
-- =============================================================================
SELECT 'T8: neutral is no-op' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_8_v092r';
    PERFORM pgmnemo.reinforce(_id, 'neutral');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4)  AS confidence_after,
    last_outcome                    IS NULL AS outcome_still_null,
    success_count,
    fail_count
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_8_v092r';

-- Expect: confidence_after=0.5000, outcome_still_null=true, success_count=0, fail_count=0

-- =============================================================================
-- T9: GUC lower clamp: reinforce_success_delta=0.0 → clamped to 0.001
-- =============================================================================
SELECT 'T9: GUC lower clamp (delta=0 → 0.001)' AS test;

DO $$
DECLARE _id BIGINT;
BEGIN
    SELECT id INTO _id FROM pgmnemo.agent_lesson WHERE topic = 'lesson_9_v092r';
    SET LOCAL pgmnemo.reinforce_success_delta = '0.0';
    PERFORM pgmnemo.reinforce(_id, 'success');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    (confidence > 0.5) AS above_start
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_9_v092r';

-- Expect: confidence_after=0.5010, above_start=true (clamped delta=0.001 applied)

-- =============================================================================
-- T10: Batch fail GUC override: reinforce_fail_delta=0.25 → 0.5-0.25=0.25
-- =============================================================================
SELECT 'T10: batch fail GUC override delta=0.25' AS test;

DO $$
DECLARE _ids BIGINT[];
BEGIN
    SELECT ARRAY_AGG(id) INTO _ids
    FROM pgmnemo.agent_lesson
    WHERE topic = 'lesson_10_v092r';
    SET LOCAL pgmnemo.reinforce_fail_delta = '0.25';
    PERFORM pgmnemo.reinforce(_ids, 'failure');
END;
$$;

SELECT
    ROUND(confidence::NUMERIC, 4) AS confidence_after,
    fail_count
FROM pgmnemo.agent_lesson
WHERE topic = 'lesson_10_v092r';

-- Expect: confidence_after=0.2500, fail_count=1

-- =============================================================================
-- Cleanup
-- =============================================================================
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_v092r';

SELECT 'All v0.9.2 reinforce GUC tests completed.' AS result;
