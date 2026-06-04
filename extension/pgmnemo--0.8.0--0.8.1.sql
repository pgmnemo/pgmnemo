-- pgmnemo--0.8.0--0.8.1.sql
-- Incremental upgrade: pgmnemo 0.8.0 → 0.8.1
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Documentation sprint — docs + one function-body refresh (no schema change).
--
-- v0.8.1 resolves the following adoption issues:
--   #18 — GUC access pattern (SHOW vs current_setting): documented in
--          docs/INSTALL.md §"Reading the GUCs" and docs/USAGE.md §"GUC reference"
--   #19 — Docker production install without compiler: documented in
--          docs/INSTALL.md Path 3 (Dockerfile COPY, no build tools needed)
--   #20 — pgmnemo.stats() diagnostic SP: already shipped in v0.4.1; 19-col version
--          (including confidence distribution) shipped in v0.7.0; documented in
--          docs/USAGE.md §"Health check — pgmnemo.stats()"
--   #24 — Orphan recovery: documented in docs/MIGRATION.md §B.5; cross-referenced
--          from docs/USAGE.md and orphan_count surface in pgmnemo.stats()
--   AGENTS.md — new top-level agent integration guide (all functions, working SQL)
--   README.md / POSITIONING.md / WHY_PGMNEMO.md / ROADMAP.md — positioning reframe
--
-- No schema/data changes. Only one CREATE OR REPLACE (function body) below:
-- the provenance-gate error message now names BOTH relaxation modes ('warn' and
-- 'off') and recommends supplying provenance instead of disabling the gate.
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.8.1';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.8.1'" to load this file. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- Provenance gate: clearer rejection message (issue: users asked how to disable).
-- Body-only change; signature, trigger binding, and behaviour are unchanged.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo._enforce_provenance_gate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    _gate TEXT;
BEGIN
    IF NEW.commit_sha IS NOT NULL OR NEW.artifact_hash IS NOT NULL THEN
        RETURN NEW;
    END IF;

    BEGIN
        _gate := lower(trim(coalesce(current_setting('pgmnemo.gate_strict', TRUE), '')));
        IF _gate = '' THEN
            _gate := 'enforce';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        _gate := 'enforce';
    END;

    CASE _gate
        WHEN 'enforce' THEN
            RAISE EXCEPTION
                'pgmnemo provenance gate [enforce]: INSERT rejected — '
                'commit_sha or artifact_hash is required. '
                'Recommended: supply a provenance field (the write then succeeds in any '
                'mode and keeps provenance). To relax the gate instead: '
                'SET pgmnemo.gate_strict = ''warn'' (accept with an audit warning) '
                'or ''off'' (skip the check entirely). '
                'See docs/SQL_REFERENCE.md "Disabling the provenance gate".';
        WHEN 'warn' THEN
            RAISE WARNING
                'pgmnemo provenance gate [warn]: INSERT accepted without commit_sha or artifact_hash. '
                'Row will be a ghost lesson (verified_at IS NULL) and excluded from recall by default.';
            RETURN NEW;
        ELSE
            RETURN NEW;
    END CASE;
END;
$$;
