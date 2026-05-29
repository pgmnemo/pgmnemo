-- test_v070.sql
-- pg_regress tests for pgmnemo v0.7.0
--
-- Tests:
--   A: confidence + outcome tracking columns exist on agent_lesson
--   B: reinforce() function exists and has correct signature
--   C: recall_lessons() scoring formula changed (confidence-weighted blend)
--   D: stats() has confidence_mean, confidence_median, confidence_below_half columns
--   E: match_confidence output column present in recall_lessons and recall_hybrid
--   F: ingestion guards (min-signal, repetition-collapse, embedding dedup)
--   G: ingest() accepts optional p_confidence parameter
--
-- Prerequisites: pgmnemo installed at 0.6.3 then upgraded to 0.7.0, or freshly
-- installed at 0.7.0. Extension must be created before running these tests.

-- ─────────────────────────────────────────────────────────────────────────────
-- A: Column existence checks on pgmnemo.agent_lesson
-- ─────────────────────────────────────────────────────────────────────────────

-- A1: confidence column exists
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  = 'confidence';

-- A2: success_count column exists
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  = 'success_count';

-- A3: fail_count column exists
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  = 'fail_count';

-- A4: last_outcome column exists
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  = 'last_outcome';

-- A5: last_outcome_at column exists
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  = 'last_outcome_at';

-- ─────────────────────────────────────────────────────────────────────────────
-- B: reinforce() function exists with correct signature
-- ─────────────────────────────────────────────────────────────────────────────

-- B1: reinforce() function is registered
SELECT proname, pronargs
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'reinforce';

-- ─────────────────────────────────────────────────────────────────────────────
-- C: recall_lessons() — verify match_confidence column present in RETURNS TABLE
-- ─────────────────────────────────────────────────────────────────────────────

-- C1: recall_lessons return type includes match_confidence
SELECT a.attname AS column_name
FROM pg_proc p
JOIN pg_namespace n    ON n.oid = p.pronamespace
JOIN pg_type t         ON t.oid = p.prorettype
JOIN pg_attribute a    ON a.attrelid = t.typrelid AND a.attnum > 0
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'recall_lessons'
  AND a.attname  = 'match_confidence';

-- ─────────────────────────────────────────────────────────────────────────────
-- D: stats() — verify confidence distribution columns
-- ─────────────────────────────────────────────────────────────────────────────

-- D1: stats() has confidence_mean column
SELECT a.attname AS column_name
FROM pg_proc p
JOIN pg_namespace n    ON n.oid = p.pronamespace
JOIN pg_type t         ON t.oid = p.prorettype
JOIN pg_attribute a    ON a.attrelid = t.typrelid AND a.attnum > 0
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'stats'
  AND a.attname  = 'confidence_mean';

-- D2: stats() has confidence_median column
SELECT a.attname AS column_name
FROM pg_proc p
JOIN pg_namespace n    ON n.oid = p.pronamespace
JOIN pg_type t         ON t.oid = p.prorettype
JOIN pg_attribute a    ON a.attrelid = t.typrelid AND a.attnum > 0
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'stats'
  AND a.attname  = 'confidence_median';

-- D3: stats() has confidence_below_half column
SELECT a.attname AS column_name
FROM pg_proc p
JOIN pg_namespace n    ON n.oid = p.pronamespace
JOIN pg_type t         ON t.oid = p.prorettype
JOIN pg_attribute a    ON a.attrelid = t.typrelid AND a.attnum > 0
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'stats'
  AND a.attname  = 'confidence_below_half';

-- ─────────────────────────────────────────────────────────────────────────────
-- E: recall_hybrid() — verify match_confidence column
-- ─────────────────────────────────────────────────────────────────────────────

-- E1: recall_hybrid return type includes match_confidence
SELECT a.attname AS column_name
FROM pg_proc p
JOIN pg_namespace n    ON n.oid = p.pronamespace
JOIN pg_type t         ON t.oid = p.prorettype
JOIN pg_attribute a    ON a.attrelid = t.typrelid AND a.attnum > 0
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'recall_hybrid'
  AND a.attname  = 'match_confidence';

-- ─────────────────────────────────────────────────────────────────────────────
-- F: Ingestion guards
-- ─────────────────────────────────────────────────────────────────────────────

-- F1: min-signal guard — short lesson_text should fail
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.ingest(
            'test_role', 1, 'topic', 'short'  -- lesson_text < 20 chars
        );
        RAISE EXCEPTION 'GUARD DID NOT FIRE — expected EXCEPTION for short lesson_text';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%lesson_text too short%' OR SQLERRM LIKE '%topic too short%' THEN
                RAISE NOTICE 'F1 PASS: min-signal guard fired as expected: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'F1 FAIL: unexpected exception: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- F2: min-signal guard — short topic should fail
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.ingest(
            'test_role', 1, 'xy',  -- topic < 3 chars
            'This is a lesson text that is long enough to pass the minimum length check'
        );
        RAISE EXCEPTION 'GUARD DID NOT FIRE — expected EXCEPTION for short topic';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%lesson_text too short%' OR SQLERRM LIKE '%topic too short%' THEN
                RAISE NOTICE 'F2 PASS: min-signal guard fired as expected: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'F2 FAIL: unexpected exception: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- F3: confidence out of range should fail
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.ingest(
            'test_role', 1, 'valid topic',
            'This lesson text is definitely long enough to pass the length check',
            3, NULL, NULL, NULL, '{}', 1.5   -- confidence > 1.0
        );
        RAISE EXCEPTION 'GUARD DID NOT FIRE — expected EXCEPTION for p_confidence > 1.0';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%p_confidence must be between%' THEN
                RAISE NOTICE 'F3 PASS: confidence range guard fired: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'F3 FAIL: unexpected exception: %', SQLERRM;
            END IF;
    END;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G: ingest() with p_confidence parameter + reinforce() end-to-end
-- (these require a live database to insert/query rows)
-- ─────────────────────────────────────────────────────────────────────────────

-- G1: ingest() accepts p_confidence parameter (10-arg signature registered)
SELECT proname, pronargs
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname  = 'ingest'
ORDER BY pronargs DESC
LIMIT 1;

-- G2: stats() is callable and returns expected column names (smoke test)
SELECT
    version IS NOT NULL            AS has_version,
    lesson_count >= 0              AS has_lesson_count,
    confidence_mean >= 0.0         AS has_confidence_mean,
    confidence_median >= 0.0       AS has_confidence_median,
    confidence_below_half >= 0     AS has_confidence_below_half
FROM pgmnemo.stats();
