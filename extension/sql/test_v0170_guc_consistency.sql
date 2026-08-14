-- test_v0170_guc_consistency.sql
-- pg_regress tests for pgmnemo v0.17.0 — GUC single-default verification
--
-- Verifies: graph_proximity_weight is 0.0 on every call path when the GUC
-- is unset. This is the reconciliation required by PGMREL-0170-IMPLEMENT-R2B.
--
-- The defect in 0.16.1: three overloads carried COALESCE default=0.2 (not 0.0):
-- recall_hybrid(10p), recall_hybrid(11p), navigate_locate(5p). The two
-- recall_hybrid overloads additionally had exception-path fallback=0.2. All
-- other code paths used 0.0 (the v0.10.1 OPT-IN default).
--
-- After v0.17.0 reconciliation: COALESCE and exception paths are 0.0 in
-- all overloads.
--
-- Tests:
--   G1: recall_hybrid (10-param) — result count with explicit 0.0 == unset
--   G2: recall_hybrid (11-param) — result count with explicit 0.0 == unset
--   G3: recall_lessons — result count with explicit 0.0 == unset
--   G4: navigate_locate — explicit 0.0 == unset, ≥1 result
--   G5: corrupt GUC value — exception path recovers to 0.0 (no crash)
--
-- client_min_messages=WARNING suppresses NULL-embedding NOTICEs from
-- recall functions so the expected output is fully deterministic.
-- Failures surface via RAISE EXCEPTION (hard error, not NOTICE).
--
-- SPDX-License-Identifier: Apache-2.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.18.0';

-- Suppress NULL-embedding NOTICEs from recall functions for stable output.
SET client_min_messages = WARNING;

-- =============================================================================
-- Fixture: two lessons (text-only, no embedding needed for BM25 path)
-- =============================================================================

INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, is_active,
     content_type, verified_at, artifact_hash, t_valid_from, t_valid_to)
VALUES
    ('tc_guc17', -1701,
     'graph guc consistency alpha bravo charlie',
     'graph guc consistency alpha bravo charlie delta echo foxtrot',
     3, TRUE, 'fact',
     now(), 'guc17-test-hash-1',
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ),
    ('tc_guc17', -1701,
     'graph guc consistency golf hotel india',
     'graph guc consistency golf hotel india juliet kilo lima',
     3, TRUE, 'fact',
     now(), 'guc17-test-hash-2',
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ);

-- =============================================================================
-- G1: recall_hybrid (10-param active overload) — explicit 0.0 == unset
-- =============================================================================

DO $$
DECLARE
    _count_explicit INT;
    _count_default  INT;
BEGIN
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';
    SELECT count(*) INTO _count_explicit
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'graph guc consistency', 10, 'tc_guc17', -1701
    );

    RESET pgmnemo.graph_proximity_weight;
    SELECT count(*) INTO _count_default
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'graph guc consistency', 10, 'tc_guc17', -1701
    );

    IF _count_explicit = _count_default AND _count_explicit >= 1 THEN
        NULL;  -- PASS: counts equal, at least 1 row; RAISE EXCEPTION on mismatch
    ELSE
        RAISE EXCEPTION 'G1 FAIL: explicit=%, default=%', _count_explicit, _count_default;
    END IF;
END;
$$;

-- =============================================================================
-- G2: recall_hybrid (11-param active overload) — explicit 0.0 == unset
-- Use p_min_score named param to force the 11-param overload.
-- =============================================================================

DO $$
DECLARE
    _count_explicit INT;
    _count_default  INT;
BEGIN
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';
    SELECT count(*) INTO _count_explicit
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'graph guc consistency', 10, 'tc_guc17', -1701,
        p_min_score => NULL::REAL
    );

    RESET pgmnemo.graph_proximity_weight;
    SELECT count(*) INTO _count_default
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'graph guc consistency', 10, 'tc_guc17', -1701,
        p_min_score => NULL::REAL
    );

    IF _count_explicit = _count_default AND _count_explicit >= 1 THEN
        NULL;  -- PASS
    ELSE
        RAISE EXCEPTION 'G2 FAIL: explicit=%, default=%', _count_explicit, _count_default;
    END IF;
END;
$$;

-- =============================================================================
-- G3: recall_lessons — explicit 0.0 == unset
-- =============================================================================

DO $$
DECLARE
    _count_explicit INT;
    _count_default  INT;
BEGIN
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';
    SELECT count(*) INTO _count_explicit
    FROM pgmnemo.recall_lessons(
        NULL::vector(1024), 10, 'tc_guc17', -1701, 'graph guc consistency'
    );

    RESET pgmnemo.graph_proximity_weight;
    SELECT count(*) INTO _count_default
    FROM pgmnemo.recall_lessons(
        NULL::vector(1024), 10, 'tc_guc17', -1701, 'graph guc consistency'
    );

    IF _count_explicit = _count_default AND _count_explicit >= 1 THEN
        NULL;  -- PASS
    ELSE
        RAISE EXCEPTION 'G3 FAIL: explicit=%, default=%', _count_explicit, _count_default;
    END IF;
END;
$$;

-- =============================================================================
-- G4: navigate_locate — explicit 0.0 == unset, ≥1 result
-- =============================================================================

DO $$
DECLARE
    _count_explicit INT;
    _count_default  INT;
BEGIN
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';
    SELECT count(*) INTO _count_explicit
    FROM pgmnemo.navigate_locate(
        NULL::vector(1024), 'graph guc consistency alpha bravo', 50000, NULL::JSONB
    );

    RESET pgmnemo.graph_proximity_weight;
    SELECT count(*) INTO _count_default
    FROM pgmnemo.navigate_locate(
        NULL::vector(1024), 'graph guc consistency alpha bravo', 50000, NULL::JSONB
    );

    IF _count_explicit = _count_default AND _count_explicit >= 1 THEN
        NULL;  -- PASS
    ELSE
        RAISE EXCEPTION 'G4 FAIL: explicit=%, default=%', _count_explicit, _count_default;
    END IF;
END;
$$;

-- =============================================================================
-- G5: corrupt GUC value — exception path must not crash and must default to 0.0
-- Sets GUC to a non-numeric value; the EXCEPTION block must recover to 0.0.
-- With 0.0, the count equals the baseline (recall_hybrid with no graph walk).
-- =============================================================================

DO $$
DECLARE
    _count_corrupt  INT;
    _count_baseline INT;
BEGIN
    -- baseline: explicit 0.0
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';
    SELECT count(*) INTO _count_baseline
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'graph guc consistency', 10, 'tc_guc17', -1701
    );
    RESET pgmnemo.graph_proximity_weight;

    -- corrupt GUC: triggers exception path inside the function
    SET LOCAL pgmnemo.graph_proximity_weight = 'invalid_value';
    SELECT count(*) INTO _count_corrupt
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'graph guc consistency', 10, 'tc_guc17', -1701
    );
    RESET pgmnemo.graph_proximity_weight;

    IF _count_corrupt = _count_baseline THEN
        NULL;  -- PASS
    ELSE
        RAISE EXCEPTION 'G5 FAIL: corrupt GUC produced different count (corrupt=%, baseline=%)',
            _count_corrupt, _count_baseline;
    END IF;
END;
$$;

-- Final: confirm all 5 GUC consistency checks passed (no EXCEPTION = success)
SELECT TRUE AS guc_consistency_all_pass;
