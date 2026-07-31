-- test_v0140_classify.sql
-- pg_regress tests for pgmnemo v0.14.0 — Corpus self-maintenance: classify-on-write
--
-- Coverage:
--   A1: classify_content_type exists with 1 param, returns text, is IMMUTABLE + STRICT
--   B1–B5: classifier returns correct category for each label
--   B6: unclassifiable text returns NULL (no forced label)
--   C1: NULL input → NULL output (STRICT guarantee)
--   D1: reclassify_corpus exists with 2 params (p_dry_run, p_limit)
--   D2: dry-run returns 'before' and 'after' phases
--   D3: dry-run totals match (labels redistribute, corpus size unchanged)
--   D4: dry-run shows monoculture breaking (>= 2 non-procedure types with count > 0)
--   E1: ingest() has 10 params (p_content_type added)
--   E2: ingest() auto-fills content_type when NULL (no explicit value)
--   E3: ingest() explicit content_type wins over auto-derive
--
-- Test role 'tc_cls' and project_id -1400 isolate data from all other tests.
-- gate_strict off: bypass provenance gate for testing.
-- =============================================================================

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.16.0';

-- =============================================================================
-- A: classify_content_type — function exists and has correct signature
-- =============================================================================

-- A1: classify_content_type exists with exactly 1 parameter, returns text, is IMMUTABLE
DO $$
DECLARE
    _nargs   INT;
    _rettype TEXT;
    _vol     TEXT;
    _strict  BOOL;
BEGIN
    SELECT p.pronargs,
           pg_catalog.format_type(p.prorettype, NULL),
           CASE p.provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' ELSE 'volatile' END,
           p.proisstrict
    INTO _nargs, _rettype, _vol, _strict
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'classify_content_type';

    IF _nargs = 1 AND _rettype = 'text' AND _vol = 'immutable' AND _strict THEN
        RAISE NOTICE 'A1 PASS: classify_content_type(text) — 1 param, text, immutable, strict';
    ELSE
        RAISE EXCEPTION 'A1 FAIL: nargs=%, rettype=%, vol=%, strict=%',
            _nargs, _rettype, _vol, _strict;
    END IF;
END;
$$;

-- =============================================================================
-- B: classify_content_type — correct category per label
-- =============================================================================

-- B1: incident — root-cause pattern
DO $$
DECLARE _ct TEXT;
BEGIN
    SELECT pgmnemo.classify_content_type(
        'root cause of the failure: the DB connection timed out and crashed the service.'
    ) INTO _ct;
    IF _ct = 'incident' THEN
        RAISE NOTICE 'B1 PASS: root-cause text → incident';
    ELSE
        RAISE EXCEPTION 'B1 FAIL: expected incident, got %', _ct;
    END IF;
END;
$$;

-- B2: decision — explicit decided/chose pattern
DO $$
DECLARE _ct TEXT;
BEGIN
    SELECT pgmnemo.classify_content_type(
        'We decided to use psycopg2 instead of asyncpg because synchronous was sufficient.'
    ) INTO _ct;
    IF _ct = 'decision' THEN
        RAISE NOTICE 'B2 PASS: decided-text → decision';
    ELSE
        RAISE EXCEPTION 'B2 FAIL: expected decision, got %', _ct;
    END IF;
END;
$$;

-- B3: entity — "is the canonical service" (adjective between article and type)
DO $$
DECLARE _ct TEXT;
BEGIN
    SELECT pgmnemo.classify_content_type(
        'The agency-v3-next container is the canonical service for all new task dispatch.'
    ) INTO _ct;
    IF _ct = 'entity' THEN
        RAISE NOTICE 'B3 PASS: is-the-canonical-service → entity';
    ELSE
        RAISE EXCEPTION 'B3 FAIL: expected entity, got %', _ct;
    END IF;
END;
$$;

-- B4: fact — default port assertion (no instructional verbs, no "when")
DO $$
DECLARE _ct TEXT;
BEGIN
    SELECT pgmnemo.classify_content_type(
        'The default port is 5433 for the PostgreSQL container in Docker Compose.'
    ) INTO _ct;
    IF _ct = 'fact' THEN
        RAISE NOTICE 'B4 PASS: default-port-is → fact';
    ELSE
        RAISE EXCEPTION 'B4 FAIL: expected fact, got %', _ct;
    END IF;
END;
$$;

-- B5: procedure — "when" trigger word
DO $$
DECLARE _ct TEXT;
BEGIN
    SELECT pgmnemo.classify_content_type(
        'When deploying, always run alembic upgrade head before starting the API.'
    ) INTO _ct;
    IF _ct = 'procedure' THEN
        RAISE NOTICE 'B5 PASS: when-deploying → procedure';
    ELSE
        RAISE EXCEPTION 'B5 FAIL: expected procedure, got %', _ct;
    END IF;
END;
$$;

-- B6: NULL returned for text that matches no pattern
DO $$
DECLARE _ct TEXT;
BEGIN
    SELECT pgmnemo.classify_content_type('Interesting observation without clear category signals.')
    INTO _ct;
    IF _ct IS NULL THEN
        RAISE NOTICE 'B6 PASS: no-pattern text → NULL (no forced label)';
    ELSE
        RAISE EXCEPTION 'B6 FAIL: expected NULL, got %', _ct;
    END IF;
END;
$$;

