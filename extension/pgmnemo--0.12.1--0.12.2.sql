-- pgmnemo--0.12.1--0.12.2.sql
-- pgmnemo upgrade 0.12.1 → 0.12.2
-- Fix: add_edge() fails with "there is no unique or exclusion constraint matching
-- the ON CONFLICT specification" when uq_mem_edge_active partial index is absent.
--
-- Root cause: add_edge() uses ON CONFLICT (source_id, target_id, relation_type)
-- WHERE valid_until IS NULL, which requires uq_mem_edge_active to exist.
-- In some upgrade paths (pg_dump restore, direct SQL installs, or environments
-- where the index was dropped manually) the index was missing.
--
-- Fix: defensively re-assert the partial index (IF NOT EXISTS) so the ON CONFLICT
-- target is guaranteed to be present before any add_edge() call.
--
-- Additional: PGMNEMO-0122-2
-- §0  Dedup active mem_edge rows before creating the unique index (production
--     environments may have duplicate active edges that would prevent index creation).
-- §3  Drop any 0-arg guard_no_test_project() overload; re-assert GUC-based variant.
--     The v0.12.0 guard had a hardcoded project_id <= 100 check. v0.12.1 replaced
--     it with GUC pgmnemo.test_project_floor (default 0 = disabled). This migration
--     formally drops any 0-arg overload and re-asserts the GUC-based 2-arg variant.
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.12.2'" to load this file. \quit

DO $$ BEGIN RAISE NOTICE 'pgmnemo: upgrading to version 0.12.2 (fix add_edge ON CONFLICT + dedup active edges + GUC guard)'; END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §0  Dedup active mem_edge rows
--
-- Production environments may have accumulated duplicate active edges
-- (same source_id, target_id, relation_type with valid_until IS NULL).
-- The uq_mem_edge_active partial unique index requires uniqueness on this
-- triple; CREATE UNIQUE INDEX fails if duplicates exist.
-- Strategy: keep the highest-id (most recently inserted) active row for each
-- duplicate group; close earlier duplicates by setting valid_until = NOW().
-- This is a no-op on clean databases (no duplicates → no rows updated).
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    _closed INT;
BEGIN
    WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                   PARTITION BY source_id, target_id, relation_type
                   ORDER BY id DESC
               ) AS rn
        FROM pgmnemo.mem_edge
        WHERE valid_until IS NULL
    )
    UPDATE pgmnemo.mem_edge
    SET valid_until = NOW()
    WHERE id IN (SELECT id FROM ranked WHERE rn > 1);
    GET DIAGNOSTICS _closed = ROW_COUNT;
    IF _closed > 0 THEN
        RAISE NOTICE
            'pgmnemo 0.12.2: closed % duplicate active edge(s) before creating uq_mem_edge_active. '
            'See docs/MIGRATION.md §0.12.1→0.12.2 for the dedup pattern.',
            _closed;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  Defensive re-assert of uq_mem_edge_active
--
-- add_edge() relies on this partial unique index for its ON CONFLICT clause:
--   ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
-- The index was introduced in v0.5.0 and re-asserted in v0.12.0 ADDENDUM-2.
-- This migration adds a third re-assertion to repair databases where the index
-- was absent (dropped, partial restore, non-standard install).
-- Dedup (§0) runs first so duplicate active edges do not block index creation.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS uq_mem_edge_active
    ON pgmnemo.mem_edge (source_id, target_id, relation_type)
    WHERE valid_until IS NULL;

COMMENT ON INDEX pgmnemo.uq_mem_edge_active IS
    'Partial unique index on active edges (valid_until IS NULL). '
    'Enables ON CONFLICT upsert in add_edge(). '
    'Created in v0.5.0; re-asserted in v0.12.0 (ADDENDUM-2 R8) and v0.12.2 (bug fix).';

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  CREATE OR REPLACE pgmnemo.add_edge()
--
-- The function body is unchanged; this CREATE OR REPLACE re-stamps the function
-- as part of v0.12.2 so pg_catalog.pg_proc reflects the correct version and the
-- COMMENT is updated. The ON CONFLICT target correctly matches uq_mem_edge_active:
--   (source_id, target_id, relation_type) WHERE valid_until IS NULL
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}'::jsonb,
    p_mode          TEXT    DEFAULT 'replace'
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _edge_kind pgmnemo.edge_kind;
    _weight    REAL := GREATEST(0.0, LEAST(1.0, COALESCE(p_weight, 1.0)));
