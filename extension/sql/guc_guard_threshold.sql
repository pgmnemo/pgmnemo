-- guc_guard_threshold.sql
-- Regression: PGMNEMO-0122-2 — guard_no_test_project uses GUC floor, not hardcoded threshold
--
-- Proves that pgmnemo.guard_no_test_project() respects the caller-configured GUC
-- pgmnemo.test_project_floor rather than any hardcoded project_id threshold.
--
-- Coverage:
--   G1: Only one guard function exists (2-arg); no 0-arg overload present.
--   G2: Default floor=0 — project_id=42 is NOT blocked (old hardcoded <=100 would block it).
--   G3: Custom floor=500 — project_id=500 IS blocked (at/below floor).
--   G4: Custom floor=500 — project_id=501 is NOT blocked (above floor).
--   G5: Floor reset to 0 — project_id=1 is NOT blocked (smallest positive id passes).
--
-- The v0.12.0 guard had a hardcoded project_id <= 100 check; v0.12.1+ reads the GUC.
-- SPDX-License-Identifier: Apache-2.0

ALTER EXTENSION pgmnemo UPDATE TO '0.15.0';

-- ─────────────────────────────────────────────────────────────────────────────
-- G1: Exactly one guard function; no 0-arg overload
-- ─────────────────────────────────────────────────────────────────────────────

SELECT count(*) = 1 AS exactly_one_guard
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'guard_no_test_project';

SELECT count(*) = 0 AS no_0arg_overload
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'guard_no_test_project'
  AND p.pronargs = 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- G2: Default floor=0 — project_id=42 passes (hardcoded <=100 would block)
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.test_project_floor = 0;

DO $$
BEGIN
    PERFORM pgmnemo.guard_no_test_project(42);
    RAISE NOTICE 'floor0_allowed_ok: project_id=42 passes with floor=0';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'UNEXPECTED_blocked: project_id=42 blocked with floor=0: %', SQLERRM;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G3: Custom floor=500 — project_id=500 IS blocked (at the floor)
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.test_project_floor = 500;

DO $$
BEGIN
    PERFORM pgmnemo.guard_no_test_project(500);
    RAISE NOTICE 'UNEXPECTED_allowed: project_id=500 not blocked at floor=500';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'floor500_blocked_ok: project_id=500 blocked at floor=500';
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G4: Custom floor=500 — project_id=501 is NOT blocked (above the floor)
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM pgmnemo.guard_no_test_project(501);
    RAISE NOTICE 'floor500_allowed_ok: project_id=501 passes above floor=500';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'UNEXPECTED_blocked: project_id=501 blocked above floor=500: %', SQLERRM;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G5: Reset floor to 0 — project_id=1 (smallest positive) passes
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.test_project_floor = 0;

DO $$
BEGIN
    PERFORM pgmnemo.guard_no_test_project(1);
    RAISE NOTICE 'floor0_allowed_ok: project_id=1 passes with floor=0 (no scheme imposed)';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'UNEXPECTED_blocked: project_id=1 blocked with floor=0: %', SQLERRM;
END;
$$;
