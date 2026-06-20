-- provenance_gate.sql
-- pg_regress regression tests for pgmnemo v0.10.0 — provenance_gate moat
--
-- Coverage:
--   T1: gate_strict=off  — INSERT without provenance succeeds; row is ghost
--   T2: gate_strict=warn — INSERT without provenance emits WARNING; row is ghost
--   T3: gate_strict=enforce — INSERT without provenance → exception (caught in DO)
--   T4: gate_strict=enforce — INSERT with commit_sha bypasses gate
--   T5: gate_strict=enforce — INSERT with artifact_hash only bypasses gate (OR semantics)
--   T6: ingest() with commit_sha → verified_at stamped (IS NOT NULL)
--   T7: ingest() without provenance (gate=off) → ghost (verified_at IS NULL)
--   T8: blank GUC defaults to enforce — INSERT without provenance → exception (caught)
--
-- Prerequisites: pgmnemo installed; enforce_provenance_gate trigger active on agent_lesson.
-- Run via: make installcheck

SET client_min_messages = 'warning';
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

-- =============================================================================
-- T1: gate_strict=off — INSERT without provenance succeeds; row is ghost
-- =============================================================================
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
VALUES ('tc_pggate', 'gate_off_ghost', 'T1: ghost lesson inserted with gate_strict=off.');

SELECT verified_at IS NULL AS t1_ghost
FROM pgmnemo.agent_lesson
WHERE role = 'tc_pggate' AND topic = 'gate_off_ghost'
ORDER BY id DESC LIMIT 1;

-- Expect: t (no provenance → verified_at IS NULL)

-- =============================================================================
-- T2: gate_strict=warn — INSERT without provenance emits WARNING; row is ghost
-- =============================================================================
SET pgmnemo.gate_strict = 'warn';
SET client_min_messages = 'warning';

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
VALUES ('tc_pggate', 'gate_warn_ghost', 'T2: ghost lesson inserted with gate_strict=warn.');

SELECT verified_at IS NULL AS t2_ghost
FROM pgmnemo.agent_lesson
WHERE role = 'tc_pggate' AND topic = 'gate_warn_ghost'
ORDER BY id DESC LIMIT 1;

-- Expect: WARNING line above + t (row inserted as ghost)

-- =============================================================================
-- T3: gate_strict=enforce — INSERT without provenance → exception caught in DO
-- Exception message contains 'pgmnemo provenance gate'.
-- RAISE NOTICE confirms gate fired; no row inserted (exception aborted subtransaction).
-- =============================================================================
SET pgmnemo.gate_strict = 'enforce';
SET client_min_messages = 'notice';

DO $$
BEGIN
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_pggate', 'gate_enforce_blocked', 'T3: should be blocked by enforce gate.');
    RAISE EXCEPTION 'T3 SENTINEL: gate failed to block INSERT without provenance';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%pgmnemo provenance gate%' THEN
        RAISE NOTICE 'T3: gate blocked INSERT as expected';
    ELSE
        RAISE EXCEPTION 'T3: unexpected error: %', SQLERRM;
    END IF;
END;
$$;

SELECT COUNT(*) = 0 AS t3_blocked
FROM pgmnemo.agent_lesson
WHERE role = 'tc_pggate' AND topic = 'gate_enforce_blocked';

-- Expect: NOTICE + t (gate fired, row not persisted)

-- =============================================================================
-- T4: gate_strict=enforce — INSERT with commit_sha bypasses gate
-- =============================================================================
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha)
VALUES ('tc_pggate', 'gate_enforce_sha', 'T4: commit_sha satisfies gate in enforce mode.', 'sha-t4-abc');

SELECT EXISTS (
    SELECT 1 FROM pgmnemo.agent_lesson
    WHERE role = 'tc_pggate' AND topic = 'gate_enforce_sha'
) AS t4_sha_bypasses_gate;

-- Expect: t (INSERT succeeded; commit_sha provided → gate permits)

-- =============================================================================
-- T5: gate_strict=enforce — INSERT with artifact_hash only bypasses gate
-- Gate uses OR semantics: commit_sha IS NOT NULL OR artifact_hash IS NOT NULL
-- =============================================================================
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, artifact_hash)
VALUES ('tc_pggate', 'gate_enforce_hash', 'T5: artifact_hash satisfies gate in enforce mode.', 'sha256:t5deadbeef');

SELECT EXISTS (
    SELECT 1 FROM pgmnemo.agent_lesson
    WHERE role = 'tc_pggate' AND topic = 'gate_enforce_hash'
) AS t5_hash_bypasses_gate;

-- Expect: t (INSERT succeeded; artifact_hash alone is sufficient)

-- =============================================================================
-- T6: ingest() with commit_sha → verified_at IS NOT NULL (public API auto-stamps)
-- ingest() sets verified_at = NOW() when commit_sha IS NOT NULL.
-- =============================================================================
SELECT pgmnemo.ingest(
    'tc_pggate', NULL, 'gate_ingest_sha',
    'T6: ingest with commit_sha stamps verified_at.',
    3, NULL, 'sha-t6-abc', NULL, '{}'::jsonb
) IS NOT NULL AS t6_ingest_id;

SELECT verified_at IS NOT NULL AS t6_verified
FROM pgmnemo.agent_lesson
WHERE role = 'tc_pggate' AND topic = 'gate_ingest_sha'
ORDER BY id DESC LIMIT 1;

-- Expect: t + t (ID returned, verified_at stamped)

-- =============================================================================
-- T7: ingest() without provenance (gate=off) → verified_at IS NULL (ghost)
-- =============================================================================
SET pgmnemo.gate_strict = 'off';

SELECT pgmnemo.ingest(
    'tc_pggate', NULL, 'gate_ingest_ghost',
    'T7: ingest without provenance yields ghost lesson.',
    3, NULL, NULL, NULL, '{}'::jsonb
) IS NOT NULL AS t7_ingest_id;

SELECT verified_at IS NULL AS t7_ghost
FROM pgmnemo.agent_lesson
WHERE role = 'tc_pggate' AND topic = 'gate_ingest_ghost'
ORDER BY id DESC LIMIT 1;

-- Expect: t + t (ID returned, verified_at IS NULL → ghost)

-- =============================================================================
-- T8: blank GUC defaults to enforce — INSERT without provenance → exception
-- Setting gate_strict='' triggers the default-enforce branch in _enforce_provenance_gate().
-- Function: coalesce('', '') → '' → trim → '' → _gate = 'enforce'.
-- =============================================================================
SET pgmnemo.gate_strict = '';
SET client_min_messages = 'notice';

DO $$
BEGIN
    INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text)
    VALUES ('tc_pggate', 'gate_default_blocked', 'T8: should be blocked by default enforce gate.');
    RAISE EXCEPTION 'T8 SENTINEL: default gate failed to block INSERT without provenance';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%pgmnemo provenance gate%' THEN
        RAISE NOTICE 'T8: default gate blocked INSERT as expected';
    ELSE
        RAISE EXCEPTION 'T8: unexpected error: %', SQLERRM;
    END IF;
END;
$$;

SELECT COUNT(*) = 0 AS t8_default_blocked
FROM pgmnemo.agent_lesson
WHERE role = 'tc_pggate' AND topic = 'gate_default_blocked';

-- Expect: NOTICE + t (blank GUC → enforce → gate fired)

-- =============================================================================
-- Cleanup
-- =============================================================================
SET pgmnemo.gate_strict = 'off';
DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_pggate';

-- Restore defaults
SET pgmnemo.gate_strict = 'enforce';
SET pgmnemo.include_unverified = 'off';
