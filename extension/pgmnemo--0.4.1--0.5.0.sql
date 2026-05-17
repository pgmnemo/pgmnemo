-- pgmnemo--0.4.1--0.5.0.sql
-- Migration: v0.4.1 → v0.5.0
--
-- R10: Remove traverse_causal_chain 4-arg overload deprecated in v0.4.1.
--      The 5-arg form pgmnemo.traverse_causal_chain(BIGINT,INT,TEXT[],BOOLEAN,TEXT) is unchanged.
--
-- H-06: Temporal recency tuning
--   recency_weight recommended value updated to 0.5 (H-06 research predicted optimal, cell C6).
--   Previous default: 0.05 (v0.4.1 Agency ablation R1).
--   Basis: H06_TEMPORAL_TUNE_RESEARCH.md §5 — predicted best cell C6 (rw=0.5, td=1.0);
--          bench run pending live PG environment.
--   Note: COALESCE fallbacks in recall_lessons/recall_hybrid retain 0.05 for backward
--         compat; operators should SET pgmnemo.recency_weight = '0.5' per-session or
--         via ALTER DATABASE for temporal-query workloads.
--
--   pgmnemo.temporal_boost: new GUC (FLOAT, default 1.0, range 0.0–5.0).
--   A score multiplier applied to temporal-category queries in recall routing.
--   Default 1.0 = neutral (no boost). Set to >1.0 to up-weight temporal matches.

DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);

-- ─────────────────────────────────────────────────────────────────────────────
-- H-06: Register pgmnemo.temporal_boost custom GUC
-- ─────────────────────────────────────────────────────────────────────────────

-- Initialise the GUC to its default value so current_setting() never returns ''.
-- Operators may override per-session: SET pgmnemo.temporal_boost = '2.0';
DO $$
BEGIN
    PERFORM set_config('pgmnemo.temporal_boost', '1.0', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- Helper: return the current temporal_boost value, clamped to [0.0, 5.0].
CREATE OR REPLACE FUNCTION pgmnemo.get_temporal_boost()
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _v DOUBLE PRECISION;
BEGIN
    _v := COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    );
    RETURN GREATEST(0.0, LEAST(5.0, _v));
END;
$$;

COMMENT ON FUNCTION pgmnemo.get_temporal_boost() IS
    'Returns pgmnemo.temporal_boost GUC (default 1.0, range 0.0–5.0). '
    'Score multiplier for temporal-category recall queries. '
    'Set via: SET pgmnemo.temporal_boost = ''2.0''; '
    'H-06 optimal TBD pending bench run; research predicts rw=0.5 (C6) as best cell.';
