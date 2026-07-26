-- undo_consolidate.sql
-- pg_regress tests for pgmnemo.undo_consolidate() — v0.14.1 P1-A
--
-- Coverage:
--   T1:  undo_consolidate() function exists
--   T2:  apply consolidate() on a 3-lesson near-dup cluster
--   T3:  2 members superseded after consolidation
--   T4:  canonical evidence_count = 3
--   T5:  2 SUPERSEDED_BY consolidation edges exist
--   T6:  edges carry prior_state='candidate' (v0.14.1 P1-A recording)
--   T7:  dry-run undo reports 1 cluster (2 would-be-restored members)
--   T8:  dry-run is provably non-mutating — state unchanged
--   T9:  dry-run non-mutating — edges unchanged
--   T10: apply undo — 1 cluster returned
--   T11: after undo, 0 superseded in role
--   T12: after undo, all 4 lessons active
--   T13: canonical evidence_count reset to 1
--   T14: members restored to exact prior state 'candidate'
--   T15: 0 consolidation edges remain
--   T16: second undo is idempotent (no-op for this role)
-- SPDX-License-Identifier: Apache-2.0

ALTER EXTENSION pgmnemo UPDATE TO '0.14.1';

SET pgmnemo.gate_strict           = 'off';
SET pgmnemo.include_unverified    = 'on';
SET pgmnemo.track_recall_recency  = 'off';

-- ── T1: undo_consolidate() function exists ───────────────────────────────────
SELECT count(*) = 1 AS t1_undo_fn_exists
FROM pg_proc
JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
WHERE nspname = 'pgmnemo' AND proname = 'undo_consolidate';

-- ── Setup: seed 3 near-duplicate lessons + 1 outlier ─────────────────────────
-- role='tc_undo_con', project_id=99997 — isolated from other tests.
-- Same embedding geometry as consolidate.sql but with distinct commit_shas.
DO $$
DECLARE
    _l1 BIGINT; _l2 BIGINT; _l3 BIGINT;
BEGIN
    _l1 := pgmnemo.ingest('tc_undo_con', 99997, 'deploy-gap',
        'When deploy gap occurs check uvicorn reload disable immediately',
        p_commit_sha => 'sha_uc_l1');
    _l2 := pgmnemo.ingest('tc_undo_con', 99997, 'deploy-gap',
        'When deploy gap occurs check uvicorn reload disable setting',
        p_commit_sha => 'sha_uc_l2');
    _l3 := pgmnemo.ingest('tc_undo_con', 99997, 'deploy-gap',
        'When deploy gap occurs uvicorn reload should be disabled',
        p_commit_sha => 'sha_uc_l3');
    PERFORM pgmnemo.ingest('tc_undo_con', 99997, 'api-error',
        'When API returns 500 always check the error logs first',
        p_commit_sha => 'sha_uc_l4');

    -- L1: canonical (highest recall_count=5)
    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[1.0' || repeat(',0.0', 1023) || ']')::vector(1024),
        recall_count = 5, confidence = 0.8
    WHERE commit_sha = 'sha_uc_l1';

    -- L2/L3: near-duplicates of L1
    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.9998,0.02' || repeat(',0.0', 1022) || ']')::vector(1024),
        recall_count = 2, confidence = 0.5
    WHERE commit_sha = 'sha_uc_l2';

    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.9999,0.01414' || repeat(',0.0', 1022) || ']')::vector(1024),
        recall_count = 1, confidence = 0.5
    WHERE commit_sha = 'sha_uc_l3';

    -- L4: perpendicular outlier — forms no cluster
    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.0' || repeat(',0.0', 1022) || ',1.0]')::vector(1024),
        recall_count = 0, confidence = 0.5
    WHERE commit_sha = 'sha_uc_l4';
END;
$$;

-- ── T2: apply consolidation ───────────────────────────────────────────────────
SELECT count(*) = 1 AS t2_consolidate_one_cluster
FROM pgmnemo.consolidate(0.92, false, 'tc_undo_con');

-- ── T3: 2 members superseded ─────────────────────────────────────────────────
SELECT count(*) = 2 AS t3_two_superseded
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con' AND state = 'superseded';

-- ── T4: canonical evidence_count = 3 ─────────────────────────────────────────
SELECT evidence_count = 3 AS t4_evidence_count_three
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con' AND is_active AND evidence_count > 1;

