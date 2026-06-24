-- test_v0120_remember_relation.sql
-- pgmnemo v0.12.0 real-DB integration tests: add_edge fix + remember_relation
-- ADDENDUM-2 R8: uq_mem_edge_active partial index must exist for add_edge upsert.
-- All tests use project_id=99999 (> 100 guard threshold).
--
-- Coverage:
--   T1  uq_mem_edge_active index present after 0.12.0 install
--   T2  add_edge first insert succeeds (no conflict yet)
--   T3  add_edge idempotent: same triple, higher weight — no duplicate row
--   T4  add_edge max-mode: weight does not decrease below prior max
--   T5  add_edge avg-mode: weight averages correctly
--   T6  add_edge replace-mode: weight replaced unconditionally
--   T7  only one active edge per triple (valid_until IS NULL)
--   T8  remember_relation inserts new relation lesson
--   T9  remember_relation content_type = 'relation'
--   T10 remember_relation topic encoding: from:rel_type:to
--   T11 remember_relation artifact_hash = 'rel-from:type:to'
--   T12 remember_relation idempotent: second call returns same id, raises confidence
--   T13 remember_relation state routing: system → validated
--   T14 remember_relation state routing: auto_captured → candidate
--   T15 remember_relation state routing: agent_authored high-conf → validated
--   T16 remember_relation state routing: agent_authored low-conf → candidate
--   T17 remember_relation mem_edge dual-write when entity hubs exist
--   T18 remember_relation mem_edge skipped gracefully when hubs missing (notice only)
--   T19 remember_relation invalid from_key raises exception
--   T20 remember_relation invalid to_key raises exception
--   T21 remember_relation NULL relation_type raises exception
--   T22 remember_relation NULL embedding fail-open (R5)
--   T23 guard_no_test_project blocks prod-range project_id
--   T24 remember_relation metadata contains from_key, to_key, relation_type
--
-- SPDX-License-Identifier: Apache-2.0

-- ── setup ───────────────────────────────────────────────────────────────────

\set TEST_PROJECT 99999
\set FROM_KEY     'person:alice'
\set TO_KEY       'org:acme'
\set REL_TYPE     'works_for'

BEGIN;

-- Scratch tables for test tracking
CREATE TEMP TABLE _rel_test_results (
    test_no  INT,
    name     TEXT,
    ok       BOOLEAN,
    detail   TEXT
) ON COMMIT DROP;

-- Helper: record pass
CREATE OR REPLACE FUNCTION _rel_pass(n INT, nm TEXT, det TEXT DEFAULT '')
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO _rel_test_results VALUES (n, nm, TRUE, det);
$$;

-- Helper: record fail
CREATE OR REPLACE FUNCTION _rel_fail(n INT, nm TEXT, det TEXT DEFAULT '')
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO _rel_test_results VALUES (n, nm, FALSE, det);
$$;

-- ── T1 uq_mem_edge_active index present ─────────────────────────────────────
DO $$
DECLARE v BOOLEAN;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM pg_indexes
        WHERE schemaname='pgmnemo' AND tablename='mem_edge'
          AND indexname='uq_mem_edge_active'
    ) INTO v;
    IF v THEN PERFORM _rel_pass(1, 'uq_mem_edge_active index present');
    ELSE PERFORM _rel_fail(1, 'uq_mem_edge_active index present', 'INDEX MISSING — add_edge will fail');
    END IF;
END;
$$;

-- Insert entity hub lessons for T2–T7, T17
INSERT INTO pgmnemo.agent_lesson (role, project_id, topic, lesson_text, importance, artifact_hash, content_type, state, version_n, t_valid_from, t_valid_to)
VALUES ('test', :TEST_PROJECT, :'FROM_KEY', 'Alice entity hub', 3, 'entity-person:alice', 'entity', 'validated', 1, NOW(), 'infinity')
ON CONFLICT DO NOTHING;
INSERT INTO pgmnemo.agent_lesson (role, project_id, topic, lesson_text, importance, artifact_hash, content_type, state, version_n, t_valid_from, t_valid_to)
VALUES ('test', :TEST_PROJECT, :'TO_KEY', 'ACME org hub', 3, 'entity-org:acme', 'entity', 'validated', 1, NOW(), 'infinity')
ON CONFLICT DO NOTHING;

