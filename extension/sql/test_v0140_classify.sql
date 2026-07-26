-- test_v0140_classify.sql
-- pg_regress tests for pgmnemo v0.14.0 — Corpus self-maintenance: classify-on-write
--
-- Coverage:
--   A1: classify_content_type exists — 1 param, text, immutable, strict
--   B1–B5: classifier returns correct label per category
--   B6: unclassifiable text returns NULL (no forced label)
--   C1: NULL input → NULL output (STRICT)
--   D1: reclassify_corpus exists — 2 params (p_dry_run, p_limit)
--   D2: dry-run returns both 'before' and 'after' phases
--   D3: dry-run totals match (total rows conserved)
--   D4: dry-run shows monoculture breaking (≥ 2 non-procedure types gain counts)
--   E1: ingest() has 10 params (p_content_type added)
--   E2: ingest() auto-fills content_type when NULL
--   E3: ingest() explicit content_type wins over auto-derive
--
-- Test isolation: role 'tc_cls', project_id -1400.
-- Gate off: bypass provenance requirements for controlled inserts.

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.14.2';

-- ─────────────────────────────────────────────────────────────────────────────
-- A: classify_content_type — signature
-- ─────────────────────────────────────────────────────────────────────────────

-- A1: 1 param, returns text, IMMUTABLE, STRICT
SELECT
    p.pronargs                                            AS nargs,
    pg_catalog.format_type(p.prorettype, NULL)            AS rettype,
    CASE p.provolatile WHEN 'i' THEN 'immutable' END      AS volatility,
    p.proisstrict                                         AS strict
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'classify_content_type';

-- ─────────────────────────────────────────────────────────────────────────────
-- B: classify_content_type — correct label per category
-- ─────────────────────────────────────────────────────────────────────────────

-- B1: incident — root-cause language
SELECT pgmnemo.classify_content_type(
    'root cause of the failure: DB connection timed out and crashed the service.'
) AS b1_incident;

-- B2: decision — "decided" verb
SELECT pgmnemo.classify_content_type(
    'We decided to use psycopg2 instead of asyncpg because synchronous was sufficient.'
) AS b2_decision;

-- B3: entity — "is the canonical service"
SELECT pgmnemo.classify_content_type(
    'The agency-v3-next container is the canonical service for all new task dispatch.'
) AS b3_entity;

-- B4: fact — default port assertion (no instructional verb, no "when")
SELECT pgmnemo.classify_content_type(
    'The default port is 5433 for the PostgreSQL container in Docker Compose.'
) AS b4_fact;

-- B5: procedure — "when" trigger word + "always"
SELECT pgmnemo.classify_content_type(
    'When deploying, always run alembic upgrade head before starting the API.'
) AS b5_procedure;

-- B6: unclassifiable — no pattern match → NULL
SELECT pgmnemo.classify_content_type(
    'Interesting observation without any clear category signals.'
) AS b6_null;

-- ─────────────────────────────────────────────────────────────────────────────
-- C: STRICT behaviour
-- ─────────────────────────────────────────────────────────────────────────────

-- C1: NULL input → NULL output (STRICT, no exception)
SELECT pgmnemo.classify_content_type(NULL) IS NULL AS c1_null_in_null_out;

-- ─────────────────────────────────────────────────────────────────────────────
-- D: reclassify_corpus — signature and dry-run semantics
-- ─────────────────────────────────────────────────────────────────────────────

-- D1: 2 params (p_dry_run, p_limit)
SELECT p.pronargs AS d1_nargs
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'reclassify_corpus';

