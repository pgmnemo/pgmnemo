-- t_confidence_mode_switch.sql
-- pg_regress tests for pgmnemo v0.13.0 confidence mode GUC
--
-- Coverage:
--   T1: Default mode = 'posterior' → 1 success: (1+1)/(1+0+1+1) = 2/3 ≈ 0.667
--   T2: Switch to 'additive' → 1 more success: 0.667 + 0.02 ≈ 0.687
--   T3: Reset to 'posterior' → 1 failure: s=2,f=1 → (2+1)/(2+1+1+1) = 3/5 = 0.600
--   T4: Invalid mode value → RAISE EXCEPTION
-- SPDX-License-Identifier: Apache-2.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

-- Setup
DO $$
BEGIN
    PERFORM pgmnemo.ingest('test_role', 999, 'mode_test',
        'lesson delta test confidence mode switch posterior additive v0130',
        p_commit_sha => 'sha_ms_d');
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- T1: Default mode = 'posterior' → 1 success: (1+1)/(1+0+1+1) = 2/3 ≈ 0.667
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM pgmnemo.reinforce(
        (SELECT id FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d'),
        'success', TRUE);
END;
$$;

SELECT round(confidence::numeric, 3) = 0.667 AS t1_posterior_default
FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d';

-- ─────────────────────────────────────────────────────────────────────────────
-- T2: Switch to additive → 1 more success: 0.667 + 0.02 ≈ 0.687
-- ─────────────────────────────────────────────────────────────────────────────
SET pgmnemo.confidence_mode = 'additive';

DO $$
BEGIN
    PERFORM pgmnemo.reinforce(
        (SELECT id FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d'),
        'success', TRUE);
END;
$$;

SELECT round(confidence::numeric, 3) = 0.687 AS t2_additive_mode
FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d';

-- ─────────────────────────────────────────────────────────────────────────────
-- T3: Reset to posterior → 1 failure: s=2, f=1 → (2+1)/(2+1+1+1) = 3/5 = 0.600
-- ─────────────────────────────────────────────────────────────────────────────
RESET pgmnemo.confidence_mode;

DO $$
BEGIN
    PERFORM pgmnemo.reinforce(
        (SELECT id FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d'),
        'failure', TRUE);
END;
$$;

SELECT round(confidence::numeric, 3) = 0.600 AS t3_back_to_posterior
FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d';

-- ─────────────────────────────────────────────────────────────────────────────
-- T4: Invalid mode → RAISE EXCEPTION (unknown value rejected)
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    SET pgmnemo.confidence_mode = 'bogus';
    PERFORM pgmnemo.reinforce(
        (SELECT id FROM pgmnemo.agent_lesson WHERE commit_sha = 'sha_ms_d'),
        'success', TRUE);
    RAISE EXCEPTION 'T4 FAIL: should have raised on unknown mode';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%unknown confidence_mode%' THEN
        RAISE NOTICE 'T4 PASS: unknown mode correctly rejected';
    ELSE
        RAISE;
    END IF;
END;
$$;

RESET pgmnemo.confidence_mode;

-- Cleanup
DELETE FROM pgmnemo.agent_lesson WHERE topic = 'mode_test';