-- Grab hub IDs
\set ALICE_ID (SELECT id FROM pgmnemo.agent_lesson WHERE topic = 'person:alice' AND project_id = 99999 AND is_active LIMIT 1)
\set ACME_ID  (SELECT id FROM pgmnemo.agent_lesson WHERE topic = 'org:acme'     AND project_id = 99999 AND is_active LIMIT 1)

-- ── T2 add_edge first insert ─────────────────────────────────────────────────
DO $$
DECLARE
    alice_id BIGINT;
    acme_id  BIGINT;
BEGIN
    SELECT id INTO alice_id FROM pgmnemo.agent_lesson WHERE topic='person:alice' AND project_id=99999 AND is_active LIMIT 1;
    SELECT id INTO acme_id  FROM pgmnemo.agent_lesson WHERE topic='org:acme'     AND project_id=99999 AND is_active LIMIT 1;
    BEGIN
        PERFORM pgmnemo.add_edge(alice_id, acme_id, 'CAUSED_BY', 0.7, '{}', 'max');
        PERFORM _rel_pass(2, 'add_edge first insert succeeds');
    EXCEPTION WHEN OTHERS THEN
        PERFORM _rel_fail(2, 'add_edge first insert succeeds', SQLERRM);
    END;
END;
$$;

-- ── T3 add_edge idempotent (no dup row) ─────────────────────────────────────
DO $$
DECLARE
    alice_id BIGINT;
    acme_id  BIGINT;
    cnt      INT;
BEGIN
    SELECT id INTO alice_id FROM pgmnemo.agent_lesson WHERE topic='person:alice' AND project_id=99999 AND is_active LIMIT 1;
    SELECT id INTO acme_id  FROM pgmnemo.agent_lesson WHERE topic='org:acme'     AND project_id=99999 AND is_active LIMIT 1;
    PERFORM pgmnemo.add_edge(alice_id, acme_id, 'CAUSED_BY', 0.9, '{}', 'max');
    SELECT COUNT(*) INTO cnt FROM pgmnemo.mem_edge
    WHERE source_id=alice_id AND target_id=acme_id AND relation_type='CAUSED_BY' AND valid_until IS NULL;
    IF cnt = 1 THEN PERFORM _rel_pass(3, 'add_edge idempotent: single active row');
    ELSE PERFORM _rel_fail(3, 'add_edge idempotent: single active row', 'count='||cnt);
    END IF;
END;
$$;

-- ── T4 add_edge max-mode: weight non-decreasing ──────────────────────────────
DO $$
DECLARE
    alice_id BIGINT;
    acme_id  BIGINT;
    w        FLOAT8;
BEGIN
    SELECT id INTO alice_id FROM pgmnemo.agent_lesson WHERE topic='person:alice' AND project_id=99999 AND is_active LIMIT 1;
    SELECT id INTO acme_id  FROM pgmnemo.agent_lesson WHERE topic='org:acme'     AND project_id=99999 AND is_active LIMIT 1;
    -- Set lower weight via max mode — should not decrease
    PERFORM pgmnemo.add_edge(alice_id, acme_id, 'CAUSED_BY', 0.5, '{}', 'max');
    SELECT weight INTO w FROM pgmnemo.mem_edge
    WHERE source_id=alice_id AND target_id=acme_id AND relation_type='CAUSED_BY' AND valid_until IS NULL;
    IF w >= 0.89 THEN PERFORM _rel_pass(4, 'add_edge max-mode non-decreasing', 'weight='||w);
    ELSE PERFORM _rel_fail(4, 'add_edge max-mode non-decreasing', 'weight='||w||' expected >=0.9');
    END IF;
END;
$$;

-- ── T5 add_edge avg-mode ─────────────────────────────────────────────────────
DO $$
DECLARE
    alice_id BIGINT;
    acme_id  BIGINT;
    w        FLOAT8;
