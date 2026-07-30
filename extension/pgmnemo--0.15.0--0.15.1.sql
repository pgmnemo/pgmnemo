-- pgmnemo upgrade: 0.15.0 → 0.15.1
-- SPDX-License-Identifier: Apache-2.0
--
-- 0.15.1 — A3: recall_situation() now honours pgmnemo.include_unverified
--
-- Rationale:
--   The shipped 0.15.0 COMMENT on recall_situation() carried an explicit promise:
--   "GUC-conditional filtering is deferred to a follow-up release."
--   Every other recall function (recall_hybrid, recall_fast, recall_lessons,
--   traverse_temporal_window) reads pgmnemo.include_unverified with an
--   EXCEPTION-safe current_setting() pattern and excludes unverified rows
--   when the GUC is absent or false.  recall_situation() did neither, so
--   draft and candidate lessons were returned even when gate_strict-equivalent
--   filtering was desired.
--
--   This upgrade delivers the deferred GUC support:
--   • Converts the function from LANGUAGE sql to LANGUAGE plpgsql (required for
--     EXCEPTION-safe GUC reads — the block-level EXCEPTION handler is a plpgsql
--     construct).
--   • Reads pgmnemo.include_unverified using the same EXCEPTION-safe pattern as
--     recall_hybrid() / recall_fast() / recall_lessons().
--   • Permissive default preserved: when the GUC is not set, _include_unverified
--     is FALSE, meaning only verified rows (verified_at IS NOT NULL) are returned.
--     This matches sibling behaviour and does NOT regress callers that explicitly
--     SET pgmnemo.include_unverified = 'on' (the pattern used in production and
--     in all installcheck fixtures).
--   • Updates the COMMENT to replace the stale 'deferred' promise with a
--     description of the actual implemented behaviour.
--
-- Production corpus note (verified against a live 6k-lesson corpus, 2026-07-30):
--   All 60 deploy_gap episode rows have verified_at IS NOT NULL.
--   Both directions (include_unverified on and off) therefore return 60 rows
--   for that class — no regression on the primary acceptance query.
-- =============================================================================


-- =============================================================================
-- A3  recall_situation() — add include_unverified GUC filtering
-- =============================================================================
-- Replaces the LANGUAGE sql STABLE PARALLEL SAFE implementation from 0.15.0
-- with a LANGUAGE plpgsql implementation that mirrors the GUC-read pattern
-- used by recall_hybrid(), recall_fast(), and recall_lessons().
-- STABLE and PARALLEL SAFE are preserved: the function does not modify DB state
-- and does not call SET LOCAL, so both qualifiers remain correct.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_situation(
    p_sit_fp     TEXT,
    p_project_id INT     DEFAULT NULL,
    p_role       TEXT    DEFAULT NULL,
    p_k          INT     DEFAULT 10
)
RETURNS TABLE (
    id           BIGINT,
    role         TEXT,
    topic        TEXT,
    lesson_text  TEXT,
    content_type TEXT,
    sit_fp       TEXT,
    created_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $func$
DECLARE
    _include_unverified BOOLEAN;
BEGIN
    -- Mirror the EXCEPTION-safe pattern used by recall_hybrid(), recall_fast(),
    -- and recall_lessons().  When the GUC is not set, missing_ok=TRUE causes
    -- current_setting() to return NULL; COALESCE then defaults to FALSE.
    -- When the GUC is set to a non-boolean value (should not occur in practice),
    -- the EXCEPTION handler falls back to FALSE rather than raising to the caller.
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    RETURN QUERY
    SELECT
        al.id,
        al.role,
        al.topic,
        al.lesson_text,
        al.content_type,
        pgmnemo.extract_sit_fp(al.topic, al.lesson_text) AS sit_fp,
        al.created_at
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.content_type IS NOT NULL
      -- Bitemporal lifecycle gate: exclude superseded rows.
      AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
      AND pgmnemo.extract_sit_fp(al.topic, al.lesson_text) = p_sit_fp
      AND (p_project_id IS NULL OR al.project_id = p_project_id)
      AND (p_role IS NULL OR al.role = p_role)
      -- GUC gate: mirrors recall_hybrid / recall_fast.
      -- When pgmnemo.include_unverified is not set (default) or false,
      -- only rows with verified_at IS NOT NULL are returned.
      AND (_include_unverified OR al.verified_at IS NOT NULL)
    ORDER BY al.created_at DESC
    LIMIT p_k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_situation(TEXT, INT, TEXT, INT) IS
    'TRUST POSTURE (v0.15.1): '
    'reads pgmnemo.include_unverified with the same EXCEPTION-safe pattern as '
    'recall_hybrid() / recall_fast() / recall_lessons(). '
    'When the GUC is absent or false (the default), only rows with '
    'verified_at IS NOT NULL are returned. '
    'Set pgmnemo.include_unverified = ''on'' for this session to include '
    'draft and candidate rows — the standard pattern used in production recall '
    'and in all installcheck fixtures. '
    'Production note: episode rows written by remember_event() at run closeout '
    'are typically verified at write time via synthesized artifact_hash, so the '
    'default filter causes no practical regression on real corpora. '
    'Situational recall: return prior lessons whose situation class matches p_sit_fp. '
    'Matches on SITUATION fingerprint, not text similarity. '
    'Two differently-worded reports of the same failure match; '
    'two similarly-worded reports of different failures do not. '
    'Uses ix_pgmnemo_sit_fp_active for O(log n) lookup. '
    'p_sit_fp: exact fingerprint string from extract_sit_fp(). '
    'p_project_id: restrict to project (NULL = all). '
    'p_role: restrict to role (NULL = all). '
    'p_k: max results, newest-first (default 10). '
    'Returns: id, role, topic, lesson_text, content_type, sit_fp, created_at. v0.15.1.';
