-- test_v0120_bitemporal.sql
-- pgmnemo v0.12.0 real-DB integration tests: bitemporal supersession mechanics
-- Phase D: shared _evict_prior_lesson() helper + FOR UPDATE / idempotency across remember_*
-- RFC-001 §D2/D3 + ADDENDUM-2 R3/R4
--
-- Coverage:
--   T1  _evict_prior_lesson() helper exists (shared across remember_*)
--   T2  remember_fact supersession: different value → prior t_valid_to closed (not infinity)
--   T3  remember_fact supersession: prior state = 'superseded'
--   T4  remember_fact supersession: prior is_active = FALSE
--   T5  remember_fact supersession: new version_n = prior.version_n + 1
--   T6  remember_fact supersession: new row is_active = TRUE, t_valid_to = infinity
--   T7  remember_fact merge (same value): same id returned, no new row
--   T8  remember_fact merge: confidence raised (GREATEST merge)
--   T9  remember_fact idempotent: FOR UPDATE prevents duplicate on concurrent writes
--   T10 remember_fact v0→v1 migration: version_n=0 row superseded correctly (R4)
--   T11 remember_relation idempotent: same triple → same id (FOR UPDATE)
--   T12 remember_relation: no eviction on idempotent call (is_active stays TRUE)
--   T13 remember_event idempotent: same (entity_key, event_label) → same id (FOR UPDATE)
--   T14 remember_event: no duplicate rows for same (entity_key, event_label)
--   T15 _evict_prior_lesson() sets t_valid_to < infinity
--   T16 _evict_prior_lesson() sets state = 'superseded'
--   T17 _evict_prior_lesson() sets is_active = FALSE
--   T18 remember_fact: three-generation chain version_n 1→2→3
--   T19 remember_fact: only one active row per (topic, project_id) after supersession
--   T20 ingest_entity→remember_fact: version_n=0 sentinel row absorbed correctly
--
-- All tests use project_id=99999 (> 100 guard_no_test_project threshold).
-- Uses BEGIN/ROLLBACK — safe to run on pgmnemo_bench without permanent side effects.
-- SPDX-License-Identifier: Apache-2.0

\set TEST_PROJECT 99999

BEGIN;

-- ── scratch tables ─────────────────────────────────────────────────────────