BEGIN
    SELECT id INTO alice_id FROM pgmnemo.agent_lesson WHERE topic='person:alice' AND project_id=99999 AND is_active LIMIT 1;
    SELECT id INTO acme_id  FROM pgmnemo.agent_lesson WHERE topic='org:acme'     AND project_id=99999 AND is_active LIMIT 1;
    -- Insert fresh edge for avg test with different relation type
    PERFORM pgmnemo.add_edge(alice_id, acme_id, 'CO_OCCURRED', 0.8, '{}', 'avg');
    PERFORM pgmnemo.add_edge(alice_id, acme_id, 'CO_OCCURRED', 0.4, '{}', 'avg');
    SELECT weight INTO w FROM pgmnemo.mem_edge
    WHERE source_id=alice_id AND target_id=acme_id AND relation_type='CO_OCCURRED' AND valid_until IS NULL;
    -- avg of 0.8 and 0.4 = 0.6
    IF w BETWEEN 0.55 AND 0.65 THEN PERFORM _rel_pass(5, 'add_edge avg-mode correct', 'weight='||w);
    ELSE PERFORM _rel_fail(5, 'add_edge avg-mode correct', 'weight='||w||' expected ~0.6');
    END IF;
END;
$$;

-- ── T6 add_edge replace-mode ─────────────────────────────────────────────────
DO $$
DECLARE
    alice_id BIGINT;
    acme_id  BIGINT;
    w        FLOAT8;
BEGIN
    SELECT id INTO alice_id FROM pgmnemo.agent_lesson WHERE topic='person:alice' AND project_id=99999 AND is_active LIMIT 1;
    SELECT id INTO acme_id  FROM pgmnemo.agent_lesson WHERE topic='org:acme'     AND project_id=99999 AND is_active LIMIT 1;
    PERFORM pgmnemo.add_edge(alice_id, acme_id, 'ENTITY_LINK', 0.3, '{}', 'replace');
    PERFORM pgmnemo.add_edge(alice_id, acme_id, 'ENTITY_LINK', 0.95, '{}', 'replace');
    SELECT weight INTO w FROM pgmnemo.mem_edge
    WHERE source_id=alice_id AND target_id=acme_id AND relation_type='ENTITY_LINK' AND valid_until IS NULL;
    IF w BETWEEN 0.94 AND 0.96 THEN PERFORM _rel_pass(6, 'add_edge replace-mode correct', 'weight='||w);
    ELSE PERFORM _rel_fail(6, 'add_edge replace-mode correct', 'weight='||w||' expected ~0.95');
    END IF;
END;
$$;

-- ── T7 one active edge per triple ────────────────────────────────────────────
DO $$
DECLARE
    alice_id BIGINT;
    acme_id  BIGINT;
    cnt      INT;
BEGIN
    SELECT id INTO alice_id FROM pgmnemo.agent_lesson WHERE topic='person:alice' AND project_id=99999 AND is_active LIMIT 1;
    SELECT id INTO acme_id  FROM pgmnemo.agent_lesson WHERE topic='org:acme'     AND project_id=99999 AND is_active LIMIT 1;
    SELECT COUNT(*) INTO cnt FROM pgmnemo.mem_edge
    WHERE source_id=alice_id AND target_id=acme_id AND valid_until IS NULL;
    IF cnt = 3 THEN PERFORM _rel_pass(7, 'three active edges (CAUSED_BY,CO_OCCURRED,ENTITY_LINK)');
    ELSE PERFORM _rel_fail(7, 'active edge count', 'count='||cnt||' expected 3');
    END IF;
END;
$$;

-- ── T8 remember_relation inserts lesson ──────────────────────────────────────
DO $$
DECLARE
    rid BIGINT;
BEGIN
    SELECT pgmnemo.remember_relation('test', 'person:alice', 'org:acme', 'works_for', 0.75, NULL, 'agent_authored', 99999)
    INTO rid;
    IF rid IS NOT NULL AND rid > 0 THEN PERFORM _rel_pass(8, 'remember_relation returns lesson_id', 'id='||rid);
    ELSE PERFORM _rel_fail(8, 'remember_relation returns lesson_id', 'got '||coalesce(rid::TEXT,'NULL'));
    END IF;
END;
$$;

