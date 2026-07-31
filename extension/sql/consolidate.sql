-- consolidate.sql
-- pg_regress tests for pgmnemo.consolidate() — v0.14.0 corpus self-maintenance (R2)
--
-- Coverage:
--   T1: evidence_count column present on agent_lesson
--   T2: consolidate() function present
--   T3: dry-run finds exactly 1 cluster of size 3 (near-dup deploy-gap family)
--   T4: dry-run mutates nothing (state, is_active, evidence_count unchanged)
--   T5: canonical is the lesson with highest recall_count
--   T6: apply collapses 1 cluster
--   T7: 2 non-canonical members transition to state='superseded', is_active=FALSE
--   T8: canonical.evidence_count set to 3
--   T9: 2 SUPERSEDED_BY edges exist pointing to canonical
--   T10: second apply is idempotent (0 clusters, members already excluded)
--   T11: cross-role boundary — highly-similar embeddings in different roles not collapsed
--        (P2-E: rewritten to actually exercise the role guard, not just orthogonal embeddings)
-- SPDX-License-Identifier: Apache-2.0

-- ── Upgrade to 0.14.0 ────────────────────────────────────────────────────────
ALTER EXTENSION pgmnemo UPDATE TO '0.16.1';

SET pgmnemo.gate_strict           = 'off';
SET pgmnemo.include_unverified    = 'on';
SET pgmnemo.track_recall_recency  = 'off';

-- ── T1: evidence_count column exists ─────────────────────────────────────────
SELECT count(*) = 1 AS t1_evidence_count_col_exists
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'agent_lesson'
  AND column_name  = 'evidence_count';

-- ── T2: consolidate() function exists ────────────────────────────────────────
SELECT count(*) = 1 AS t2_consolidate_fn_exists
FROM pg_proc
JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
WHERE nspname = 'pgmnemo' AND proname = 'consolidate';

-- ── Setup: seed 3 near-duplicate lessons + 1 outlier ─────────────────────────
-- All in role 'tc_consolidate', project_id 99996 (isolated from other tests).
-- Embeddings are normalised 1024-dim vectors:
--   L1 = e_1 = [1.0, 0.0, …]              (canonical, recall_count=5)
--   L2 ≈ e_1  [0.9998, 0.02, 0.0, …]      (sim with L1 ≈ 0.9998)
--   L3 ≈ e_1  [0.9999, 0.01414, 0.0, …]   (sim with L1 ≈ 0.9999)
--   L4 = e_1024 = [0.0, …, 0.0, 1.0]      (perpendicular — outlier, sim=0)
DO $$
DECLARE
    v_l1_id BIGINT;
    v_l2_id BIGINT;
    v_l3_id BIGINT;
BEGIN
    v_l1_id := pgmnemo.ingest(
        'tc_consolidate', 99996, 'deploy-gap',
        'When deploy gap occurs check uvicorn reload disable immediately',
        p_commit_sha => 'sha_tc_con_l1'
    );
    v_l2_id := pgmnemo.ingest(
        'tc_consolidate', 99996, 'deploy-gap',
        'When deploy gap occurs check uvicorn reload disable setting',
        p_commit_sha => 'sha_tc_con_l2'
    );
    v_l3_id := pgmnemo.ingest(
        'tc_consolidate', 99996, 'deploy-gap',
        'When deploy gap occurs uvicorn reload should be disabled',
        p_commit_sha => 'sha_tc_con_l3'
    );
    PERFORM pgmnemo.ingest(
        'tc_consolidate', 99996, 'api-error',
        'When API returns 500 always check the error logs first',
        p_commit_sha => 'sha_tc_con_l4'
    );

    -- Assign synthetic normalised embeddings
    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[1.0' || repeat(',0.0', 1023) || ']')::vector(1024),
        recall_count = 5,
        confidence   = 0.8
    WHERE commit_sha = 'sha_tc_con_l1';

    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.9998,0.02' || repeat(',0.0', 1022) || ']')::vector(1024),
        recall_count = 2,
        confidence   = 0.5
    WHERE commit_sha = 'sha_tc_con_l2';

    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.9999,0.01414' || repeat(',0.0', 1022) || ']')::vector(1024),
        recall_count = 1,
        confidence   = 0.5
    WHERE commit_sha = 'sha_tc_con_l3';

    -- Outlier: perpendicular to the cluster; cosine_sim = 0 with L1/L2/L3
    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.0' || repeat(',0.0', 1022) || ',1.0]')::vector(1024),
        recall_count = 0,
        confidence   = 0.5
    WHERE commit_sha = 'sha_tc_con_l4';
END;
$$;

-- ── T3: dry-run finds 1 cluster of size 3 ────────────────────────────────────
SELECT size = 3 AS t3_cluster_size_three
FROM pgmnemo.consolidate(0.92, true, 'tc_consolidate');

-- ── T4: dry-run mutates nothing ───────────────────────────────────────────────
SELECT count(*) = 0 AS t4_no_superseded_after_dryrun
FROM pgmnemo.agent_lesson
WHERE role = 'tc_consolidate' AND state = 'superseded';

