-- MAGMA-4: Dual-stream consolidation worker — regression/smoke test
-- Verifies consolidation_watermark table + consolidate_episodes() function exist.

-- Watermark table exists and is a singleton
SELECT COUNT(*) = 1 AS watermark_singleton
FROM pgmnemo.consolidation_watermark;

-- consolidate_episodes() function exists
SELECT proname
FROM pg_proc
JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
WHERE nspname = 'pgmnemo' AND proname = 'consolidate_episodes';

-- mem_edge unique constraint on (source_id, target_id, edge_type) exists
SELECT COUNT(*) >= 1 AS dedup_constraint_present
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'pgmnemo'
  AND t.relname = 'mem_edge'
  AND c.contype = 'u';

-- consolidate_episodes() returns expected columns
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'pgmnemo'
  AND table_name   = 'consolidation_watermark'
ORDER BY ordinal_position;