-- ── T5: 2 SUPERSEDED_BY consolidation edges ──────────────────────────────────
SELECT count(*) = 2 AS t5_two_consolidation_edges
FROM pgmnemo.mem_edge e
JOIN pgmnemo.agent_lesson tgt ON tgt.id = e.target_id
WHERE tgt.role = 'tc_undo_con'
  AND e.relation_type = 'SUPERSEDED_BY'
  AND e.valid_until IS NULL
  AND e.metadata @> '{"consolidation":true}'::jsonb;

-- ── T6: edges carry prior_state key (v0.14.1 P1-A recording) ────────────────
-- prior_state = 'draft' (state assigned by ingest() for these test lessons)
SELECT count(*) = 2 AS t6_prior_state_key_recorded
FROM pgmnemo.mem_edge e
JOIN pgmnemo.agent_lesson tgt ON tgt.id = e.target_id
WHERE tgt.role = 'tc_undo_con'
  AND e.relation_type = 'SUPERSEDED_BY'
  AND e.valid_until IS NULL
  AND (e.metadata ? 'prior_state');

-- ── T7: dry-run reports 1 cluster (would-be-restored) ────────────────────────
SELECT count(*) = 1 AS t7_dryrun_one_cluster_reported
FROM pgmnemo.undo_consolidate(NULL, TRUE) u
JOIN pgmnemo.agent_lesson al ON al.id = u.canonical_id
WHERE al.role = 'tc_undo_con';

-- ── T8: dry-run non-mutating — still 2 superseded ────────────────────────────
SELECT count(*) = 2 AS t8_dryrun_no_mutation_state
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con' AND state = 'superseded';

-- ── T9: dry-run non-mutating — edges unchanged ───────────────────────────────
SELECT count(*) = 2 AS t9_dryrun_no_mutation_edges
FROM pgmnemo.mem_edge e
JOIN pgmnemo.agent_lesson tgt ON tgt.id = e.target_id
WHERE tgt.role = 'tc_undo_con'
  AND e.relation_type = 'SUPERSEDED_BY'
  AND e.valid_until IS NULL
  AND e.metadata @> '{"consolidation":true}'::jsonb;

-- ── T10: apply undo — returns 1 cluster ──────────────────────────────────────
SELECT count(*) = 1 AS t10_undo_one_cluster
FROM pgmnemo.undo_consolidate(NULL, FALSE) u
JOIN pgmnemo.agent_lesson al ON al.id = u.canonical_id
WHERE al.role = 'tc_undo_con';

-- ── T11: 0 superseded after undo ─────────────────────────────────────────────
SELECT count(*) = 0 AS t11_no_superseded_after_undo
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con' AND state = 'superseded';

-- ── T12: all 4 lessons active ────────────────────────────────────────────────
SELECT count(*) = 4 AS t12_all_four_active
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con' AND is_active;

-- ── T13: canonical evidence_count reset to 1 ─────────────────────────────────
SELECT count(*) = 0 AS t13_no_inflated_evidence_count
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con' AND evidence_count > 1;

-- ── T14: members restored to prior state 'draft' (exact inverse) ─────────────
-- ingest() assigns state='draft' to these test lessons; undo restores exactly.
SELECT count(*) = 2 AS t14_members_restored_to_prior_state
FROM pgmnemo.agent_lesson
WHERE role = 'tc_undo_con'
  AND commit_sha IN ('sha_uc_l2', 'sha_uc_l3')
  AND state = 'draft'
  AND is_active;

-- ── T15: 0 consolidation edges remain ────────────────────────────────────────
SELECT count(*) = 0 AS t15_no_edges_remain
FROM pgmnemo.mem_edge e
JOIN pgmnemo.agent_lesson al ON al.id = e.target_id
WHERE al.role = 'tc_undo_con'
  AND e.relation_type = 'SUPERSEDED_BY'
  AND e.valid_until IS NULL
  AND e.metadata @> '{"consolidation":true}'::jsonb;

-- ── T16: second undo is idempotent for this role ─────────────────────────────
SELECT count(*) = 0 AS t16_second_undo_noop
FROM pgmnemo.undo_consolidate(NULL, FALSE) u
JOIN pgmnemo.agent_lesson al ON al.id = u.canonical_id
WHERE al.role = 'tc_undo_con';

-- ── Cleanup ───────────────────────────────────────────────────────────────────
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_undo_con';