SELECT count(*) = 4 AS t4_all_still_active_after_dryrun
FROM pgmnemo.agent_lesson
WHERE role = 'tc_consolidate' AND is_active;

SELECT count(*) = 0 AS t4_no_evidence_count_bump_after_dryrun
FROM pgmnemo.agent_lesson
WHERE role = 'tc_consolidate' AND evidence_count > 1;

-- ── T5: canonical has highest recall_count ───────────────────────────────────
SELECT al.recall_count = 5 AS t5_canonical_has_max_recall
FROM pgmnemo.consolidate(0.92, true, 'tc_consolidate') c
JOIN pgmnemo.agent_lesson al ON al.id = c.canonical_id;

-- ── T6: apply collapses 1 cluster ────────────────────────────────────────────
SELECT count(*) = 1 AS t6_one_cluster_applied
FROM pgmnemo.consolidate(0.92, false, 'tc_consolidate');

-- ── T7: 2 members superseded and inactive ────────────────────────────────────
SELECT count(*) = 2 AS t7_two_superseded
FROM pgmnemo.agent_lesson
WHERE role = 'tc_consolidate' AND state = 'superseded';

SELECT count(*) = 2 AS t7_two_inactive
FROM pgmnemo.agent_lesson
WHERE role = 'tc_consolidate' AND NOT is_active;

-- ── T8: canonical evidence_count = 3 ─────────────────────────────────────────
SELECT evidence_count = 3 AS t8_canonical_evidence_count_three
FROM pgmnemo.agent_lesson
WHERE role = 'tc_consolidate'
  AND is_active
  AND evidence_count > 1;

-- ── T9: 2 SUPERSEDED_BY edges point to the canonical ────────────────────────
SELECT count(*) = 2 AS t9_two_superseded_by_edges
FROM pgmnemo.mem_edge e
JOIN pgmnemo.agent_lesson tgt ON tgt.id = e.target_id
WHERE tgt.role     = 'tc_consolidate'
  AND e.relation_type = 'SUPERSEDED_BY'
  AND e.valid_until   IS NULL;

-- ── T10: second apply is idempotent (0 clusters) ─────────────────────────────
-- Superseded members are now is_active=FALSE and excluded from candidate pool.
SELECT count(*) = 0 AS t10_no_clusters_second_run
FROM pgmnemo.consolidate(0.92, false, 'tc_consolidate');

-- ── T11: cross-role boundary — highly-similar embeddings in different roles ──
-- P2-E: Rewrite — seeds L5 in 'tc_con_ra' and L6 in 'tc_con_rb' with embeddings
-- nearly identical to L1/L2 (cosine sim ≈ 0.9998 > threshold 0.92).  If the role
-- guard were absent, L5–L6 would form a cluster.  With the guard active, zero
-- clusters are returned.  This actually exercises the cross-role guard; the prior
-- design relied on orthogonal embeddings and never triggered the guard at all.
DO $$
DECLARE _l5 BIGINT; _l6 BIGINT;
BEGIN
    _l5 := pgmnemo.ingest('tc_con_ra', 99994, 'cross-role',
        'When running deploy always run alembic upgrade head first',
        p_commit_sha => 'sha_cr_l5');
    _l6 := pgmnemo.ingest('tc_con_rb', 99995, 'cross-role',
        'When running deploy always run alembic upgrade head first',
        p_commit_sha => 'sha_cr_l6');

    -- Near-identical embeddings: cosine sim ≈ 0.9998 > threshold 0.92.
    -- Would cluster if in the same role — different roles must block it.
    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[1.0' || repeat(',0.0', 1023) || ']')::vector(1024),
        recall_count = 3, confidence = 0.7
    WHERE commit_sha = 'sha_cr_l5';

    UPDATE pgmnemo.agent_lesson
    SET embedding    = ('[0.9998,0.02' || repeat(',0.0', 1022) || ']')::vector(1024),
        recall_count = 1, confidence = 0.5
    WHERE commit_sha = 'sha_cr_l6';
END;
$$;

-- No cluster formed across different roles — 0 rows returned by consolidate
SELECT count(*) = 0 AS t11_cross_role_no_cluster
FROM pgmnemo.consolidate(0.92, false, NULL);

-- Both lessons untouched — confirms the role guard is actively enforced
SELECT count(*) = 1 AS t11_role_a_still_active
FROM pgmnemo.agent_lesson
WHERE role = 'tc_con_ra' AND commit_sha = 'sha_cr_l5' AND is_active;

SELECT count(*) = 1 AS t11_role_b_still_active
FROM pgmnemo.agent_lesson
WHERE role = 'tc_con_rb' AND commit_sha = 'sha_cr_l6' AND is_active;

-- ── Cleanup ───────────────────────────────────────────────────────────────────
DELETE FROM pgmnemo.agent_lesson WHERE role IN ('tc_con_ra', 'tc_con_rb');
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_consolidate';
