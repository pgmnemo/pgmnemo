-- pgmnemo upgrade: 0.14.1 → 0.14.2
-- SPDX-License-Identifier: Apache-2.0
--
-- 0.14.2 — Curation-honesty: reclassify_corpus() must not clobber types set by
-- remember_* verbs.
--
-- ROOT CAUSE (DATA-DESTRUCTIVE, P1):
--   classify_content_type() produces only: procedure | incident | decision | fact | entity.
--   reclassify_corpus() previously touched EVERY active row, including rows whose
--   content_type was set deliberately by a typed write verb.  remember_event() writes
--   content_type='event'; the classifier does not know that type, so reclassify rewrote
--   those rows into classifier categories.  Measured on a live corpus (dry-run): event 10→0.
--
-- FIX:
--   §1  classifier_owned_types() — canonical, single source of truth for the classifier's
--       output domain.  Returns the 5 types the classifier can produce.  reclassify_corpus()
--       derives its candidate filter from this set rather than a deny-list of one value,
--       so any future type written by remember_* verbs is safe by construction.
--   §2  reclassify_corpus() — restrict candidates to rows whose content_type IS NULL or
--       IS IN classifier_owned_types().  All other rows (e.g. 'event', 'relation') are
--       left untouched in both dry-run and live mode.
--   §3  ingest() auto-classify path — already safe (COALESCE: caller value wins over
--       classifier); no change needed.  Documented here for traceability.
--
-- The upgrade script writes only the corrected functions; it does not rebuild the
-- full install.  Sibling tasks may APPEND further fixes to this file.
-- =============================================================================


-- =============================================================================
-- §1  classifier_owned_types() — derive protection set from classifier output domain
-- =============================================================================
-- Returns the exact set of content_type values that classify_content_type() can emit.
-- Rows whose current content_type is NOT in this set and NOT NULL were set by a
-- curator (remember_event, remember_relation, or a future typed verb) and must not
-- be reclassified.
--
-- IMMUTABLE: result is a compile-time constant; value changes only when the
-- classify_content_type() CASE arms change — in which case this function MUST be
-- updated in the same upgrade script.

CREATE OR REPLACE FUNCTION pgmnemo.classifier_owned_types()
RETURNS text[]
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $func$
    SELECT ARRAY['incident', 'decision', 'entity', 'fact', 'procedure']::text[]
$func$;

COMMENT ON FUNCTION pgmnemo.classifier_owned_types() IS
    'Returns the output domain of classify_content_type(): the 5 types the classifier '
    'can produce (incident, decision, entity, fact, procedure). '
    'reclassify_corpus() uses this to derive its candidate filter — rows with '
    'content_type NOT in this set and NOT NULL are curator-owned and must not be '
    'reclassified. Update this function whenever classify_content_type() gains or '
    'loses a CASE arm. v0.14.2.';


-- =============================================================================
-- §2  reclassify_corpus() — restrict candidates to classifier-owned types only
-- =============================================================================
-- Only touch rows whose CURRENT content_type IS NULL (not yet classified) or
-- IS IN pgmnemo.classifier_owned_types() (previously classified by the same
-- classifier and eligible for update).
--
-- Rows with any other content_type — 'event' written by remember_event(),
-- 'relation' written by remember_relation(), or any future curator type — are
-- excluded from candidates entirely and are therefore unchanged in both dry-run
-- and live mode.

CREATE OR REPLACE FUNCTION pgmnemo.reclassify_corpus(
    p_dry_run  boolean DEFAULT true,
    p_limit    int     DEFAULT NULL
)
RETURNS TABLE (phase text, content_type text, cnt bigint)
LANGUAGE plpgsql AS $func$
DECLARE
    _owned text[] := pgmnemo.classifier_owned_types();
BEGIN
    IF p_dry_run THEN
        -- ── DRY-RUN: compute distributions, no writes ──────────────────────
        -- candidates: only rows whose current type is NULL or classifier-owned.
        -- Curator-owned rows (e.g. 'event', 'relation') are excluded.
        RETURN QUERY
        WITH candidates AS (
            SELECT
                al.content_type                                AS old_ct,
                pgmnemo.classify_content_type(al.lesson_text) AS new_ct
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND (al.content_type IS NULL
                   OR al.content_type = ANY(_owned))
            ORDER BY al.id
            LIMIT p_limit
        ),
        -- BEFORE: current distribution of candidate rows only
        before_dist AS (
            SELECT 'before'::text AS ph, c.old_ct AS ct, COUNT(*)::bigint AS n
            FROM candidates c
            GROUP BY c.old_ct
        ),
        -- AFTER: proposed distribution if the live run were applied
        -- COALESCE: when classifier returns NULL, the existing label is kept
        after_dist AS (
            SELECT 'after'::text AS ph,
                   COALESCE(c.new_ct, c.old_ct) AS ct,
                   COUNT(*)::bigint AS n
            FROM candidates c
            GROUP BY COALESCE(c.new_ct, c.old_ct)
        )
        SELECT bd.ph, bd.ct, bd.n FROM before_dist bd
        UNION ALL
        SELECT ad.ph, ad.ct, ad.n FROM after_dist ad
        ORDER BY 1, 3 DESC;

    ELSE
        -- ── LIVE RUN: UPDATE rows with a new (different) classifier label ───
        -- Same candidate filter: skip curator-owned types.
        RETURN QUERY
        WITH to_update AS (
            SELECT al.id,
                   pgmnemo.classify_content_type(al.lesson_text) AS new_ct
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND (al.content_type IS NULL
                   OR al.content_type = ANY(_owned))
            ORDER BY al.id
            LIMIT p_limit
        ),
        changed AS (
            UPDATE pgmnemo.agent_lesson al
            SET content_type = tu.new_ct,
                updated_at   = NOW()
            FROM to_update tu
            WHERE al.id = tu.id
              AND tu.new_ct IS NOT NULL
              AND (al.content_type IS DISTINCT FROM tu.new_ct)
            RETURNING tu.new_ct AS final_ct
        )
        SELECT 'updated'::text,
               ch.final_ct,
               COUNT(*)::bigint
        FROM changed ch
        GROUP BY ch.final_ct
        ORDER BY 3 DESC;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reclassify_corpus(boolean, int) IS
    'Corpus self-maintenance: re-derive content_type for active lessons (v0.14.2). '
    'p_dry_run=true (default): returns before/after distributions without writing. '
    'p_dry_run=false: UPDATEs rows where classify_content_type() returns a non-NULL new label. '
    'CURATION-HONESTY (v0.14.2): only touches rows whose content_type IS NULL or belongs to '
    'pgmnemo.classifier_owned_types() — rows set by remember_event(), remember_relation(), '
    'or any future curator verb are excluded from candidates and are left byte-identical. '
    'Protection is derived from the classifier output domain, not a hardcoded deny-list.';


-- =============================================================================
-- §3  ingest() auto-classify — verification note (no code change required)
-- =============================================================================
-- ingest() resolves effective content_type as:
--   _effective_content_type := COALESCE(p_content_type, classify_content_type(p_lesson_text))
-- This means:
--   • When caller passes p_content_type (e.g. remember_event passes 'event'), it wins.
--   • When p_content_type IS NULL, the classifier result fills in.
-- The COALESCE order guarantees a caller-supplied type is NEVER overridden.
-- Verified against 0.14.1 source — no change needed for this fix.
