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


-- =============================================================================
-- P2-A  consolidate() — accumulate evidence_count across multiple runs
-- =============================================================================
-- ROOT CAUSE: evidence_count was SET (overwritten) with the cluster size on each
-- consolidate() call, so after a second run the count reflected only the most recent
-- cluster size, not the running total of near-duplicates ever collapsed.
--
-- FIX: switch from SET to += (accumulate):
--   evidence_count = evidence_count + (cluster_size - 1)
--
-- RATIONALE (preserved here for traceability):
-- After the first consolidation the collapsed members transition to state='superseded'
-- with is_active=FALSE.  The candidate query in consolidate() excludes inactive rows,
-- so a second run can NEVER re-collect already-superseded members.  Accumulation
-- therefore cannot double-count; it records the running total of all near-duplicates
-- ever collapsed into this canonical across all consolidate() passes.
--
-- Evidence_count semantics: "number of near-duplicate originals collapsed into this
-- canonical, not counting the canonical itself" — starts at 1 (standalone) and grows
-- by (cluster_size - 1) per consolidate() pass.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.consolidate(
    p_similarity REAL    DEFAULT 0.92,
    p_dry_run    BOOLEAN DEFAULT TRUE,
    p_role       TEXT    DEFAULT NULL,
    p_limit      INT     DEFAULT 100
)
RETURNS TABLE (
    canonical_id    BIGINT,
    member_ids      BIGINT[],
    size            INT,
    mean_similarity REAL
)
LANGUAGE plpgsql
AS $$
DECLARE
    _pair        RECORD;
    _cluster     RECORD;
    _root_a      BIGINT;
    _root_b      BIGINT;
    _new_root    BIGINT;
    _old_root    BIGINT;
    _mbr         BIGINT;
    _prior_state TEXT;           -- v0.14.1 P1-A: captured before superseding for undo
