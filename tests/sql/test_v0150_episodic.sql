-- test_v0150_episodic.sql
-- pg_regress tests for pgmnemo v0.15.0 — Episode fingerprint + situational recall
--
-- Coverage:
--   A1-1: extract_sit_fp() function exists and is IMMUTABLE
--   A1-2: R1 — [INCIDENT:<class>] topic → 'class=<class>' (file count stripped)
--   A1-3: R1 — different file counts → SAME class (key: situation, not specifics)
--   A1-4: R1 — different incident classes → DIFFERENT fingerprints
--   A1-5: R2 — failure_class= in episode text → 'class=WORD|outcome=WORD'
--   A1-6: R3 — outcome=COMPLETED (no failure_class) → 'class=completed'
--   A1-7: no matching pattern → NULL
--   A2-1: recall_situation() function exists with correct signature
--   A2-2: recall_situation returns rows matching the fingerprint
--   A2-3: recall_situation does NOT return rows from a different class
--   A2-4: remember_event() writes sit_fp into metadata JSONB
--   A2-5: ix_pgmnemo_sit_fp_active index exists on agent_lesson
--   A2-6: recall_situation is situation-based not text-similarity (key correctness test)
--
-- Test role 'tc_v0150' and project_id -1500 isolate data from all other tests.
-- gate_strict off: bypass provenance gate for testing.
-- SPDX-License-Identifier: Apache-2.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.15.0';
ALTER EXTENSION pgmnemo UPDATE TO '0.15.0';

-- =============================================================================
-- A1-1: extract_sit_fp() exists and is IMMUTABLE
-- =============================================================================

DO $$
DECLARE
    _volatility CHAR;
BEGIN
    SELECT p.provolatile INTO _volatility
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'extract_sit_fp'
    LIMIT 1;

    IF _volatility = 'i' THEN
        RAISE NOTICE 'A1-1 PASS: extract_sit_fp() exists, provolatile=i (IMMUTABLE)';
    ELSE
        RAISE EXCEPTION 'A1-1 FAIL: expected provolatile=i, got %, or function missing', _volatility;
    END IF;
END;
$$;

-- =============================================================================
-- A1-2: R1 — [INCIDENT:deploy_gap] topic → 'class=deploy_gap'
-- =============================================================================

DO $$
DECLARE
    _fp TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:deploy_gap] Container code stale — 7 files behind git HEAD'
    );
    IF _fp = 'class=deploy_gap' THEN
        RAISE NOTICE 'A1-2 PASS: [INCIDENT:deploy_gap] → %', _fp;
    ELSE
        RAISE EXCEPTION 'A1-2 FAIL: expected class=deploy_gap, got %', _fp;
    END IF;
END;
$$;

-- =============================================================================
-- A1-3: R1 — different file counts → SAME class (situation, not specifics)
-- =============================================================================

DO $$
DECLARE
    _fp1 TEXT;
    _fp7 TEXT;
    _fp24 TEXT;
BEGIN
    _fp1  := pgmnemo.extract_sit_fp('[INCIDENT:deploy_gap] Container code stale — 1 files behind git HEAD');
    _fp7  := pgmnemo.extract_sit_fp('[INCIDENT:deploy_gap] Container code stale — 7 files behind git HEAD');
    _fp24 := pgmnemo.extract_sit_fp('[INCIDENT:deploy_gap] Container code stale — 24 files behind git HEAD');

    IF _fp1 = _fp7 AND _fp7 = _fp24 AND _fp1 = 'class=deploy_gap' THEN
        RAISE NOTICE 'A1-3 PASS: 1-file, 7-file, 24-file variants all → class=deploy_gap';
    ELSE
        RAISE EXCEPTION 'A1-3 FAIL: got fp1=%, fp7=%, fp24=% — not all equal to class=deploy_gap',
            _fp1, _fp7, _fp24;
    END IF;
END;
$$;

-- =============================================================================
-- A1-4: R1 — different incident classes → DIFFERENT fingerprints
-- =============================================================================

DO $$
DECLARE
    _fp_deploy TEXT;
    _fp_zombie TEXT;
    _fp_budget TEXT;
BEGIN
    _fp_deploy := pgmnemo.extract_sit_fp('[INCIDENT:deploy_gap] Container code stale — 7 files');
    _fp_zombie := pgmnemo.extract_sit_fp('[INCIDENT:zombie_running] 3 zombie RUNNING runs recovered');
    _fp_budget := pgmnemo.extract_sit_fp('[INCIDENT:budget_burst] $35.63 burned in 15 min (10 runs)');

    IF _fp_deploy <> _fp_zombie AND _fp_zombie <> _fp_budget AND _fp_deploy <> _fp_budget THEN
        RAISE NOTICE 'A1-4 PASS: deploy_gap=%, zombie_running=%, budget_burst=% — all different',
            _fp_deploy, _fp_zombie, _fp_budget;
    ELSE
        RAISE EXCEPTION 'A1-4 FAIL: expected distinct fingerprints, got deploy=%, zombie=%, budget=%',
            _fp_deploy, _fp_zombie, _fp_budget;
    END IF;
