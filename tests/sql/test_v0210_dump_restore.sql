-- test_v0210_dump_restore.sql
-- pg_regress suite: pgmnemo 0.21.0 — pg_extension_config_dump wiring
--
-- Verifies that pg_extension.extconfig is correctly populated so that pg_dump
-- includes user-data tables in backups. An empty extconfig (the 0.20.0 bug)
-- causes pg_dump to silently omit all lesson corpus data while preserving DDL.
--
-- Coverage:
--   T1  extconfig is non-empty (pg_extension_config_dump was called)
--   T2  agent_lesson table is registered (primary lesson store)
--   T3  mem_edge table is registered (graph edge store)
--   T4  memory_ingest_log table is registered (ingest batch log)
--   T5  agent_lesson_id_seq is registered (preserves id continuity after restore)
--   T6  mem_edge_id_seq is registered
--   T7  memory_ingest_log_id_seq is registered
--   T8  agent_lesson_state_transition is NOT registered (static extension data;
--       registering it would cause duplicate-key errors on restore because
--       CREATE EXTENSION re-inserts the seed rows before the dump data is applied)
--   T9  all dump conditions are empty-string (dump all rows, no filter)
--   T10 user data round-trips through INSERT/SELECT (data pg_dump would include)
--
-- Note on full dump/restore verification:
--   A complete pg_dump → pg_restore → SELECT round-trip is exercised by
--   scripts/clean_room_install_check.sh --dump-restore. This pg_regress test
--   focuses on the catalog invariant: if extconfig is correct, pg_dump will
--   include the data.
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

-- ─────────────────────────────────────────────────────────────────────────────
-- T1: extconfig must register at least 6 objects (3 tables + 3 sequences)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT array_length(extconfig, 1) >= 6 AS has_config_entries
FROM pg_extension WHERE extname = 'pgmnemo';

-- ─────────────────────────────────────────────────────────────────────────────
-- T2: agent_lesson (primary lesson store) is in extconfig
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 1 AS agent_lesson_registered
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'agent_lesson' AND c.relkind = 'r';

-- ─────────────────────────────────────────────────────────────────────────────
-- T3: mem_edge (graph edge store) is in extconfig
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 1 AS mem_edge_registered
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'mem_edge' AND c.relkind = 'r';

-- ─────────────────────────────────────────────────────────────────────────────
-- T4: memory_ingest_log (batch ingestion log) is in extconfig
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 1 AS ingest_log_registered
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'memory_ingest_log' AND c.relkind = 'r';

-- ─────────────────────────────────────────────────────────────────────────────
-- T5: agent_lesson_id_seq is in extconfig (id counter survives restore)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 1 AS lesson_seq_registered
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'agent_lesson_id_seq' AND c.relkind = 'S';

-- ─────────────────────────────────────────────────────────────────────────────
-- T6: mem_edge_id_seq is in extconfig
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 1 AS edge_seq_registered
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'mem_edge_id_seq' AND c.relkind = 'S';

-- ─────────────────────────────────────────────────────────────────────────────
-- T7: memory_ingest_log_id_seq is in extconfig
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 1 AS log_seq_registered
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'memory_ingest_log_id_seq' AND c.relkind = 'S';

-- ─────────────────────────────────────────────────────────────────────────────
-- T8: agent_lesson_state_transition must NOT be in extconfig
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 0 AS state_transition_excluded
FROM pg_extension e
JOIN pg_class c ON c.oid = ANY(e.extconfig)
WHERE e.extname = 'pgmnemo' AND c.relname = 'agent_lesson_state_transition';

-- ─────────────────────────────────────────────────────────────────────────────
-- T9: all dump conditions are empty-string (dump all rows, no predicate filter)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) = 0 AS no_filter_conditions
FROM pg_extension e,
     LATERAL UNNEST(COALESCE(e.extcondition, ARRAY[]::TEXT[])) AS cond
WHERE e.extname = 'pgmnemo' AND cond <> '';

-- ─────────────────────────────────────────────────────────────────────────────
-- T10: user data is visible (this is the data pg_dump would preserve)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, artifact_hash)
VALUES ('dump-test-v0210', 'config-dump-regression',
        'Row that must survive pg_dump/restore — confirms data is in a config-dump table',
        'sha256:feedbeef0210');

SELECT COUNT(*) = 1 AS dump_test_row_present
FROM pgmnemo.agent_lesson WHERE role = 'dump-test-v0210';

-- cleanup
DO $$
BEGIN
    DELETE FROM pgmnemo.agent_lesson WHERE role = 'dump-test-v0210';
END $$;