BEGIN
    DROP TABLE IF EXISTS _con_candidates;
    DROP TABLE IF EXISTS _con_pairs;
    DROP TABLE IF EXISTS _con_uf;
    DROP TABLE IF EXISTS _con_clusters;

    CREATE TEMP TABLE _con_candidates ON COMMIT DROP AS
    SELECT id, role, recall_count, confidence, importance, created_at, embedding
    FROM pgmnemo.agent_lesson
    WHERE is_active
      AND state NOT IN ('superseded', 'archived', 'rejected')
      AND embedding IS NOT NULL
      AND (p_role IS NULL OR role = p_role)
    ORDER BY recall_count DESC, confidence DESC, importance DESC, created_at ASC
    LIMIT p_limit * 20;

    CREATE TEMP TABLE _con_pairs ON COMMIT DROP AS
    SELECT
        a.id                                         AS id_a,
        b.id                                         AS id_b,
        (1.0 - (a.embedding <=> b.embedding))::REAL  AS sim
    FROM _con_candidates a
    JOIN _con_candidates b ON b.id > a.id
                          AND a.role = b.role
    WHERE (1.0 - (a.embedding <=> b.embedding)) >= p_similarity;

    CREATE TEMP TABLE _con_uf (id BIGINT PRIMARY KEY, root BIGINT NOT NULL)
    ON COMMIT DROP;

    INSERT INTO _con_uf (id, root)
    SELECT DISTINCT id_a, id_a FROM _con_pairs
    UNION
    SELECT DISTINCT id_b, id_b FROM _con_pairs;

    FOR _pair IN SELECT id_a, id_b FROM _con_pairs LOOP
        SELECT root INTO _root_a FROM _con_uf WHERE id = _pair.id_a;
        SELECT root INTO _root_b FROM _con_uf WHERE id = _pair.id_b;
        IF _root_a IS DISTINCT FROM _root_b THEN
            _new_root := LEAST(_root_a, _root_b);
            _old_root := GREATEST(_root_a, _root_b);
            UPDATE _con_uf SET root = _new_root WHERE root = _old_root;
        END IF;
    END LOOP;

    LOOP
        UPDATE _con_uf u
        SET root = p.root
        FROM _con_uf p
        WHERE p.id = u.root AND p.root <> u.root;
        EXIT WHEN NOT FOUND;
    END LOOP;

    CREATE TEMP TABLE _con_clusters ON COMMIT DROP AS
    WITH cluster_agg AS (
        SELECT
            u.root,
            array_agg(u.id ORDER BY
                c.recall_count DESC,
                c.confidence   DESC,
                c.importance   DESC,
                c.created_at   ASC,
                c.id           ASC
            )            AS members,
            count(*)::INT AS sz
        FROM _con_uf u
        JOIN _con_candidates c ON c.id = u.id
        GROUP BY u.root
        HAVING count(*) > 1
    ),
    cluster_sim AS (
        SELECT
            ca.root,
            ca.members,
            ca.sz,
            (SELECT avg(p.sim)::REAL
             FROM _con_pairs p
             WHERE p.id_a = ANY(ca.members)
               AND p.id_b = ANY(ca.members)
            ) AS mean_sim
        FROM cluster_agg ca
    )
    SELECT
        members[1]                       AS canonical_id,
        members                          AS all_members,
        sz,
        coalesce(mean_sim, p_similarity) AS mean_sim
    FROM cluster_sim
    ORDER BY sz DESC, members[1]
    LIMIT p_limit;

    IF NOT p_dry_run THEN
        FOR _cluster IN SELECT * FROM _con_clusters LOOP

            -- P2-A: ACCUMULATE rather than SET — superseded members are excluded
            -- from future scans (is_active=FALSE), so they cannot be re-collected;
            -- accumulation cannot double-count across multiple consolidate() passes.
            UPDATE pgmnemo.agent_lesson
            SET evidence_count = evidence_count + (_cluster.sz - 1)
            WHERE id = _cluster.canonical_id;

            FOREACH _mbr IN ARRAY _cluster.all_members LOOP
                CONTINUE WHEN _mbr = _cluster.canonical_id;

                -- v0.14.1 P1-A: read prior state before superseding
                SELECT state INTO _prior_state
                FROM pgmnemo.agent_lesson WHERE id = _mbr;

                UPDATE pgmnemo.agent_lesson
                SET state            = 'superseded',
                    is_active        = FALSE,
                    state_changed_at = NOW()
                WHERE id = _mbr;

                PERFORM pgmnemo.add_edge(
                    _mbr,
                    _cluster.canonical_id,
                    'SUPERSEDED_BY',
                    _cluster.mean_sim::FLOAT8,
                    jsonb_build_object(
                        'consolidation', TRUE,
                        'cluster_size',  _cluster.sz,
                        'prior_state',   _prior_state   -- v0.14.1 P1-A: for undo_consolidate()
                    ),
                    'max'
                );
            END LOOP;
        END LOOP;
    END IF;

    RETURN QUERY
    SELECT c.canonical_id, c.all_members, c.sz, c.mean_sim
    FROM _con_clusters c
    ORDER BY c.sz DESC, c.canonical_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.consolidate(REAL, BOOLEAN, TEXT, INT) IS
    'Cluster near-duplicate ACTIVE lessons by cosine similarity and collapse them. '
    'p_similarity REAL DEFAULT 0.92: cosine similarity threshold for grouping. '
    'p_dry_run BOOLEAN DEFAULT TRUE: when TRUE, return proposed clusters without any writes. '
    'p_role TEXT DEFAULT NULL: restrict to a single role (NULL = all roles). '
    'p_limit INT DEFAULT 100: max clusters to return / process per call. '
    'Returns: (canonical_id BIGINT, member_ids BIGINT[], size INT, mean_similarity REAL). '
    'Algorithm: union-find over all-pairs cosine similarity within each role. '
    'Canonical election: recall_count DESC, confidence DESC, importance DESC, '
    'created_at ASC, id ASC (stable tiebreaker — P1-4 v0.14.1 fix). '
    'Apply (p_dry_run=FALSE): canonical.evidence_count += (cluster_size - 1) [P2-A]; '
    'non-canonical members: state=superseded, is_active=FALSE, state_changed_at=NOW(); '
    'SUPERSEDED_BY edge (semantic) via add_edge() from each member to canonical; '
    'edge metadata includes prior_state for undo_consolidate() (v0.14.1 P1-A). '
    'All writes in the caller''s transaction — roll back on error. '
    'Guards: never self-supersedes; never collapses across different roles. '
    'Added in v0.14.0; tiebreaker fix v0.14.1 P1-4; prior_state recording v0.14.1 P1-A; '
    'evidence_count accumulation P2-A v0.14.2.';