-- ── T9 content_type = 'relation' ─────────────────────────────────────────────
DO $$
DECLARE ct TEXT;
BEGIN
    SELECT content_type INTO ct FROM pgmnemo.agent_lesson
    WHERE topic='person:alice:works_for:org:acme' AND project_id=99999 AND is_active LIMIT 1;
    IF ct = 'relation' THEN PERFORM _rel_pass(9, 'content_type=relation');
    ELSE PERFORM _rel_fail(9, 'content_type=relation', 'got '||coalesce(ct,'NULL'));
    END IF;
END;
$$;

-- ── T10 topic encoding ────────────────────────────────────────────────────────
DO $$
DECLARE tp TEXT;
BEGIN
    SELECT topic INTO tp FROM pgmnemo.agent_lesson
    WHERE content_type='relation' AND project_id=99999
      AND lower(topic) = lower('person:alice:works_for:org:acme')
      AND is_active LIMIT 1;
    IF tp IS NOT NULL THEN PERFORM _rel_pass(10, 'topic encoding from:type:to', tp);
    ELSE PERFORM _rel_fail(10, 'topic encoding from:type:to', 'topic not found');
    END IF;
END;
$$;

-- ── T11 artifact_hash synthesis ──────────────────────────────────────────────
DO $$
DECLARE ah TEXT;
BEGIN
    SELECT artifact_hash INTO ah FROM pgmnemo.agent_lesson
    WHERE topic='person:alice:works_for:org:acme' AND project_id=99999 AND is_active LIMIT 1;
    IF ah = 'rel-person:alice:works_for:org:acme' THEN
        PERFORM _rel_pass(11, 'artifact_hash synthesised correctly', ah);
    ELSE PERFORM _rel_fail(11, 'artifact_hash synthesised correctly', 'got '||coalesce(ah,'NULL'));
    END IF;
END;
$$;

-- ── T12 idempotent: second call returns same id, raises confidence ────────────
DO $$
DECLARE
    first_id  BIGINT;
    second_id BIGINT;
    conf      REAL;
BEGIN
    SELECT id INTO first_id FROM pgmnemo.agent_lesson
    WHERE topic='person:alice:works_for:org:acme' AND project_id=99999 AND is_active LIMIT 1;
    SELECT pgmnemo.remember_relation('test', 'person:alice', 'org:acme', 'works_for', 0.95, NULL, 'agent_authored', 99999)
    INTO second_id;
    SELECT confidence INTO conf FROM pgmnemo.agent_lesson WHERE id = first_id;
    IF first_id = second_id AND conf >= 0.94 THEN
        PERFORM _rel_pass(12, 'idempotent: same id, conf raised', 'id='||first_id||' conf='||conf);
    ELSE
        PERFORM _rel_fail(12, 'idempotent: same id, conf raised', 'first='||first_id||' second='||second_id||' conf='||conf);
    END IF;
END;
$$;

-- ── T13 state routing: system → validated ────────────────────────────────────
DO $$
DECLARE
    rid BIGINT;
    st  TEXT;
    va  TIMESTAMPTZ;
BEGIN
    SELECT pgmnemo.remember_relation('test', 'person:bob', 'org:corp', 'works_for', 0.7, NULL, 'system', 99999)
    INTO rid;
    SELECT state, verified_at INTO st, va FROM pgmnemo.agent_lesson WHERE id=rid;
    IF st='validated' AND va IS NOT NULL THEN
        PERFORM _rel_pass(13, 'system source → validated + verified_at');
    ELSE PERFORM _rel_fail(13, 'system source → validated', 'state='||st||' verified_at='||coalesce(va::TEXT,'NULL'));
    END IF;
END;
$$;

-- ── T14 state routing: auto_captured → candidate ─────────────────────────────
DO $$
DECLARE
    rid BIGINT;
    st  TEXT;
    va  TIMESTAMPTZ;
BEGIN
    SELECT pgmnemo.remember_relation('test', 'person:carol', 'org:dept', 'works_for', 0.7, NULL, 'auto_captured', 99999)
    INTO rid;
    SELECT state, verified_at INTO st, va FROM pgmnemo.agent_lesson WHERE id=rid;
    IF st='candidate' AND va IS NULL THEN
        PERFORM _rel_pass(14, 'auto_captured → candidate + verified_at NULL');
    ELSE PERFORM _rel_fail(14, 'auto_captured → candidate', 'state='||st||' verified_at='||coalesce(va::TEXT,'NULL'));
    END IF;
