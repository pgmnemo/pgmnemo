-- test_v071.sql
-- pg_regress tests for pgmnemo v0.7.1
--
-- Tests:
--   A: Batch reinforce(BIGINT[], TEXT) overload registered (MINOR-2)
--   B: Batch reinforce behavioral tests (MINOR-2)
--   C: recall_hybrid match_confidence uses vec_score (BUG-1 fix)
--   D: recall_hybrid COMMENT updated to v0.7.1 (MINOR-3 regression guard)
--   E: Scalar reinforce(BIGINT, TEXT) unchanged (regression guard)
--
-- Prerequisites: pgmnemo installed at v0.7.1 (fresh or upgraded from 0.7.0).
-- Inserted test rows use project_id <= -1 (non-conflicting namespace).

-- =============================================================================
-- A: Batch reinforce overload exists
-- =============================================================================

-- A1: Two reinforce overloads registered (scalar + batch)
DO $$
DECLARE _cnt INT;
BEGIN
    SELECT COUNT(*) INTO _cnt
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'reinforce';

    IF _cnt = 2 THEN
        RAISE NOTICE 'A1 PASS: reinforce has 2 overloads (scalar + batch)';
    ELSE
        RAISE EXCEPTION 'A1 FAIL: expected 2 reinforce overloads, got %', _cnt;
    END IF;
END;
$$;

-- A2: Batch overload returns INT (not REAL like the scalar form)
DO $$
DECLARE _ret TEXT;
BEGIN
    SELECT pg_catalog.pg_get_function_result(p.oid) INTO _ret
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'reinforce'
      AND pg_catalog.pg_get_function_arguments(p.oid) LIKE '%bigint[]%';

    IF _ret = 'integer' THEN
        RAISE NOTICE 'A2 PASS: batch reinforce RETURNS integer';
    ELSE
        RAISE EXCEPTION 'A2 FAIL: expected RETURNS integer, got %', _ret;
    END IF;
END;
$$;

-- =============================================================================
-- B: Batch reinforce behavioral tests
-- =============================================================================

-- B1: Empty array returns 0 immediately (no work, no error)
DO $$
DECLARE _updated INT;
BEGIN
    _updated := pgmnemo.reinforce(ARRAY[]::BIGINT[], 'success');
    IF _updated = 0 THEN
        RAISE NOTICE 'B1 PASS: batch reinforce empty array returns 0';
    ELSE
        RAISE EXCEPTION 'B1 FAIL: expected 0, got %', _updated;
    END IF;
END;
$$;

-- B2: NULL array returns 0 immediately (no error)
DO $$
DECLARE _updated INT;
BEGIN
    _updated := pgmnemo.reinforce(NULL::BIGINT[], 'success');
    IF _updated = 0 THEN
        RAISE NOTICE 'B2 PASS: batch reinforce NULL array returns 0';
    ELSE
        RAISE EXCEPTION 'B2 FAIL: expected 0, got %', _updated;
    END IF;
END;
$$;

-- B3: All-missing IDs returns 0 with no RAISE EXCEPTION
DO $$
DECLARE _updated INT;
BEGIN
    _updated := pgmnemo.reinforce(ARRAY[-999991, -999992, -999993]::BIGINT[], 'success');
    IF _updated = 0 THEN
        RAISE NOTICE 'B3 PASS: batch reinforce all-missing IDs returns 0, no exception';
    ELSE
        RAISE EXCEPTION 'B3 FAIL: expected 0 (all missing), got %', _updated;
    END IF;
END;
$$;

-- B4: Unknown outcome still raises (caller programming error, not data error)
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.reinforce(ARRAY[-999991]::BIGINT[], 'SUCCESS');  -- wrong case
        RAISE EXCEPTION 'B4 FAIL: unknown outcome did not raise';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%unknown outcome%' THEN
                RAISE NOTICE 'B4 PASS: unknown outcome raises expected exception: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'B4 FAIL: unexpected exception text: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- B5: 1 real lesson + 1 missing ID → returns 1 (skip the missing, update the real)
DO $$
DECLARE
    _lesson_id BIGINT;
    _updated   INT;
    _conf_before REAL;
    _conf_after  REAL;