END;
$$;

-- =============================================================================
-- A1-5: R2 — failure_class= in episode text
-- =============================================================================

DO $$
DECLARE
    _fp TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        'project:agency:event:run_114268_closeout',
        '[EPISODE] run=114268 outcome=ESCALATED duration=0.1min cost=$0.0' || E'\n'
        || 'fingerprint: failure_class=INFRA_AUTH_INVALID task_id=9842'
    );
    IF _fp = 'class=INFRA_AUTH_INVALID|outcome=ESCALATED' THEN
        RAISE NOTICE 'A1-5 PASS: failure_class=INFRA_AUTH_INVALID + outcome=ESCALATED → %', _fp;
    ELSE
        RAISE EXCEPTION 'A1-5 FAIL: expected class=INFRA_AUTH_INVALID|outcome=ESCALATED, got %', _fp;
    END IF;
END;
$$;

-- =============================================================================
-- A1-6: R3 — outcome=COMPLETED (no failure_class) → 'class=completed'
-- =============================================================================

DO $$
DECLARE
    _fp TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        'project:agency:event:run_114262_closeout',
        '[EPISODE] run=114262 outcome=COMPLETED duration=4.6min cost=$0.7388' || E'\n'
        || 'fingerprint: task_id=9841'
    );
    IF _fp = 'class=completed' THEN
        RAISE NOTICE 'A1-6 PASS: outcome=COMPLETED (no failure_class) → %', _fp;
    ELSE
        RAISE EXCEPTION 'A1-6 FAIL: expected class=completed, got %', _fp;
    END IF;
END;
$$;

-- =============================================================================
-- A1-7: no matching pattern → NULL
-- =============================================================================

DO $$
DECLARE
    _fp TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        'some-unstructured-topic',
        'When deploying, always restart the service before running tests.'
    );
    IF _fp IS NULL THEN
        RAISE NOTICE 'A1-7 PASS: unstructured topic/text → NULL (no fingerprint)';
    ELSE
        RAISE EXCEPTION 'A1-7 FAIL: expected NULL, got %', _fp;
    END IF;
END;
$$;

-- =============================================================================
-- Setup: seed isolated rows for A2 tests
-- Two deploy_gap incidents (different text/word count) → same class
-- One zombie_running incident (different class) → must NOT match
-- One INFRA_AUTH_INVALID episode → must NOT match deploy_gap
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, content_type, source_type)
VALUES
    -- deploy_gap incident — 7 files, verbose wording
    ('tc_v0150', -1500,
     '[INCIDENT:deploy_gap] Container code stale — 7 files behind git HEAD',
     'The deploy gap detector flagged 7 modified files in apps/v3-next that are not reflected '
     'in the running container. Root cause: uvicorn --reload is OFF (deployment policy). '
     'Fix: run bash scripts/agency-restart.sh to apply the committed changes.',
     3, 'incident', 'system'),

    -- deploy_gap incident — 24 files, terse wording (DIFFERENT text, SAME class)
    ('tc_v0150', -1500,
     '[INCIDENT:deploy_gap] Container code stale — 24 files behind git HEAD',
     '24-file stale container detected. Graceful restart required.',
     3, 'incident', 'system'),

    -- zombie_running incident — different class, must NOT match deploy_gap
    ('tc_v0150', -1500,
     '[INCIDENT:zombie_running] 3 zombie RUNNING runs recovered after orchestrator init',
     'Three runs stuck in RUNNING state with no active SDK call. Marked FAILED. '
     'Root cause: container restart mid-execution.',
     3, 'incident', 'system'),

    -- INFRA_AUTH_INVALID episode — different class, must NOT match deploy_gap
    ('tc_v0150', -1500,
     'project:tc_v0150:event:run_99001_closeout',
     '[EPISODE] run=99001 outcome=ESCALATED duration=0.1min cost=$0.0' || E'\n'
     || 'fingerprint: failure_class=INFRA_AUTH_INVALID task_id=77001',
     3, 'event', 'system');

-- =============================================================================
-- A2-1: recall_situation() function exists with correct signature
-- =============================================================================

DO $$
DECLARE
    _cnt INT;
BEGIN
    SELECT COUNT(*) INTO _cnt
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_situation';

    IF _cnt >= 1 THEN
        RAISE NOTICE 'A2-1 PASS: recall_situation() exists (% overload(s))', _cnt;
    ELSE
        RAISE EXCEPTION 'A2-1 FAIL: recall_situation() not found in pgmnemo schema';
    END IF;
END;
$$;

-- =============================================================================
-- A2-2: recall_situation returns rows matching the fingerprint
-- =============================================================================

DO $$
DECLARE
    _cnt INT;