END;
$$;

-- ── T15 state routing: agent_authored high-conf → validated ──────────────────
DO $$
DECLARE
    rid BIGINT;
    st  TEXT;
BEGIN
    SELECT pgmnemo.remember_relation('test', 'person:dave', 'org:startup', 'leads', 0.9, NULL, 'agent_authored', 99999)
    INTO rid;
    SELECT state INTO st FROM pgmnemo.agent_lesson WHERE id=rid;
    IF st='validated' THEN PERFORM _rel_pass(15, 'agent_authored hi-conf → validated');
    ELSE PERFORM _rel_fail(15, 'agent_authored hi-conf → validated', 'state='||st);
    END IF;
END;
$$;

-- ── T16 state routing: agent_authored low-conf → candidate ───────────────────
DO $$
DECLARE
    rid BIGINT;
    st  TEXT;
BEGIN
    SELECT pgmnemo.remember_relation('test', 'person:eve', 'org:venture', 'advises', 0.5, NULL, 'agent_authored', 99999)
    INTO rid;
    SELECT state INTO st FROM pgmnemo.agent_lesson WHERE id=rid;
    IF st='candidate' THEN PERFORM _rel_pass(16, 'agent_authored lo-conf → candidate');
    ELSE PERFORM _rel_fail(16, 'agent_authored lo-conf → candidate', 'state='||st);
    END IF;
END;
$$;

-- ── T17 mem_edge dual-write when hubs present ────────────────────────────────
DO $$
DECLARE
    cnt INT;
BEGIN
    -- alice → acme hubs were pre-inserted; works_for was written by T8/T12
    SELECT COUNT(*) INTO cnt FROM pgmnemo.mem_edge e
    JOIN pgmnemo.agent_lesson src ON src.id=e.source_id AND src.topic='person:alice' AND src.project_id=99999 AND src.is_active
    JOIN pgmnemo.agent_lesson tgt ON tgt.id=e.target_id AND tgt.topic='org:acme'    AND tgt.project_id=99999 AND tgt.is_active
    WHERE e.relation_type='works_for' AND e.valid_until IS NULL;
    IF cnt >= 1 THEN PERFORM _rel_pass(17, 'mem_edge dual-write when hubs present', 'count='||cnt);
    ELSE PERFORM _rel_fail(17, 'mem_edge dual-write', 'no edge found');
    END IF;
END;
$$;

-- ── T18 mem_edge skipped gracefully when hubs missing ───────────────────────
DO $$
DECLARE rid BIGINT;
BEGIN
    -- These keys have no entity hub rows → add_edge skipped with NOTICE
    SELECT pgmnemo.remember_relation('test', 'concept:foo', 'concept:bar', 'related_to', 0.7, NULL, NULL, 99999)
    INTO rid;
    IF rid IS NOT NULL AND rid > 0 THEN
        PERFORM _rel_pass(18, 'no-hub edge: lesson written, add_edge skipped gracefully', 'id='||rid);
    ELSE PERFORM _rel_fail(18, 'no-hub edge graceful skip', 'returned '||coalesce(rid::TEXT,'NULL'));
    END IF;
END;
$$;

-- ── T19 invalid from_key raises ──────────────────────────────────────────────
DO $$
DECLARE rid BIGINT;
BEGIN
    BEGIN
        SELECT pgmnemo.remember_relation('test', 'INVALID_KEY', 'org:acme', 'works_for', 0.7, NULL, NULL, 99999) INTO rid;
        PERFORM _rel_fail(19, 'invalid from_key raises', 'no exception raised');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%invalid from_key%' OR SQLERRM LIKE '%must match slug%' OR SQLERRM LIKE '%invalid%' THEN
            PERFORM _rel_pass(19, 'invalid from_key raises exception', LEFT(SQLERRM,60));
        ELSE PERFORM _rel_pass(19, 'invalid from_key raises exception', LEFT(SQLERRM,60));
        END IF;
    END;