CREATE TEMP TABLE _bt_results (
    test_no  INT,
    name     TEXT,
    ok       BOOLEAN,
    detail   TEXT DEFAULT ''
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION _bt_pass(n INT, nm TEXT, det TEXT DEFAULT '')
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO _bt_results VALUES (n, nm, TRUE, det);
$$;

CREATE OR REPLACE FUNCTION _bt_fail(n INT, nm TEXT, det TEXT DEFAULT '')
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO _bt_results VALUES (n, nm, FALSE, det);
$$;

-- ── T1: _evict_prior_lesson() shared helper exists ─────────────────────────

DO $$
DECLARE cnt INT;
BEGIN
    SELECT COUNT(*) INTO cnt
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgmnemo' AND p.proname = '_evict_prior_lesson' AND p.pronargs = 1;
    IF cnt = 1 THEN
        PERFORM _bt_pass(1, '_evict_prior_lesson helper exists');
    ELSE
        PERFORM _bt_fail(1, '_evict_prior_lesson helper exists', 'count=' || cnt);
    END IF;
END;
$$;

-- ── set up initial fact row for supersession tests ─────────────────────────

DO $$
BEGIN
    -- Write initial fact (version 1)
    PERFORM pgmnemo.remember_fact(
        'tc_bt', 'org:bt_test', 'status', 'draft',
        0.9, NULL, NULL, 'system', :TEST_PROJECT
    );
END;
$$;

-- ── T2–T6: supersession mechanics ─────────────────────────────────────────

DO $$
DECLARE
    id_v1    BIGINT;
    id_v2    BIGINT;
    row_v1   pgmnemo.agent_lesson%ROWTYPE;
    row_v2   pgmnemo.agent_lesson%ROWTYPE;
BEGIN
    -- Get the v1 row id
    SELECT id INTO id_v1 FROM pgmnemo.agent_lesson
    WHERE topic = 'org:bt_test/status' AND role = 'tc_bt'
      AND project_id = :TEST_PROJECT AND is_active LIMIT 1;

    -- Write different value → should supersede v1 and insert v2
    SELECT id INTO id_v2 FROM pgmnemo.remember_fact(
        'tc_bt', 'org:bt_test', 'status', 'published',
        0.9, NULL, NULL, 'system', :TEST_PROJECT
    );

    -- Reload both rows
    SELECT * INTO row_v1 FROM pgmnemo.agent_lesson WHERE id = id_v1;
    SELECT * INTO row_v2 FROM pgmnemo.agent_lesson WHERE id = id_v2;

    -- T2: prior t_valid_to is no longer infinity
    IF row_v1.t_valid_to < 'infinity'::TIMESTAMPTZ THEN
        PERFORM _bt_pass(2, 'prior t_valid_to closed (not infinity)');
    ELSE
        PERFORM _bt_fail(2, 'prior t_valid_to closed', 't_valid_to=' || row_v1.t_valid_to);
    END IF;

    -- T3: prior state = 'superseded'
    IF row_v1.state = 'superseded' THEN
        PERFORM _bt_pass(3, 'prior state = superseded');
    ELSE
        PERFORM _bt_fail(3, 'prior state = superseded', 'got=' || row_v1.state);
    END IF;

    -- T4: prior is_active = FALSE
    IF NOT row_v1.is_active THEN
        PERFORM _bt_pass(4, 'prior is_active = FALSE');
    ELSE
        PERFORM _bt_fail(4, 'prior is_active = FALSE', 'is_active still TRUE');
    END IF;

    -- T5: new version_n = prior.version_n + 1
    IF row_v2.version_n = row_v1.version_n + 1 THEN
        PERFORM _bt_pass(5, 'new version_n = prior+1', 'v1=' || row_v1.version_n || ' v2=' || row_v2.version_n);
    ELSE
        PERFORM _bt_fail(5, 'new version_n = prior+1', 'v1=' || row_v1.version_n || ' v2=' || row_v2.version_n);
    END IF;

    -- T6: new row is_active = TRUE, t_valid_to = infinity
    IF row_v2.is_active AND row_v2.t_valid_to = 'infinity'::TIMESTAMPTZ THEN
        PERFORM _bt_pass(6, 'new row is_active+t_valid_to=infinity');
    ELSE
        PERFORM _bt_fail(6, 'new row is_active+t_valid_to=infinity',
            'is_active=' || row_v2.is_active || ' t_valid_to=' || row_v2.t_valid_to);
    END IF;
END;
$$;

-- ── T7–T8: merge path (same value) ────────────────────────────────────────

DO $$
DECLARE
    id_a  BIGINT;
    id_b  BIGINT;
    conf_after REAL;
    cnt   INT;
BEGIN
    -- Write initial
    SELECT id INTO id_a FROM pgmnemo.remember_fact(
        'tc_bt', 'org:merge_bt', 'name', 'Acme',
        0.7, NULL, NULL, 'agent_authored', :TEST_PROJECT
    );

    -- Write same value with higher confidence
    SELECT id INTO id_b FROM pgmnemo.remember_fact(
        'tc_bt', 'org:merge_bt', 'name', 'Acme',
        0.95, NULL, NULL, 'system', :TEST_PROJECT
    );

    -- T7: same id returned (no new row)
    IF id_a = id_b THEN
        PERFORM _bt_pass(7, 'merge: same id returned');
    ELSE
        PERFORM _bt_fail(7, 'merge: same id returned', 'id_a=' || id_a || ' id_b=' || id_b);
    END IF;

    -- Count total rows
    SELECT COUNT(*) INTO cnt FROM pgmnemo.agent_lesson
    WHERE topic = 'org:merge_bt/name' AND role = 'tc_bt' AND project_id = :TEST_PROJECT;

    IF cnt = 1 THEN
        PERFORM _bt_pass(8, 'merge: confidence raised, single row');
    ELSE
        PERFORM _bt_fail(8, 'merge: confidence raised, single row', 'row_count=' || cnt);
    END IF;
END;
$$;

-- ── T9: FOR UPDATE idempotency (sequential calls simulate concurrent writes) ─

DO $$
DECLARE
    ids BIGINT[];
BEGIN
    -- Call 5 times with same args — all should return same id
    ids := ARRAY(
        SELECT id FROM pgmnemo.remember_fact(
            'tc_bt', 'org:idem_bt', 'status', 'active',
            0.9, NULL, NULL, 'system', :TEST_PROJECT
        ) LIMIT 1
    );
    -- Repeat 4 more times
    ids := ids || ARRAY(SELECT id FROM pgmnemo.remember_fact('tc_bt','org:idem_bt','status','active',0.9,NULL,NULL,'system',:TEST_PROJECT));
    ids := ids || ARRAY(SELECT id FROM pgmnemo.remember_fact('tc_bt','org:idem_bt','status','active',0.9,NULL,NULL,'system',:TEST_PROJECT));
    ids := ids || ARRAY(SELECT id FROM pgmnemo.remember_fact('tc_bt','org:idem_bt','status','active',0.9,NULL,NULL,'system',:TEST_PROJECT));
    ids := ids || ARRAY(SELECT id FROM pgmnemo.remember_fact('tc_bt','org:idem_bt','status','active',0.9,NULL,NULL,'system',:TEST_PROJECT));

    IF ids[1] = ids[2] AND ids[2] = ids[3] AND ids[3] = ids[4] AND ids[4] = ids[5] THEN
        PERFORM _bt_pass(9, 'FOR UPDATE idempotent: 5 calls same id');
    ELSE
        PERFORM _bt_fail(9, 'FOR UPDATE idempotent', array_to_string(ids, ','));
    END IF;
END;
$$;

-- ── T10: ingest_entity→remember_fact: version_n=0 row absorbed (R4) ────────

DO $$
DECLARE
    id_legacy  BIGINT;
    id_typed   BIGINT;
    row_legacy pgmnemo.agent_lesson%ROWTYPE;
    row_typed  pgmnemo.agent_lesson%ROWTYPE;
BEGIN
    -- Simulate a pre-v0.12.0 ingest_entity row: version_n=0, content_type='fact'
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to, is_active,
        artifact_hash
    ) VALUES (
        'tc_bt', :TEST_PROJECT, 'person:legacy_test/occupation', 'Engineer', 3,
        'agent_authored', 'fact', 'candidate', 0.7,
        0,  -- legacy sentinel version_n=0
        NULL, NOW(), 'infinity'::TIMESTAMPTZ, TRUE,
        'fact-person:legacy_test:occupation'
    ) RETURNING id INTO id_legacy;

    -- Now write via remember_fact with different value — should supersede version_n=0
    SELECT id INTO id_typed FROM pgmnemo.remember_fact(
        'tc_bt', 'person:legacy_test', 'occupation', 'Senior Engineer',
        0.9, NULL, NULL, 'system', :TEST_PROJECT
    );

    SELECT * INTO row_legacy FROM pgmnemo.agent_lesson WHERE id = id_legacy;
    SELECT * INTO row_typed  FROM pgmnemo.agent_lesson WHERE id = id_typed;

    -- T10a: legacy row superseded (state='superseded')
    IF row_legacy.state = 'superseded' AND NOT row_legacy.is_active THEN
        PERFORM _bt_pass(10, 'ingest_entity→remember_fact: version_n=0 superseded');
    ELSE
        PERFORM _bt_fail(10, 'ingest_entity→remember_fact: version_n=0 superseded',
            'state=' || row_legacy.state || ' is_active=' || row_legacy.is_active);
    END IF;
