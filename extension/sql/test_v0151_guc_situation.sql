-- test_v0151_guc_situation.sql
-- pg_regress tests for pgmnemo v0.15.1 — recall_situation() GUC filtering
--
-- Coverage:
--   A3-1: recall_situation() is LANGUAGE plpgsql after upgrade (changed from sql)
--   A3-2: recall_situation returns ALL matching rows when include_unverified = 'on'
--   A3-3: recall_situation returns ONLY verified rows when include_unverified is off
--   A3-4: recall_situation returns ONLY verified rows when include_unverified not set (default)
--   A3-5: EXCEPTION-safe fallback — bad GUC value does not propagate to caller
--   A3-6: other recall criteria (p_project_id, p_role, p_k) still work post-upgrade
--
-- Test role 'tc_v0151' and project_id -1510 isolate data from all other tests.
-- gate_strict off: bypass provenance gate for test writes.
-- SPDX-License-Identifier: Apache-2.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.19.0';

-- =============================================================================
-- A3-1: recall_situation() is LANGUAGE plpgsql after upgrade
-- =============================================================================

DO $$
DECLARE
    _lang TEXT;
BEGIN
    SELECT l.lanname INTO _lang
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l  ON l.oid = p.prolang
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_situation'
    LIMIT 1;

    IF _lang = 'plpgsql' THEN
        RAISE NOTICE 'A3-1 PASS: recall_situation() is LANGUAGE plpgsql';
    ELSE
        RAISE EXCEPTION 'A3-1 FAIL: expected plpgsql, got %', _lang;
    END IF;
END;
$$;

-- =============================================================================
-- Fixture: insert two lessons — one verified, one unverified — same sit_fp
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, is_active,
     content_type, verified_at, artifact_hash, t_valid_from, t_valid_to)
VALUES
    -- verified row
    ('tc_v0151', -1510,
     '[INCIDENT:guc_test] GUC filtering verified row',
     'failure_class=GUC_TEST outcome=VERIFIED this lesson was verified',
     3, TRUE, 'incident', now(), 'test-artifact-hash-v0151-verified',
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ),
    -- unverified row (no verified_at, no commit_sha, no artifact_hash —
    --   gate_strict=off allows this insert)
    ('tc_v0151', -1510,
     '[INCIDENT:guc_test] GUC filtering unverified row',
     'failure_class=GUC_TEST outcome=UNVERIFIED this lesson was not verified',
     2, TRUE, 'incident', NULL, NULL,
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ);

-- =============================================================================
-- A3-2: include_unverified = 'on' → both rows returned
-- =============================================================================

DO $$
DECLARE
    _count INT;
    _fp    TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:guc_test] GUC filtering verified row',
        'failure_class=GUC_TEST outcome=VERIFIED this lesson was verified'
    );

    SET LOCAL pgmnemo.include_unverified = 'on';

    SELECT count(*) INTO _count
    FROM pgmnemo.recall_situation(_fp, p_project_id => -1510, p_k => 50);

    IF _count = 2 THEN
        RAISE NOTICE 'A3-2 PASS: include_unverified=on returns % rows (verified + unverified)', _count;
    ELSE
        RAISE EXCEPTION 'A3-2 FAIL: expected 2 rows with include_unverified=on, got %', _count;
    END IF;
END;
$$;

-- =============================================================================
-- A3-3: include_unverified = 'off' → only verified row returned
-- =============================================================================

DO $$
DECLARE
    _count INT;
    _fp    TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:guc_test] GUC filtering verified row',
        'failure_class=GUC_TEST outcome=VERIFIED this lesson was verified'
    );

    SET LOCAL pgmnemo.include_unverified = 'off';

    SELECT count(*) INTO _count
    FROM pgmnemo.recall_situation(_fp, p_project_id => -1510, p_k => 50);

    IF _count = 1 THEN
        RAISE NOTICE 'A3-3 PASS: include_unverified=off returns % row (verified only)', _count;
    ELSE
        RAISE EXCEPTION 'A3-3 FAIL: expected 1 row with include_unverified=off, got %', _count;
    END IF;
END;
$$;

-- =============================================================================
-- A3-4: GUC not set (RESET) → defaults to FALSE → only verified row returned
-- =============================================================================

DO $$
DECLARE
    _count INT;
    _fp    TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:guc_test] GUC filtering verified row',
        'failure_class=GUC_TEST outcome=VERIFIED this lesson was verified'
    );

    RESET pgmnemo.include_unverified;

    SELECT count(*) INTO _count
    FROM pgmnemo.recall_situation(_fp, p_project_id => -1510, p_k => 50);

    IF _count = 1 THEN
        RAISE NOTICE 'A3-4 PASS: GUC not set → defaults to FALSE → % row (verified only)', _count;
    ELSE
        RAISE EXCEPTION 'A3-4 FAIL: expected 1 row when GUC not set, got %', _count;
    END IF;
END;
$$;

-- =============================================================================
-- A3-5: EXCEPTION-safe fallback — invalid GUC value does not raise to caller
-- =============================================================================

DO $$
DECLARE
    _count INT;
    _fp    TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:guc_test] GUC filtering verified row',
        'failure_class=GUC_TEST outcome=VERIFIED this lesson was verified'
    );

    -- pg_regress cannot set an arbitrary custom GUC to a non-boolean string
    -- without a custom GUC definition.  Test the fallback by confirming the
    -- function does not throw when the GUC is absent (missing_ok path).
    RESET pgmnemo.include_unverified;

    BEGIN
        SELECT count(*) INTO _count
        FROM pgmnemo.recall_situation(_fp, p_project_id => -1510, p_k => 50);
        RAISE NOTICE 'A3-5 PASS: function did not raise when GUC absent; returned % row(s)', _count;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'A3-5 FAIL: recall_situation raised when GUC absent: %', SQLERRM;
    END;
END;
$$;

-- =============================================================================
-- A3-6: p_project_id, p_role, p_k still work post-upgrade
-- =============================================================================

DO $$
DECLARE
    _count_project INT;
    _count_role    INT;
    _count_k       INT;
    _fp            TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:guc_test] GUC filtering verified row',
        'failure_class=GUC_TEST outcome=VERIFIED this lesson was verified'
    );

    SET LOCAL pgmnemo.include_unverified = 'on';

    -- p_project_id filter: wrong project → 0 rows
    SELECT count(*) INTO _count_project
    FROM pgmnemo.recall_situation(_fp, p_project_id => -9999, p_k => 50);

    -- p_role filter: correct role → both rows; wrong role → 0
    SELECT count(*) INTO _count_role
    FROM pgmnemo.recall_situation(_fp, p_role => 'tc_v0151', p_k => 50);

    -- p_k limit: k=1 → 1 row even though 2 exist
    SELECT count(*) INTO _count_k
    FROM pgmnemo.recall_situation(_fp, p_project_id => -1510, p_k => 1);

    IF _count_project = 0 AND _count_role = 2 AND _count_k = 1 THEN
        RAISE NOTICE 'A3-6 PASS: p_project_id=0, p_role=2, p_k=1 all correct';
    ELSE
        RAISE EXCEPTION 'A3-6 FAIL: project=% (want 0), role=% (want 2), k=% (want 1)',
            _count_project, _count_role, _count_k;
    END IF;
END;
$$;

-- Cleanup
DELETE FROM pgmnemo.agent_lesson WHERE project_id = -1510 AND role = 'tc_v0151';