BEGIN
    SELECT COUNT(*) INTO _cnt
    FROM pgmnemo.recall_situation(
        'class=deploy_gap',
        p_project_id => -1500,
        p_k => 20
    );

    IF _cnt = 2 THEN
        RAISE NOTICE 'A2-2 PASS: recall_situation(class=deploy_gap) returned % rows (7-file + 24-file)', _cnt;
    ELSE
        RAISE EXCEPTION 'A2-2 FAIL: expected 2 deploy_gap rows, got %', _cnt;
    END IF;
END;
$$;

-- =============================================================================
-- A2-3: recall_situation does NOT return rows from a different class
--        Key correctness test: zombie_running must not appear in deploy_gap results
-- =============================================================================

DO $$
DECLARE
    _bad_topic TEXT;
BEGIN
    SELECT topic INTO _bad_topic
    FROM pgmnemo.recall_situation(
        'class=deploy_gap',
        p_project_id => -1500,
        p_k => 20
    )
    WHERE topic LIKE '%zombie_running%';

    IF _bad_topic IS NULL THEN
        RAISE NOTICE 'A2-3 PASS: zombie_running topic absent from deploy_gap recall results';
    ELSE
        RAISE EXCEPTION 'A2-3 FAIL: zombie_running topic appeared in deploy_gap results: %', _bad_topic;
    END IF;
END;
$$;

-- =============================================================================
-- A2-4: remember_event() writes sit_fp into metadata JSONB
-- =============================================================================

DO $$
DECLARE
    _id   BIGINT;
    _fp   TEXT;
BEGIN
    -- Write a PHANTOM_DONE escalation episode
    _id := pgmnemo.remember_event(
        'tc_v0150',
        'project:tc_test',
        'run_99002_closeout',
        '[EPISODE] run=99002 outcome=ESCALATED duration=12.3min cost=$1.9335' || E'\n'
        || 'fingerprint: failure_class=PHANTOM_DONE task_id=99002',
        p_source_type => 'system',
        p_project_id => -1500
    );

    -- Read back the sit_fp from metadata
    SELECT metadata->>'sit_fp' INTO _fp
    FROM pgmnemo.agent_lesson
    WHERE id = _id;

    IF _fp = 'class=PHANTOM_DONE|outcome=ESCALATED' THEN
        RAISE NOTICE 'A2-4 PASS: remember_event() wrote sit_fp=% into metadata', _fp;
    ELSE
        RAISE EXCEPTION 'A2-4 FAIL: expected sit_fp=class=PHANTOM_DONE|outcome=ESCALATED in metadata, got %', _fp;
    END IF;
END;
$$;

-- =============================================================================
-- A2-5: ix_pgmnemo_sit_fp_active index exists on agent_lesson
-- =============================================================================

DO $$
DECLARE
    _idx TEXT;
BEGIN
    SELECT indexname INTO _idx
    FROM pg_indexes
    WHERE schemaname = 'pgmnemo'
      AND tablename  = 'agent_lesson'
      AND indexname  = 'ix_pgmnemo_sit_fp_active';

    IF _idx IS NOT NULL THEN
        RAISE NOTICE 'A2-5 PASS: index ix_pgmnemo_sit_fp_active exists on pgmnemo.agent_lesson';
    ELSE
        RAISE EXCEPTION 'A2-5 FAIL: ix_pgmnemo_sit_fp_active not found in pg_indexes';
    END IF;
END;
$$;

-- =============================================================================
-- A2-6: Situation-based, NOT text-similarity — the KEY correctness proof
--   Row1 topic=deploy_gap 7-files, text="verbose long explanation of fix"
--   Row2 topic=deploy_gap 24-files, text="terse"  (different wording)
--   Row3 topic=zombie_running, text uses similar vocabulary
--   recall_situation('class=deploy_gap') must return Row1 + Row2, never Row3.
-- =============================================================================

DO $$
DECLARE
    _topics TEXT[];
    _has_deploy_7  BOOLEAN := FALSE;
    _has_deploy_24 BOOLEAN := FALSE;
    _has_zombie    BOOLEAN := FALSE;
BEGIN
    SELECT array_agg(topic) INTO _topics
    FROM pgmnemo.recall_situation(
        'class=deploy_gap',
        p_project_id => -1500,
        p_k => 20
    );

    -- Check each topic
    SELECT
        bool_or(topic LIKE '%7 files%'),
        bool_or(topic LIKE '%24 files%'),
        bool_or(topic LIKE '%zombie%')
    INTO _has_deploy_7, _has_deploy_24, _has_zombie
    FROM unnest(_topics) AS topic;

    IF _has_deploy_7 AND _has_deploy_24 AND NOT _has_zombie THEN
        RAISE NOTICE
            'A2-6 PASS: deploy_gap 7-file=%, 24-file=%, zombie=% — situation match, not text similarity',
            _has_deploy_7, _has_deploy_24, _has_zombie;
    ELSE
        RAISE EXCEPTION
            'A2-6 FAIL: 7-file=%, 24-file=%, zombie=% — expected T,T,F',
            _has_deploy_7, _has_deploy_24, _has_zombie;
    END IF;
END;
$$;

-- Cleanup: remove test rows
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_v0150' AND project_id = -1500;