-- =============================================================================
-- P2-D  classify_content_type() — narrow 'rejected' to prevent context-blind
--       false-positives on operational text
-- =============================================================================
-- ROOT CAUSE: the bare word-boundary pattern \mrejected\M matched any sentence
-- containing "rejected" (e.g. "The PR was rejected for having typos") and
-- classified it as 'decision', even though no decision is being recorded.
--
-- FIX: remove the bare \mrejected\M arm from the decision branch, mirroring the
-- treatment of \mbugfix\M in v0.14.1.  Genuine rejection decisions are still
-- caught by the remaining arms:
--   • 'decided', 'decision', 'verdict', 'approved', 'chosen'
--   • ADR[-\s]?\d pattern
--   • compound selection patterns (chose/selected/adopted + instead/over/rather than)
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.classify_content_type(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $func$
    SELECT CASE

        -- ── INCIDENT (highest priority) ────────────────────────────────────
        WHEN p_text ~* '\m(root.?cause|postmortem|outage|incident|hotfix|regression|rollback|revert)\M'
          OR p_text ~* '\m(stacktrace|traceback|segfault|oom.?kill)\M'
          OR (p_text ~* '\m(crashed?|broken|corrupted?|panicked?|failed)\M'
              AND p_text ~* '\m(caused|because of|due to|led to|resulted?|triggered?)\M')
          OR p_text ~* '\mthe (bug|error|issue|failure) (was|is)\M'
          -- NOTE: \mbugfix\M removed in v0.14.1 — caused false-positives on process
          -- text like "When submitting a bugfix PR, always …" (should be 'procedure').
        THEN 'incident'

        -- ── DECISION ────────────────────────────────────────────────────────
        WHEN p_text ~* '\mADR[-\s]?\d'
          OR p_text ~* '\m(decided|decision|verdict|approved|chosen)\M'
          -- NOTE: \mrejected\M removed in v0.14.2 — caused false-positives on
          -- operational text like "The PR was rejected for having typos" (should
          -- be NULL, not 'decision').  True rejection decisions fire via 'decided',
          -- 'decision', 'verdict', 'approved', 'chosen', or the compound patterns.
          OR p_text ~* 'we (chose|selected|adopted|agreed|preferred?|decided)\M'
          OR (p_text ~* '\m(chose|selected|adopted)\M'
              AND p_text ~* '\m(instead|over|rather than|in favor of)\M')
        THEN 'decision'

        -- ── ENTITY ──────────────────────────────────────────────────────────
        WHEN p_text ~* '\mis (?:a|the)(?:\s+\w+){0,2}\s+(?:service|tool|library|module|package|repo|repository|component|system|project)\M'
          OR p_text ~* '\mis (?:the)(?:\s+\w+){0,1}\s+(?:lead|owner|author|contact|maintainer|engineer|manager|architect|operator|po)\M'
          OR p_text ~* '\m(owns?|maintains?|is responsible for)\M'
        THEN 'entity'

        -- ── FACT ────────────────────────────────────────────────────────────
        WHEN (   p_text ~* '\m(defaults? to|default (value |port |behavior )?is)\M'
              OR p_text ~* '\malways returns?\M'
              OR p_text ~* '\m(is always|is set to|is stored in|is fixed at|is never)\M'
              OR p_text ~* '\mversion (is|was)\M'
              OR p_text ~* '\m(schema|table|column|port|endpoint) (is|has|was|uses?|contains?)\M'
             )
          AND p_text !~* '\mwhen\M'
          AND p_text !~* '\m(run|install|deploy|configure|restart|use)\M'
        THEN 'fact'

        -- ── PROCEDURE (catch-all) ────────────────────────────────────────────
        WHEN p_text ~* '\mwhen\M'
          OR p_text ~* '\m(must|should|always|never|avoid|prefer|recommend)\M'
          OR p_text ~* '\m(run|execute|install|deploy|configure|restart|use)\M'
          OR p_text ~* '\m(command|script|workflow|pattern|approach|method)\M'
          OR p_text ~* '\mhow to\M'
        THEN 'procedure'

        ELSE NULL
    END
$func$;

COMMENT ON FUNCTION pgmnemo.classify_content_type(text) IS
    'Deterministic keyword/regex content-type classifier (v0.14.2). No LLM. '
    'Returns: procedure | incident | decision | fact | entity | NULL. '
    'Priority: incident > decision > entity > fact > procedure > NULL. '
    'IMMUTABLE + STRICT: NULL input → NULL output; result is purely a function of the text. '
    'v0.14.1: removed bare \mbugfix\M arm — caused false-positives on process text. '
    'v0.14.2: removed bare \mrejected\M arm — caused false-positives on operational '
    'text like "The PR was rejected for having typos" (P2-D). '
    'Used by ingest() auto-fill and reclassify_corpus().';
