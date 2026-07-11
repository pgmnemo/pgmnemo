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
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.12.2'" to load this file. \quit

DO $$ BEGIN RAISE NOTICE 'pgmnemo: upgrading to version 0.12.2 (fix add_edge ON CONFLICT)'; END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  Defensive re-assert of uq_mem_edge_active
--
-- add_edge() relies on this partial unique index for its ON CONFLICT clause:
--   ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
-- The index was introduced in v0.5.0 and re-asserted in v0.12.0 ADDENDUM-2.
-- This migration adds a third re-assertion to repair databases where the index
-- was absent (dropped, partial restore, non-standard install).
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