-- =============================================================================
-- C: STRICT behaviour — NULL in → NULL out
-- =============================================================================

-- C1: NULL input returns NULL (STRICT guarantee, no exception)
SELECT pgmnemo.classify_content_type(NULL) IS NULL AS c1_null_in_null_out;

-- =============================================================================
-- D: reclassify_corpus — signature and dry-run behaviour
-- =============================================================================

-- D1: reclassify_corpus exists with 2 params
DO $$
DECLARE _nargs INT;
BEGIN
    SELECT p.pronargs INTO _nargs
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'reclassify_corpus';

    IF _nargs = 2 THEN
        RAISE NOTICE 'D1 PASS: reclassify_corpus has 2 params (p_dry_run, p_limit)';
    ELSE
        RAISE EXCEPTION 'D1 FAIL: expected 2 params, got %', _nargs;
    END IF;
END;
$$;

-- D2: dry-run (p_limit=100) returns both 'before' and 'after' phases
SELECT count(DISTINCT phase) >= 2 AS d2_both_phases
FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 100);

-- D3: dry-run totals match — labels redistribute but corpus size is unchanged
DO $$
DECLARE
    _before_total BIGINT;
    _after_total  BIGINT;
BEGIN
    SELECT SUM(cnt) INTO _before_total
    FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 200)
    WHERE phase = 'before';

    SELECT SUM(cnt) INTO _after_total
    FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 200)
    WHERE phase = 'after';

    IF _before_total = _after_total THEN
        RAISE NOTICE 'D3 PASS: dry-run totals match — before=%, after=%',
            _before_total, _after_total;
    ELSE
        RAISE EXCEPTION 'D3 FAIL: totals differ — before=%, after=%',
            _before_total, _after_total;
    END IF;
END;
$$;

-- D4: dry-run shows monoculture breaking — at least 2 non-procedure, non-NULL types with cnt > 0
DO $$
DECLARE _non_proc INT;
BEGIN
    SELECT count(*) INTO _non_proc
    FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 500)
    WHERE phase = 'after'
      AND content_type IS NOT NULL
      AND content_type != 'procedure'
      AND cnt > 0;

    IF _non_proc >= 2 THEN
        RAISE NOTICE 'D4 PASS: monoculture broken — % non-procedure types gained counts', _non_proc;
    ELSE
        RAISE EXCEPTION 'D4 FAIL: only % non-procedure types in after distribution (need >= 2)', _non_proc;
    END IF;
END;
$$;

-- =============================================================================
-- E: ingest() — 10-param signature and content_type auto-fill
-- =============================================================================

-- E1: ingest has exactly 10 parameters
DO $$
DECLARE _nargs INT;
BEGIN
    SELECT p.pronargs INTO _nargs
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = 'ingest';

    IF _nargs = 10 THEN
        RAISE NOTICE 'E1 PASS: ingest() has 10 parameters (p_content_type added)';
    ELSE
        RAISE EXCEPTION 'E1 FAIL: expected 10 params, got %', _nargs;
    END IF;
END;
$$;

-- E2: ingest() auto-fills content_type when not supplied (9-arg call, old-style)
DO $$
DECLARE
    _id BIGINT;
    _ct TEXT;
BEGIN
    -- 9-arg call (backward compat): content_type is NULL → should be auto-derived
    SELECT pgmnemo.ingest(
        'tc_cls',   -- role
        -1400,      -- project_id
        'deploy-test',
        'When running the deploy script, always check that the environment variables are set first.',
        3,          -- importance
        NULL,       -- embedding
        NULL,       -- commit_sha
        'deadbeef00000000000000000000000000000000000000000000000000000001',  -- artifact_hash
        '{}'::jsonb -- metadata
        -- p_content_type omitted → auto-derive
    ) INTO _id;

    SELECT content_type INTO _ct
    FROM pgmnemo.agent_lesson WHERE id = _id;

    -- "When running ... always check" → procedure
    IF _ct = 'procedure' THEN
        RAISE NOTICE 'E2 PASS: ingest() auto-filled content_type=procedure for procedure text (id=%)', _id;
    ELSE
        RAISE EXCEPTION 'E2 FAIL: expected procedure, got % (id=%)', _ct, _id;
    END IF;

    -- Clean up
    DELETE FROM pgmnemo.agent_lesson WHERE id = _id;
END;
$$;

-- E3: ingest() explicit content_type wins over classifier
DO $$
DECLARE
    _id BIGINT;
    _ct TEXT;
BEGIN
    SELECT pgmnemo.ingest(
        'tc_cls',
        -1400,
        'explicit-type-test',
        'When running the deploy script, always check that the environment variables are set.',
        3,
        NULL,
        NULL,
        'deadbeef00000000000000000000000000000000000000000000000000000002',
        '{}'::jsonb,
        'decision'   -- explicit p_content_type: should override classifier result
    ) INTO _id;

    SELECT content_type INTO _ct
    FROM pgmnemo.agent_lesson WHERE id = _id;

    IF _ct = 'decision' THEN
        RAISE NOTICE 'E3 PASS: explicit content_type=decision preserved despite procedure text (id=%)', _id;
    ELSE
        RAISE EXCEPTION 'E3 FAIL: expected decision (explicit), got % (id=%)', _ct, _id;
    END IF;

    -- Clean up
    DELETE FROM pgmnemo.agent_lesson WHERE id = _id;
END;
$$;