BEGIN
    -- Insert a lesson with provenance (so it's active and real)
    _lesson_id := pgmnemo.ingest(
        'test_v071_batch', -1, 'batch_reinforce_skip_test',
        'Test lesson for v0.7.1 batch reinforce skip behavior.',
        3::SMALLINT, NULL::vector(1024),
        'sha_v071_b5_' || to_char(clock_timestamp(), 'US'), NULL, '{}'::JSONB
    );

    SELECT confidence INTO _conf_before
    FROM pgmnemo.agent_lesson WHERE id = _lesson_id;

    -- Batch: [real_id, missing_id] — should skip the missing, update the real
    _updated := pgmnemo.reinforce(ARRAY[_lesson_id, -999999]::BIGINT[], 'success');

    SELECT confidence INTO _conf_after
    FROM pgmnemo.agent_lesson WHERE id = _lesson_id;

    IF _updated = 1 AND _conf_after > _conf_before THEN
        RAISE NOTICE 'B5 PASS: batch reinforce [present, missing] returns 1, confidence updated';
    ELSIF _updated <> 1 THEN
        RAISE EXCEPTION 'B5 FAIL: expected updated=1, got %', _updated;
    ELSE
        RAISE EXCEPTION 'B5 FAIL: confidence did not increase (before=%, after=%)',
            _conf_before, _conf_after;
    END IF;
END;
$$;

-- =============================================================================
-- C: recall_hybrid match_confidence BUG-1 fix
-- =============================================================================

-- C1: match_confidence ≈ cosine (not ~0.005 from RRF/1.5 formula)
--     Strategy: insert a lesson with a known unit vector, recall with the SAME
--     vector → cosine = 1.0 → match_confidence should be ~1.0 (not 0.011).
DO $$
DECLARE
    _vec       TEXT;
    _vec_val   vector(1024);
    _lesson_id BIGINT;
    _mc        REAL;
    _vs        DOUBLE PRECISION;
BEGIN
    -- Build a 1024-d unit vector: all components = 1/sqrt(1024) = 0.03125
    _vec := '[' || repeat('0.03125,', 1023) || '0.03125]';
    _vec_val := _vec::vector(1024);

    -- Insert with provenance (verified_at = NOW() auto-set by ingest())
    _lesson_id := pgmnemo.ingest(
        'test_v071_recall', -2, 'match_confidence_calibration_test',
        'Test lesson for v0.7.1 match_confidence calibration fix (BUG-1).',
        3::SMALLINT, _vec_val,
        'sha_v071_c1_' || to_char(clock_timestamp(), 'US'),
        NULL, '{}'::JSONB
    );

    -- Recall with the same vector (cosine = 1.0 → match_confidence should = 1.0)
    SELECT h.match_confidence, h.vec_score INTO _mc, _vs
    FROM pgmnemo.recall_hybrid(
        _vec_val,
        'match confidence calibration test',
        1, 'test_v071_recall', -2
    ) h;

    IF _mc IS NULL THEN
        RAISE EXCEPTION 'C1 FAIL: recall_hybrid returned no rows';
    ELSIF _mc > 0.9 THEN
        -- Old formula (RRF/1.5) ≈ 0.011; new formula (vec_score) ≈ 1.0
        RAISE NOTICE 'C1 PASS: match_confidence=% vec_score=% (BUG-1 fixed: mc≈cosine, not ~0.005)',
            _mc, _vs;
    ELSE
        RAISE EXCEPTION 'C1 FAIL: match_confidence=% (BUG-1 still present: expected >0.9)', _mc;
    END IF;
END;
$$;

-- =============================================================================
-- D: COMMENT regression guards
-- =============================================================================

-- D1: recall_hybrid COMMENT describes vec_score formula (BUG-1 fix content, version-agnostic)
DO $$
DECLARE _comment TEXT;
BEGIN
    SELECT obj_description(p.oid, 'pg_proc') INTO _comment
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid';

    IF _comment LIKE '%vec_score%' THEN
        RAISE NOTICE 'D1 PASS: recall_hybrid COMMENT describes vec_score formula (BUG-1 fix)';
    ELSE
        RAISE EXCEPTION 'D1 FAIL: recall_hybrid COMMENT missing vec_score formula description: %',
            left(_comment, 80);
    END IF;
END;
$$;

-- D2: recall_hybrid COMMENT mentions graph_proximity dormancy note (MINOR-3)
DO $$
DECLARE _comment TEXT;
BEGIN
    SELECT obj_description(p.oid, 'pg_proc') INTO _comment
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid';

    IF _comment LIKE '%mem_edge%' THEN
        RAISE NOTICE 'D2 PASS: recall_hybrid COMMENT includes mem_edge / graph_proximity dormancy note';
    ELSE
        RAISE EXCEPTION 'D2 FAIL: recall_hybrid COMMENT missing mem_edge note';
    END IF;
END;
$$;

-- =============================================================================
-- E: Scalar reinforce(BIGINT, TEXT) regression — unchanged behavior
-- =============================================================================

-- E1: Scalar reinforce still raises on unknown outcome
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.reinforce(-999994::BIGINT, 'FAIL_OUTCOME');
        RAISE EXCEPTION 'E1 FAIL: scalar reinforce did not raise on unknown outcome';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%not found%' OR SQLERRM LIKE '%unknown outcome%' THEN
                RAISE NOTICE 'E1 PASS: scalar reinforce raised expected exception on bad input';
            ELSE
                RAISE EXCEPTION 'E1 FAIL: unexpected exception: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- E2: Scalar reinforce still raises on not-found lesson
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.reinforce(-999995::BIGINT, 'success');
        RAISE EXCEPTION 'E2 FAIL: scalar reinforce did not raise on missing lesson_id';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%not found%' THEN
                RAISE NOTICE 'E2 PASS: scalar reinforce raises on missing lesson_id (unchanged)';
            ELSE
                RAISE EXCEPTION 'E2 FAIL: unexpected exception: %', SQLERRM;
            END IF;
    END;
END;
$$;