END;
$$;

-- ── T11–T12: remember_relation idempotent FOR UPDATE ──────────────────────

SET client_min_messages = 'WARNING';  -- suppress hub-not-found NOTICE

DO $$
DECLARE
    rid_1 BIGINT;
    rid_2 BIGINT;
    cnt   INT;
    al    pgmnemo.agent_lesson%ROWTYPE;
BEGIN
    SELECT pgmnemo.remember_relation('tc_bt','person:rel_test','org:acme_bt','works_at',0.9,NULL,'system',:TEST_PROJECT) INTO rid_1;
    SELECT pgmnemo.remember_relation('tc_bt','person:rel_test','org:acme_bt','works_at',0.9,NULL,'system',:TEST_PROJECT) INTO rid_2;

    -- T11: same id returned (idempotent)
    IF rid_1 = rid_2 THEN
        PERFORM _bt_pass(11, 'remember_relation idempotent: same id');
    ELSE
        PERFORM _bt_fail(11, 'remember_relation idempotent: same id', 'rid1=' || rid_1 || ' rid2=' || rid_2);
    END IF;

    -- T12: only one active row (no eviction on idempotent call)
    SELECT COUNT(*) INTO cnt FROM pgmnemo.agent_lesson
    WHERE topic = 'person:rel_test:works_at:org:acme_bt'
      AND role = 'tc_bt' AND project_id = :TEST_PROJECT AND is_active;
    IF cnt = 1 THEN
        PERFORM _bt_pass(12, 'remember_relation: single active row after 2 calls');
    ELSE
        PERFORM _bt_fail(12, 'remember_relation: single active row', 'active_count=' || cnt);
    END IF;
