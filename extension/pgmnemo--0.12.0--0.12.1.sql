-- pgmnemo--0.12.0--0.12.1.sql
-- pgmnemo upgrade 0.12.0 -> 0.12.1
-- Vendor decoupling: configurable test-project floor (no baked numbering),
-- product cites its own spec (RFC-001) instead of an internal ADR. No behaviour
-- change beyond guard_no_test_project becoming opt-in via GUC pgmnemo.test_project_floor.
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.12.1'" to load this file. \quit

DO $$ BEGIN RAISE NOTICE 'pgmnemo: upgrading to version 0.12.1 (vendor decoupling)'; END; $$;

-- guard_no_test_project: floor is now caller-configured via GUC (was hardcoded).
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
    v_floor := COALESCE(NULLIF(current_setting('pgmnemo.test_project_floor', true), '')::int, 0);
    IF p_project_id <= v_floor THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: project_id=% is at/below the configured production floor (pgmnemo.test_project_floor=%). Use a higher test project_id.', p_project_id, v_floor;
    END IF;
    IF p_allowed_db IS NOT NULL AND current_database() <> p_allowed_db THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: must run on ''%'', current db is ''%''.', p_allowed_db, current_database();
    END IF;
END;
$$;
COMMENT ON FUNCTION pgmnemo.guard_no_test_project(INT, TEXT) IS 'Safety guard for test harnesses. Raises when p_project_id IS NULL or <= GUC pgmnemo.test_project_floor (default 0 = floor check disabled; callers opt in). RFC-001 testing guidance. v0.12.1.';

-- Decouple internal ADR reference -> product spec (RFC-001).
COMMENT ON FUNCTION pgmnemo._has_contact_pii(TEXT) IS 'PII property detector. Returns TRUE for {email,phone,address,telegram,full_name}. PROPERTY_CONVENTIONS §5.1 / RFC-001 §D4. v0.12.0.';
COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[]) IS
    'v0.11.0 — RFC-001 §D2 / P0.2: typed recall. '
    'New param p_content_types text[] DEFAULT NULL (LAST, backward-compatible). '
    'NULL → unchanged behavior (all content types). '
    'non-NULL → pushes content_type = ANY(p_content_types) into BOTH subplans (vec + BM25) '
    'BEFORE RRF fusion — uses ix_pgmnemo_content_type_active (pushdown, not post-filter). '
    'Empty array ''{}'': zero rows returned (no silent fallback to all-types). '
    'Inherits all v0.10.1 (#87) fixes: query_text cap, indexed full_text BM25, '
    'bm25_budget_ms timeout, simple tsconfig. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'graph_proximity via mem_edge causal/temporal walk (depth ≤5). '
    'VOLATILE (side-effects: recency stamp, temp table _pgmnemo_bm25_work).';