-- Seed diverse lessons so dry-run monoculture test is self-contained
INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, content_type, is_active, t_valid_to)
VALUES
    ('tc_cls', -1400, 'seed-a',
     'root cause of the crash: DB connection lost due to network timeout and service crashed because of it.',
     3, 'procedure', true, 'infinity'),
    ('tc_cls', -1400, 'seed-b',
     'root cause of the failure: memory leak triggered the OOM killer and caused the crash.',
     3, 'procedure', true, 'infinity'),
    ('tc_cls', -1400, 'seed-c',
     'We decided to adopt psycopg2 instead of asyncpg because synchronous code is simpler.',
     3, 'procedure', true, 'infinity'),
    ('tc_cls', -1400, 'seed-d',
     'The default port is 5432 for the PostgreSQL Docker service in all environments.',
     3, 'procedure', true, 'infinity'),
    ('tc_cls', -1400, 'seed-e',
     'When deploying to production, always run alembic upgrade head before starting the API.',
     3, 'procedure', true, 'infinity'),
    ('tc_cls', -1400, 'seed-f',
     'The gateway-service is the canonical service for all external API requests.',
     3, 'procedure', true, 'infinity');

-- D2: dry-run returns both 'before' and 'after' phases
SELECT count(DISTINCT phase) >= 2 AS d2_both_phases
FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 100);

-- D3: totals match (labels redistribute but corpus size is unchanged)
SELECT
    SUM(CASE WHEN phase = 'before' THEN cnt END) AS before_total,
    SUM(CASE WHEN phase = 'after'  THEN cnt END) AS after_total,
    SUM(CASE WHEN phase = 'before' THEN cnt END)
        = SUM(CASE WHEN phase = 'after' THEN cnt END) AS d3_totals_match
FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 200);

-- D4: at least 2 non-procedure types gain counts in the after distribution
SELECT count(*) >= 2 AS d4_monoculture_broken
FROM pgmnemo.reclassify_corpus(p_dry_run => true, p_limit => 500)
WHERE phase = 'after'
  AND content_type IS NOT NULL
  AND content_type != 'procedure'
  AND cnt > 0;

-- Cleanup seeded rows
DELETE FROM pgmnemo.agent_lesson
WHERE role = 'tc_cls' AND project_id = -1400;

-- ─────────────────────────────────────────────────────────────────────────────
-- E: ingest() — 10-param signature and content_type auto-fill
-- ─────────────────────────────────────────────────────────────────────────────

-- E1: 10 parameters
SELECT p.pronargs AS e1_nargs
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'ingest';

-- E2: auto-fill — 9-arg call (no p_content_type) → classifier derives 'procedure'
-- Note: DO block required — FROM ingest() AS id JOIN agent_lesson cannot see
--       rows inserted by the same command (PostgreSQL intra-command snapshot).
DO $$
DECLARE v_id BIGINT; v_ct TEXT;
BEGIN
    v_id := pgmnemo.ingest(
        'tc_cls'::text,
        -1400::int,
        'deploy-test'::text,
        'When running the deploy script, always check that environment variables are set first.'::text,
        3::smallint,
        NULL::vector,
        NULL::text,
        'deadbeef0000000000000000000000000000000000000000000000000000001a'::text,
        '{}'::jsonb
    );
    SELECT content_type INTO v_ct FROM pgmnemo.agent_lesson WHERE id = v_id;
    RAISE NOTICE 'e2_autofill: %', v_ct;
END;
$$;

-- E3: explicit content_type wins over classifier (procedure text → decision explicit)
-- Note: DO block required — same PostgreSQL intra-command snapshot rule.
DO $$
DECLARE v_id BIGINT; v_ct TEXT;
BEGIN
    v_id := pgmnemo.ingest(
        'tc_cls'::text,
        -1400::int,
        'explicit-type-test'::text,
        'When running the deploy script, always check that environment variables are set.'::text,
        3::smallint,
        NULL::vector,
        NULL::text,
        'deadbeef0000000000000000000000000000000000000000000000000000002b'::text,
        '{}'::jsonb,
        'decision'::text
    );
    SELECT content_type INTO v_ct FROM pgmnemo.agent_lesson WHERE id = v_id;
    RAISE NOTICE 'e3_explicit_wins: %', v_ct;
END;
$$;

-- Cleanup ingest test rows
DELETE FROM pgmnemo.agent_lesson
WHERE role = 'tc_cls' AND project_id = -1400;