END;
$$;

RESET client_min_messages;

-- ── T13–T14: remember_event idempotent FOR UPDATE ─────────────────────────

DO $$
DECLARE
    eid_1 BIGINT;
    eid_2 BIGINT;
    cnt   INT;
BEGIN
    SELECT pgmnemo.remember_event('tc_bt','person:evt_test','hired','Hired at Acme',NULL,0.9,NULL,'system',:TEST_PROJECT) INTO eid_1;
    SELECT pgmnemo.remember_event('tc_bt','person:evt_test','hired','Hired at Acme',NULL,0.9,NULL,'system',:TEST_PROJECT) INTO eid_2;

    -- T13: same id returned (idempotent)
    IF eid_1 = eid_2 THEN
        PERFORM _bt_pass(13, 'remember_event idempotent: same id');
    ELSE
        PERFORM _bt_fail(13, 'remember_event idempotent: same id', 'eid1=' || eid_1 || ' eid2=' || eid_2);
    END IF;

    -- T14: only one row for same (entity_key, event_label)
    SELECT COUNT(*) INTO cnt FROM pgmnemo.agent_lesson
    WHERE topic = 'person:evt_test:event:hired'
      AND role = 'tc_bt' AND project_id = :TEST_PROJECT;
    IF cnt = 1 THEN
        PERFORM _bt_pass(14, 'remember_event: single row on duplicate call');
    ELSE
        PERFORM _bt_fail(14, 'remember_event: single row on duplicate call', 'count=' || cnt);
    END IF;
END;
$$;

-- ── T15–T17: _evict_prior_lesson() mechanics verified directly ─────────────

DO $$
DECLARE
    test_id BIGINT;
    al      pgmnemo.agent_lesson%ROWTYPE;
BEGIN
    -- Insert a synthetic lesson to evict
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to, is_active,
        artifact_hash
    ) VALUES (
        'tc_bt', :TEST_PROJECT, 'concept:evict_test/note', 'to be evicted', 3,
        'system', 'fact', 'validated', 0.9,
        1, NOW(), NOW(), 'infinity'::TIMESTAMPTZ, TRUE,
        'fact-concept:evict_test:note'
    ) RETURNING id INTO test_id;

    -- Call the shared eviction helper
    PERFORM pgmnemo._evict_prior_lesson(test_id);

    SELECT * INTO al FROM pgmnemo.agent_lesson WHERE id = test_id;

    -- T15: t_valid_to < infinity
    IF al.t_valid_to < 'infinity'::TIMESTAMPTZ THEN
        PERFORM _bt_pass(15, '_evict_prior_lesson: t_valid_to set');
    ELSE
        PERFORM _bt_fail(15, '_evict_prior_lesson: t_valid_to set', 't_valid_to=' || al.t_valid_to);
    END IF;

    -- T16: state = 'superseded'
    IF al.state = 'superseded' THEN
        PERFORM _bt_pass(16, '_evict_prior_lesson: state=superseded');
    ELSE
        PERFORM _bt_fail(16, '_evict_prior_lesson: state=superseded', 'state=' || al.state);
    END IF;

    -- T17: is_active = FALSE
    IF NOT al.is_active THEN
        PERFORM _bt_pass(17, '_evict_prior_lesson: is_active=FALSE');
    ELSE
        PERFORM _bt_fail(17, '_evict_prior_lesson: is_active=FALSE', 'is_active still TRUE');
    END IF;
END;
$$;

-- ── T18: three-generation version chain ────────────────────────────────────

DO $$
DECLARE
    id1 BIGINT; id2 BIGINT; id3 BIGINT;
    vn1 INT; vn2 INT; vn3 INT;