BEGIN
    _edge_kind := CASE
        WHEN p_relation_type IN ('CAUSED_BY', 'DERIVED_FROM', 'CONTRADICTS')
            THEN 'causal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('CO_OCCURRED', 'PRECEDED_BY')
            THEN 'temporal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('ENTITY_LINK', 'SHARED_TAG', 'IS_A', 'PART_OF')
            THEN 'entity'::pgmnemo.edge_kind
        ELSE 'semantic'::pgmnemo.edge_kind
    END;

    IF p_mode NOT IN ('replace', 'max', 'avg') THEN
        RAISE EXCEPTION
            'pgmnemo.add_edge: unknown mode ''%'' — valid values: replace, max, avg',
            p_mode;
    END IF;

    IF p_mode = 'max' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind,
             _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = GREATEST(pgmnemo.mem_edge.weight, EXCLUDED.weight),
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();

    ELSIF p_mode = 'avg' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind,
             _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = (pgmnemo.mem_edge.weight + EXCLUDED.weight) / 2.0,
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();

    ELSE
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind,
             _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = EXCLUDED.weight,
            metadata   = EXCLUDED.metadata,
            updated_at = now();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.add_edge(BIGINT, BIGINT, TEXT, FLOAT8, JSONB, TEXT) IS
    'Idempotent edge upsert helper (R6, v0.5.0). '
    'Inserts or updates a directed typed edge in pgmnemo.mem_edge. '
    'edge_kind auto-derived from p_relation_type (SQL_REFERENCE §1.1). '
    'Conflict on uq_mem_edge_active (source_id, target_id, relation_type WHERE valid_until IS NULL). '
    'p_mode: ''replace'' (last-writer-wins) | ''max'' (monotonic weight) | ''avg'' (running mean). '
    'p_weight clamped to [0.0, 1.0]. '
    'NULL source_id/target_id → NOT NULL violation; unknown id → FK violation. '
    'R6 (v0.5.0); index re-asserted v0.12.2 (PGMNEMO-0122-1 bug fix).';

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  Guard: drop any 0-arg overload; re-assert GUC-based guard_no_test_project
--
-- The v0.12.0 guard had a hardcoded project_id <= 100 check (the guard did not
-- accept the floor as a configurable argument — hence "0-arg" in the sense that
-- zero meaningful parameters control the threshold).
--
-- v0.12.1 replaced it with a GUC-configurable variant:
--   SET pgmnemo.test_project_floor = <N>;   -- e.g. 100 or 500
--   PERFORM pgmnemo.guard_no_test_project(p_project_id);
--   -- blocks if p_project_id <= floor; default floor=0 = disabled (no blocking)
--
-- This migration:
--   a) Drops any 0-arg guard_no_test_project() overload that may have been
--      created by a prior manual patch (DROP IF EXISTS is a no-op if absent).
--   b) Re-asserts the canonical 2-arg GUC-based variant so it is always correct
--      regardless of the upgrade path taken.
-- ─────────────────────────────────────────────────────────────────────────────

-- (a) Remove any 0-arg overload (defensive; no-op if the function does not exist)
DROP FUNCTION IF EXISTS pgmnemo.guard_no_test_project();

-- (b) Re-assert GUC-based 2-arg variant
CREATE OR REPLACE FUNCTION pgmnemo.guard_no_test_project(
    p_project_id INT,
    p_allowed_db TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_floor INT;
BEGIN
    IF p_project_id IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: p_project_id IS NULL — tests must use an explicit test project_id';
    END IF;
    -- Floor is caller-configured; default 0 = disabled (no project-id scheme imposed).
    -- SET pgmnemo.test_project_floor = <N> to block writes to ids <= N.
    v_floor := COALESCE(NULLIF(current_setting('pgmnemo.test_project_floor', true), '')::int, 0);
    IF p_project_id <= v_floor THEN
        RAISE EXCEPTION
            'pgmnemo.guard_no_test_project: project_id=% is at/below the configured '
            'production floor (pgmnemo.test_project_floor=%). Use a higher test project_id.',
            p_project_id, v_floor;
    END IF;
    IF p_allowed_db IS NOT NULL AND current_database() <> p_allowed_db THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: must run on ''%'', current db is ''%''.',
            p_allowed_db, current_database();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.guard_no_test_project(INT, TEXT) IS
    'Safety guard for test harnesses (RFC-001 §D testing guidance). '
    'Raises EXCEPTION when p_project_id IS NULL, or <= GUC pgmnemo.test_project_floor '
    '(default 0 = floor check disabled; callers opt in). '
    'The floor is caller-configured — the product imposes no project-id numbering scheme. '
    'v0.12.1 (GUC-based); re-asserted v0.12.2 (PGMNEMO-0122-2).';
