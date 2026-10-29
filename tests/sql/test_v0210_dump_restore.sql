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
--   T10 extconfig and extcondition are parallel arrays of equal length
--   T11 completeness guard: EVERY extension-owned table/sequence is registered,
--       except the one deliberately excluded (a future table forgotten here fails)
--   T12 pg_extension_config_dump() outside an extension script raises (boundary)
--   T13 real pg_dump -a: lesson / edge / ingest-log rows appear in the dump
--   T14 real pg_dump -a: all three sequence positions appear (setval)
--   T15 real pg_dump -a: seeded transition table is NOT dumped (no duplicate keys)
--   T16 boundary: empty-table dump is clean (rows removed, dump still succeeds)
--
-- Note on full dump/restore verification:
--   The complete pg_dump -> pg_restore -> compare cycle (fresh + upgrade path) is
--   scripts/dump_restore_check.sh (make dump-restore-check). T13-T16 here run the
--   dump half through the real pg_dump binary (needs pg_dump on PATH and the
--   connection env of the pg_regress run).
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

-- Point child processes (\!) at the database pg_regress is running in.
SELECT current_database() AS dbn \gset
\setenv PGDATABASE :dbn

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
-- T10: extconfig and extcondition are parallel arrays of the same length
-- ─────────────────────────────────────────────────────────────────────────────
SELECT array_length(extconfig, 1) = array_length(extcondition, 1) AS arrays_parallel
FROM pg_extension WHERE extname = 'pgmnemo';

-- ─────────────────────────────────────────────────────────────────────────────
-- T11: completeness guard — list every extension-owned table/sequence that is
-- NOT registered. Only the seeded transition table may appear.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT c.relname, c.relkind
FROM pg_depend d
JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pgmnemo'
JOIN pg_class c ON c.oid = d.objid
WHERE d.deptype = 'e' AND c.relkind IN ('r', 'p', 'S')
  AND c.oid <> ALL (e.extconfig)
ORDER BY c.relname;

-- ─────────────────────────────────────────────────────────────────────────────
-- T12: boundary — pg_extension_config_dump only works inside an extension script
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM pg_extension_config_dump('pgmnemo.agent_lesson', '');
    RAISE NOTICE 'unexpected: call succeeded';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'rejected outside extension script: %', SQLSTATE;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Seed one committed row in each registered table (pg_dump uses its own
-- connection, so the rows must be visible outside this session).
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, artifact_hash)
VALUES ('dump-test-v0210', 'config-dump-regression',
        'DUMPMARK-lesson-a: must survive pg_dump', 'sha256:feedbeef0210'),
       ('dump-test-v0210', 'config-dump-regression',
        'DUMPMARK-lesson-b: must survive pg_dump', 'sha256:feedbeef0211');

SELECT pgmnemo.add_edge(
    (SELECT min(id) FROM pgmnemo.agent_lesson WHERE role = 'dump-test-v0210'),
    (SELECT max(id) FROM pgmnemo.agent_lesson WHERE role = 'dump-test-v0210'),
    'CAUSED_BY', 0.5, '{}'::jsonb);

INSERT INTO pgmnemo.memory_ingest_log (source_origin, min_id, max_id)
VALUES ('DUMPMARK-origin', 1, 2);

SELECT (SELECT count(*) FROM pgmnemo.agent_lesson WHERE role = 'dump-test-v0210') AS lessons,
       (SELECT count(*) FROM pgmnemo.mem_edge e
         JOIN pgmnemo.agent_lesson l ON l.id = e.source_id
         WHERE l.role = 'dump-test-v0210') AS edges,
       (SELECT count(*) FROM pgmnemo.memory_ingest_log
         WHERE source_origin = 'DUMPMARK-origin') AS ingest_rows;

-- ─────────────────────────────────────────────────────────────────────────────
-- T13-T15: one real `pg_dump -a` (data only), counted by label. A failed dump
-- prints DUMP-FAILED instead of silently counting 0.
--   lesson_rows       2  both DUMPMARK lessons
--   edge_copy_blocks  1  mem_edge is emitted
--   ingest_rows       1  memory_ingest_log row
--   setvals           3  one per registered sequence (id continuity)
--   transition_copy   0  seeded table is NOT dumped (no duplicate keys on restore)
-- ─────────────────────────────────────────────────────────────────────────────
\! out=$(pg_dump -a 2>&1) || echo DUMP-FAILED; echo "lesson_rows       $(echo "$out" | grep -c 'DUMPMARK-lesson-')"; echo "edge_copy_blocks  $(echo "$out" | grep -c '^COPY pgmnemo.mem_edge ')"; echo "ingest_rows       $(echo "$out" | grep -c 'DUMPMARK-origin')"; echo "setvals           $(echo "$out" | grep -c "pg_catalog.setval('pgmnemo.\(agent_lesson_id_seq\|mem_edge_id_seq\|memory_ingest_log_id_seq\)'")"; echo "transition_copy   $(echo "$out" | grep -c '^COPY pgmnemo.agent_lesson_state_transition')"

-- ─────────────────────────────────────────────────────────────────────────────
-- T16: boundary — with the tables emptied the dump still succeeds and carries
-- no DUMPMARK rows (and the lesson table is still emitted as a COPY block)
-- ─────────────────────────────────────────────────────────────────────────────
DELETE FROM pgmnemo.mem_edge e USING pgmnemo.agent_lesson l
 WHERE l.id = e.source_id AND l.role = 'dump-test-v0210';
DELETE FROM pgmnemo.agent_lesson WHERE role = 'dump-test-v0210';
DELETE FROM pgmnemo.memory_ingest_log WHERE source_origin = 'DUMPMARK-origin';

\! out=$(pg_dump -a 2>&1) || echo DUMP-FAILED; echo "marks_after_delete $(echo "$out" | grep -c 'DUMPMARK')"; echo "lesson_copy_block  $(echo "$out" | grep -c '^COPY pgmnemo.agent_lesson ')"