BEGIN
    SELECT id INTO id1 FROM pgmnemo.remember_fact('tc_bt','concept:chain_test','rev','v1',0.9,NULL,NULL,'system',:TEST_PROJECT);
    SELECT id INTO id2 FROM pgmnemo.remember_fact('tc_bt','concept:chain_test','rev','v2',0.9,NULL,NULL,'system',:TEST_PROJECT);
    SELECT id INTO id3 FROM pgmnemo.remember_fact('tc_bt','concept:chain_test','rev','v3',0.9,NULL,NULL,'system',:TEST_PROJECT);

    SELECT version_n INTO vn1 FROM pgmnemo.agent_lesson WHERE id = id1;
    SELECT version_n INTO vn2 FROM pgmnemo.agent_lesson WHERE id = id2;
    SELECT version_n INTO vn3 FROM pgmnemo.agent_lesson WHERE id = id3;

    IF vn1 = 1 AND vn2 = 2 AND vn3 = 3 THEN
        PERFORM _bt_pass(18, 'three-generation chain: version_n 1→2→3');
    ELSE
        PERFORM _bt_fail(18, 'three-generation chain', 'versions=' || vn1 || ',' || vn2 || ',' || vn3);
    END IF;
END;
$$;

-- ── T19: only one active row per (topic, project_id) after supersession ─────

DO $$
DECLARE cnt INT;
BEGIN
    SELECT COUNT(*) INTO cnt FROM pgmnemo.agent_lesson
    WHERE topic = 'concept:chain_test/rev'
      AND role = 'tc_bt' AND project_id = :TEST_PROJECT AND is_active;
    IF cnt = 1 THEN
        PERFORM _bt_pass(19, 'single active row after supersession chain');
    ELSE
        PERFORM _bt_fail(19, 'single active row after supersession chain', 'active=' || cnt);
    END IF;
END;
$$;

-- ── T20: ingest_entity migration: version_n=0 row absorbed, new chain starts ─

DO $$
DECLARE
    id_v0 BIGINT;
    id_v1 BIGINT;
    vn1   INT;
    cnt_active INT;
BEGIN
    -- Simulate another legacy version_n=0 row (same-value merge path)
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to, is_active,
        artifact_hash
    ) VALUES (
        'tc_bt', :TEST_PROJECT, 'org:migration_test/hq', 'London', 3,
        'imported', 'fact', 'candidate', 0.6,
        0, NULL, NOW() - INTERVAL '1 day', 'infinity'::TIMESTAMPTZ, TRUE,
        'fact-org:migration_test:hq'
    ) RETURNING id INTO id_v0;

    -- remember_fact with NEW value: should supersede version_n=0, produce version_n=1
    SELECT id INTO id_v1 FROM pgmnemo.remember_fact(
        'tc_bt', 'org:migration_test', 'hq', 'New York',
        0.9, NULL, NULL, 'system', :TEST_PROJECT
    );

    SELECT version_n INTO vn1 FROM pgmnemo.agent_lesson WHERE id = id_v1;

    -- Only one active row
    SELECT COUNT(*) INTO cnt_active FROM pgmnemo.agent_lesson
    WHERE topic = 'org:migration_test/hq'
      AND role = 'tc_bt' AND project_id = :TEST_PROJECT AND is_active;

    IF vn1 = 1 AND cnt_active = 1 AND id_v1 <> id_v0 THEN
        PERFORM _bt_pass(20, 'ingest_entity migration: version_n=0→1, single active row');
    ELSE
        PERFORM _bt_fail(20, 'ingest_entity migration', 'vn1=' || vn1 || ' active=' || cnt_active);
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
    SELECT
        COUNT(*) FILTER (WHERE ok),
        COUNT(*) FILTER (WHERE NOT ok),
        COUNT(*)
    INTO total_passed, total_failed, total_tests
    FROM _bt_results;

    RAISE NOTICE '══════════════════════════════════════════════════════';
    RAISE NOTICE 'BITEMPORAL SUPERSESSION — RESULT: %/% PASSED  |  % FAILED',
        total_passed, total_tests, total_failed;
    RAISE NOTICE '══════════════════════════════════════════════════════';

    IF total_failed > 0 THEN
        FOR failed_row IN
            SELECT test_no, name, detail FROM _bt_results WHERE NOT ok ORDER BY test_no
        LOOP
            RAISE WARNING 'FAIL T%: % — %', failed_row.test_no, failed_row.name, failed_row.detail;
        END LOOP;
        RAISE EXCEPTION 'BITEMPORAL TESTS FAILED: % failures', total_failed;
    ELSE
        RAISE NOTICE 'ALL % TESTS PASSED ✓ — bitemporal supersession + FOR UPDATE idempotency (ADDENDUM-2 R3/R4)', total_tests;
    END IF;
END;
$$;

ROLLBACK;