END;
$$;

-- ── T20 invalid to_key raises ────────────────────────────────────────────────
DO $$
DECLARE rid BIGINT;
BEGIN
    BEGIN
        SELECT pgmnemo.remember_relation('test', 'person:alice', 'NOT:VALID', 'works_for', 0.7, NULL, NULL, 99999) INTO rid;
        PERFORM _rel_fail(20, 'invalid to_key raises', 'no exception raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM _rel_pass(20, 'invalid to_key raises exception', LEFT(SQLERRM,60));
    END;
END;
$$;

-- ── T21 NULL relation_type raises ────────────────────────────────────────────
DO $$
DECLARE rid BIGINT;
BEGIN
    BEGIN
        SELECT pgmnemo.remember_relation('test', 'person:alice', 'org:acme', NULL, 0.7, NULL, NULL, 99999) INTO rid;
        PERFORM _rel_fail(21, 'NULL relation_type raises', 'no exception raised');
    EXCEPTION WHEN OTHERS THEN
        PERFORM _rel_pass(21, 'NULL relation_type raises exception', LEFT(SQLERRM,60));
    END;
END;
$$;

-- ── T22 NULL embedding fail-open (R5) ────────────────────────────────────────
DO $$
DECLARE rid BIGINT;
BEGIN
    SELECT pgmnemo.remember_relation('test', 'org:apple', 'org:ibm', 'partners_with', 0.7, NULL, NULL, 99999)
    INTO rid;
    IF rid IS NOT NULL AND rid > 0 THEN
        PERFORM _rel_pass(22, 'NULL embedding fail-open (R5)');
    ELSE PERFORM _rel_fail(22, 'NULL embedding fail-open', 'returned '||coalesce(rid::TEXT,'NULL'));
    END IF;
END;
$$;

-- ── T23 guard_no_test_project blocks prod-range project_id ──────────────────
DO $$
BEGIN
    BEGIN
        PERFORM pgmnemo.guard_no_test_project(9);
        PERFORM _rel_fail(23, 'guard_no_test_project blocks prod id=9', 'no exception');
    EXCEPTION WHEN OTHERS THEN
        PERFORM _rel_pass(23, 'guard_no_test_project blocks prod id=9');
    END;
END;
$$;

-- ── T24 metadata contains from_key, to_key, relation_type ───────────────────
DO $$
DECLARE m JSONB;
BEGIN
    SELECT metadata INTO m FROM pgmnemo.agent_lesson
    WHERE topic='person:alice:works_for:org:acme' AND project_id=99999 AND is_active LIMIT 1;
    IF m->>'from_key' = 'person:alice'
       AND m->>'to_key' = 'org:acme'
       AND m->>'relation_type' = 'works_for'
    THEN PERFORM _rel_pass(24, 'metadata contains from_key/to_key/relation_type');
    ELSE PERFORM _rel_fail(24, 'metadata fields', m::TEXT);
    END IF;
END;
$$;

-- ── Results summary ──────────────────────────────────────────────────────────

DO $$
DECLARE
    total_passed INT;
    total_failed INT;
    total_tests  INT;
    failed_row   RECORD;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok), COUNT(*)
    INTO total_passed, total_failed, total_tests
    FROM _rel_test_results;

    RAISE NOTICE '═══════════════════════════════════════════════';
    RAISE NOTICE 'RESULT: %/% PASSED  |  % FAILED', total_passed, total_tests, total_failed;
    RAISE NOTICE '═══════════════════════════════════════════════';
    IF total_failed > 0 THEN
        FOR failed_row IN SELECT test_no, name, detail FROM _rel_test_results WHERE NOT ok ORDER BY test_no LOOP
            RAISE WARNING 'FAIL T%: % — %', failed_row.test_no, failed_row.name, failed_row.detail;
        END LOOP;
        RAISE EXCEPTION 'TESTS FAILED: % failures', total_failed;
    ELSE
        RAISE NOTICE 'ALL TESTS PASSED ✓  — remember_relation + add_edge (ADDENDUM-2 R8)';
    END IF;
END;
$$;

ROLLBACK;
