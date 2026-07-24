-- pgmnemo--0.13.0--0.14.0.sql
-- Upgrade: 0.13.0 → 0.14.0 — Corpus self-maintenance: classify-on-write
-- SPDX-License-Identifier: Apache-2.0

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  classify_content_type(p_text text) → text
-- ─────────────────────────────────────────────────────────────────────────────
-- Deterministic keyword/regex content-type classifier.  NO LLM.
-- Categories (evaluated in priority order — first match wins):
--
--   incident  — failure / outage / root-cause / postmortem context
--   decision  — explicit choice, agreement, ADR, verdict
--   entity    — person, service, project, component descriptor
--   fact      — stable state assertion (no instructional verbs present)
--   procedure — how-to, steps, commands (broad catch-all)
--   NULL      — no confident match; caller may keep existing label
--
-- The function is IMMUTABLE (no side effects, result depends only on input)
-- and STRICT (NULL input → NULL output, no exception).
-- Uses POSIX case-insensitive regex (~*) with ARE word-boundary anchors
-- (\m = word start, \M = word end).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.classify_content_type(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $func$
    SELECT CASE

        -- ── INCIDENT (highest priority) ────────────────────────────────────
        -- Explicit incident / postmortem / outage markers
        WHEN p_text ~* '\m(root.?cause|postmortem|outage|incident|hotfix|regression|rollback|revert)\M'
          OR p_text ~* '\m(stacktrace|traceback|segfault|oom.?kill)\M'
          -- Failure word + causation word together (describes *what happened*, not *what to do*)
          OR (p_text ~* '\m(crashed?|broken|corrupted?|panicked?|failed)\M'
              AND p_text ~* '\m(caused|because of|due to|led to|resulted?|triggered?)\M')
          -- Specific bug-report language
          OR p_text ~* '\mthe (bug|error|issue|failure) (was|is)\M'
          OR p_text ~* '\mbugfix\M'
        THEN 'incident'

        -- ── DECISION ────────────────────────────────────────────────────────
        -- ADR reference or explicit decision/agreement vocabulary
        WHEN p_text ~* '\mADR[-\s]?\d'
          OR p_text ~* '\m(decided|decision|verdict|approved|rejected|chosen)\M'
          OR p_text ~* 'we (chose|selected|adopted|agreed|preferred?|decided)\M'
          -- Comparative selection language (chose X over Y / instead of Y)
          OR (p_text ~* '\m(chose|selected|adopted)\M'
              AND p_text ~* '\m(instead|over|rather than|in favor of)\M')
        THEN 'decision'

        -- ── ENTITY ──────────────────────────────────────────────────────────
        -- Describes what something IS (person, service, system), not what to do.
        -- Allow optional modifier adjectives between "is (a|the)" and the type word.
        WHEN p_text ~* '\mis (?:a|the)(?:\s+\w+){0,2}\s+(?:service|tool|library|module|package|repo|repository|component|system|project)\M'
          OR p_text ~* '\mis (?:the)(?:\s+\w+){0,1}\s+(?:lead|owner|author|contact|maintainer|engineer|manager|architect|operator|po)\M'
          OR p_text ~* '\m(owns?|maintains?|is responsible for)\M'
        THEN 'entity'

        -- ── FACT ────────────────────────────────────────────────────────────
        -- Stable assertion about configuration / schema / state.
        -- Excluded when instructional verbs or "when" are present.
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
        -- How-to, operational advice, commands, patterns
        WHEN p_text ~* '\mwhen\M'
          OR p_text ~* '\m(must|should|always|never|avoid|prefer|recommend)\M'
          OR p_text ~* '\m(run|execute|install|deploy|configure|restart|use)\M'
          OR p_text ~* '\m(command|script|workflow|pattern|approach|method)\M'
          OR p_text ~* '\mhow to\M'
        THEN 'procedure'

        -- NULL: no confident match — caller keeps whatever label exists
        ELSE NULL
    END
$func$;

COMMENT ON FUNCTION pgmnemo.classify_content_type(text) IS
    'Deterministic keyword/regex content-type classifier (v0.14.0). No LLM. '
    'Returns: procedure | incident | decision | fact | entity | NULL. '
    'Priority: incident > decision > entity > fact > procedure > NULL. '
    'IMMUTABLE + STRICT: NULL input → NULL output; result is purely a function of the text. '
    'Used by ingest() auto-fill and reclassify_corpus().';


-- ─────────────────────────────────────────────────────────────────────────────
-- §2  ingest() — add p_content_type with auto-fill (v0.14.0)
-- ─────────────────────────────────────────────────────────────────────────────
-- Strategy:
--   • Drop the old 9-param signature (TEXT,INT,TEXT,TEXT,SMALLINT,vector,TEXT,TEXT,JSONB).
--   • Create a new 10-param signature with p_content_type TEXT DEFAULT NULL as the last param.
--   • Existing 9-arg call sites match the new function via the default — backward compatible.
--   • When p_content_type IS NULL → auto-derive via classify_content_type(p_lesson_text).
--   • When p_content_type is supplied → use it verbatim; never override an explicit caller value.
--   • All existing quality gates (F1 min-length, F2 repetition, F3 near-dup) are preserved.
--
-- NOTE: DROP works here because this script runs inside ALTER EXTENSION pgmnemo UPDATE,
-- which temporarily removes object-extension membership for the duration of the upgrade.
-- ─────────────────────────────────────────────────────────────────────────────

-- Remove old 9-param overload so the 10-param (with DEFAULT NULL) is unambiguous.
DROP FUNCTION IF EXISTS pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB);

CREATE FUNCTION pgmnemo.ingest(
    p_role           TEXT,
    p_project_id     INT,
    p_topic          TEXT,
    p_lesson_text    TEXT,
    p_importance     SMALLINT     DEFAULT 3,
    p_embedding      vector(1024) DEFAULT NULL,
    p_commit_sha     TEXT         DEFAULT NULL,
    p_artifact_hash  TEXT         DEFAULT NULL,
    p_metadata       JSONB        DEFAULT '{}'::jsonb,
    p_content_type   TEXT         DEFAULT NULL     -- NEW: auto-derived when NULL
) RETURNS BIGINT
LANGUAGE plpgsql AS $func$
DECLARE
    new_id                  BIGINT;
    _content_hash           TEXT;
    _prior_count            INT;
    _dedup_id               BIGINT;
    _dedup_sim              DOUBLE PRECISION;
    _tokens                 TEXT[];
    _token                  TEXT;
    _token_counts           JSONB;
    _max_freq               INT;
    _total_tokens           INT;
    _trimmed_text           TEXT;
    _effective_content_type TEXT;
BEGIN
    -- F1: minimum length guard
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) < 20 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars)';
    END IF;

    -- F2: token-frequency repetition guard
    _trimmed_text := trim(p_lesson_text);
    _tokens := regexp_split_to_array(
        regexp_replace(_trimmed_text, '\s+', ' ', 'g'), ' ');
    _total_tokens := array_length(_tokens, 1);

    IF _total_tokens > 0 THEN
        _token_counts := '{}'::JSONB;
        FOREACH _token IN ARRAY _tokens LOOP
            _token_counts := jsonb_set(
                _token_counts,
                ARRAY[_token],
                to_jsonb(COALESCE((_token_counts->>_token)::INT, 0) + 1)
            );
        END LOOP;

        SELECT MAX(value::INT)
        INTO _max_freq
        FROM jsonb_each_text(_token_counts);

        IF _max_freq::DOUBLE PRECISION / _total_tokens::DOUBLE PRECISION > 0.8 THEN
            RAISE EXCEPTION 'pgmnemo.ingest: lesson_text appears to be repetitive content';
        END IF;
    END IF;

    -- Embedding dimension guard
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch -- expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- F3: near-duplicate embedding guard
    IF p_embedding IS NOT NULL THEN
        SELECT id, (1.0 - (embedding <=> p_embedding))
        INTO _dedup_id, _dedup_sim
        FROM pgmnemo.agent_lesson
        WHERE is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
          AND embedding IS NOT NULL
          AND project_id = p_project_id
          AND (1.0 - (embedding <=> p_embedding)) > 0.98
        ORDER BY embedding <=> p_embedding
        LIMIT 1;

        IF FOUND THEN
            RAISE WARNING
                'pgmnemo.ingest: near-duplicate detected -- cosine similarity % > 0.98 '
                'to existing lesson_id=% (project_id=%). Returning existing lesson_id.',
                ROUND(_dedup_sim::NUMERIC, 4), _dedup_id, p_project_id;
            RETURN _dedup_id;
        END IF;
    END IF;

    -- Resolve effective content_type:
    --   caller-supplied value always wins; NULL → auto-derive via classifier
    _effective_content_type := COALESCE(
        p_content_type,
        pgmnemo.classify_content_type(p_lesson_text)
    );

    -- Bitemporal dedup observability
    _content_hash := MD5(
        COALESCE(p_role, '')  || '|' ||
        COALESCE(p_topic, '') || '|' ||
        COALESCE(p_commit_sha, COALESCE(p_artifact_hash, ''))
    );

    SELECT COUNT(*)::INT INTO _prior_count
    FROM pgmnemo.agent_lesson
    WHERE content_hash = _content_hash
      AND t_valid_to   = 'infinity'::TIMESTAMPTZ;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, content_type, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata, _effective_content_type,
        NOW()
    ) RETURNING id INTO new_id;

    IF _prior_count > 0 THEN
        RAISE NOTICE
            'pgmnemo.ingest: bitemporal close+create fired -- closed % prior version(s) '
            '(content_hash=%). New lesson_id=%.',
            _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB, TEXT) IS
    'Validated public write API v0.14.0. '
    'F1 (min-length): RAISE EXCEPTION when lesson_text < 20 chars. '
    'F2 (repetition): RAISE EXCEPTION when most-frequent token > 80%% of all tokens. '
    'F3 (dedup-warn): RAISE WARNING + RETURN existing lesson_id when cosine_sim > 0.98. '
    'v0.9.0: verified_at = NOW() for all lessons passing quality gates. '
    'v0.14.0: p_content_type (10th param, DEFAULT NULL) — when NULL, auto-derived via '
    'classify_content_type(lesson_text). Explicit caller value always wins. '
    'Provenance tier (commit_sha, artifact_hash) still contributes to ranking aux score.';


-- ─────────────────────────────────────────────────────────────────────────────
-- §3  reclassify_corpus(p_dry_run, p_limit) → TABLE(phase, content_type, cnt)
-- ─────────────────────────────────────────────────────────────────────────────
-- Re-derives content_type for all active lessons using classify_content_type().
--
-- p_dry_run  DEFAULT true  — return before/after distribution WITHOUT writing.
--                            Set to false to commit the UPDATE.
-- p_limit    DEFAULT NULL  — cap on rows to inspect/update (NULL = all rows).
--
-- Return schema:
--   phase        TEXT    — 'before' | 'after' (dry-run) or 'updated' (live)
--   content_type TEXT    — label value (NULL for unlabelled rows)
--   cnt          BIGINT  — row count
--
-- Dry-run "after" semantics:
--   For each row, proposed = COALESCE(classify(lesson_text), current_content_type).
--   Rows where the classifier returns NULL keep their existing label.
--
-- Live semantics (p_dry_run=false):
--   UPDATE content_type only when classify() returns non-NULL AND differs from current.
--   Returns counts by new content_type for the updated rows.
--
-- RETURN QUERY precedes each WITH clause — plpgsql requires RETURN QUERY to be
-- the first keyword of the statement, before any CTE definitions.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reclassify_corpus(
    p_dry_run  boolean DEFAULT true,
    p_limit    int     DEFAULT NULL
)
RETURNS TABLE (phase text, content_type text, cnt bigint)
LANGUAGE plpgsql AS $func$
BEGIN
    IF p_dry_run THEN
        -- ── DRY-RUN: compute distributions, no writes ──────────────────────
        -- Multi-level CTE: candidates → before_dist + after_dist → UNION ALL
        RETURN QUERY
        WITH candidates AS (
            SELECT
                al.content_type                                AS old_ct,
                pgmnemo.classify_content_type(al.lesson_text) AS new_ct
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
            ORDER BY al.id
            LIMIT p_limit
        ),
        -- BEFORE: current distribution
        before_dist AS (
            SELECT 'before'::text AS ph, c.old_ct AS ct, COUNT(*)::bigint AS n
            FROM candidates c
            GROUP BY c.old_ct
        ),
        -- AFTER: distribution if the live run were applied
        -- proposed label wins when non-NULL; else existing label is kept
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
        -- RETURN QUERY precedes the WITH so the DML CTE runs in the same statement.
        RETURN QUERY
        WITH to_update AS (
            SELECT al.id,
                   pgmnemo.classify_content_type(al.lesson_text) AS new_ct
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
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
    'Corpus self-maintenance: re-derive content_type for active lessons (v0.14.0). '
    'p_dry_run=true (default): returns before/after distributions without writing. '
    'p_dry_run=false: UPDATEs rows where classify_content_type() returns a non-NULL new label. '
    'p_limit: caps the number of rows inspected (NULL = all). '
    'Return columns: phase (before|after|updated), content_type, cnt.';

-- =============================================================================
-- §4  Schema: evidence_count column on agent_lesson           (R2 — consolidate)
-- =============================================================================

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS evidence_count INT NOT NULL DEFAULT 1
        CONSTRAINT ck_agent_lesson_evidence_count CHECK (evidence_count >= 1);

COMMENT ON COLUMN pgmnemo.agent_lesson.evidence_count IS
    'Number of near-duplicate lessons collapsed into this canonical. '
    'Default 1 (standalone lesson). '
    'Set to cluster size by pgmnemo.consolidate() when p_dry_run=FALSE. '
    'Added in v0.14.0.';

-- =============================================================================
-- §5  Function: pgmnemo.consolidate()                         (R2 — consolidate)
--
-- Clusters near-duplicate ACTIVE lessons within the same role using cosine
-- similarity of their embeddings.  Elects a canonical member per cluster
-- (rank: recall_count DESC, confidence DESC, importance DESC, created_at ASC).
--
-- Dry-run (p_dry_run=TRUE, the default):
--   Returns proposed clusters as (canonical_id, member_ids, size, mean_similarity)
--   without performing any writes.
--
-- Apply (p_dry_run=FALSE, inside one transaction):
--   - canonical.evidence_count = cluster size
--   - non-canonical members: state='superseded', is_active=FALSE
--   - SUPERSEDED_BY semantic edge inserted via add_edge() for each member
--     pointing to the canonical
--
-- Guards:
--   - never supersedes a lesson into itself  (CONTINUE WHEN _mbr = canonical)
--   - never collapses across different roles  (pairs restricted to a.role = b.role)
--   - terminal/inactive lessons excluded from candidate pool
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
    _pair     RECORD;
    _cluster  RECORD;
    _root_a   BIGINT;
    _root_b   BIGINT;
    _new_root BIGINT;
    _old_root BIGINT;
    _mbr      BIGINT;
BEGIN
    -- Discard any temp tables from a prior call in this session.
    DROP TABLE IF EXISTS _con_candidates;
    DROP TABLE IF EXISTS _con_pairs;
    DROP TABLE IF EXISTS _con_uf;
    DROP TABLE IF EXISTS _con_clusters;

    -- ── 1. Candidate pool ─────────────────────────────────────────────────
    -- Active, non-terminal lessons with embeddings, ordered by canonical rank.
    -- p_limit * 20 is the scan window; output is capped at p_limit clusters.
    CREATE TEMP TABLE _con_candidates ON COMMIT DROP AS
    SELECT id, role, recall_count, confidence, importance, created_at, embedding
    FROM pgmnemo.agent_lesson
    WHERE is_active
      AND state NOT IN ('superseded', 'archived', 'rejected')
      AND embedding IS NOT NULL
      AND (p_role IS NULL OR role = p_role)
    ORDER BY recall_count DESC, confidence DESC, importance DESC, created_at ASC
    LIMIT p_limit * 20;

    -- ── 2. All-pairs cosine similarity above threshold ────────────────────
    -- b.id > a.id avoids duplicate pairs; a.role = b.role enforces role boundary.
    CREATE TEMP TABLE _con_pairs ON COMMIT DROP AS
    SELECT
        a.id                                         AS id_a,
        b.id                                         AS id_b,
        (1.0 - (a.embedding <=> b.embedding))::REAL  AS sim
    FROM _con_candidates a
    JOIN _con_candidates b ON b.id > a.id
                          AND a.role = b.role
    WHERE (1.0 - (a.embedding <=> b.embedding)) >= p_similarity;

    -- ── 3. Union-Find: initialise each paired node as its own root ────────
    CREATE TEMP TABLE _con_uf (id BIGINT PRIMARY KEY, root BIGINT NOT NULL)
    ON COMMIT DROP;

    INSERT INTO _con_uf (id, root)
    SELECT DISTINCT id_a, id_a FROM _con_pairs
    UNION
    SELECT DISTINCT id_b, id_b FROM _con_pairs;

    -- ── 4. Union-Find: unite connected components ─────────────────────────
    FOR _pair IN SELECT id_a, id_b FROM _con_pairs LOOP
        SELECT root INTO _root_a FROM _con_uf WHERE id = _pair.id_a;
        SELECT root INTO _root_b FROM _con_uf WHERE id = _pair.id_b;
        IF _root_a IS DISTINCT FROM _root_b THEN
            _new_root := LEAST(_root_a, _root_b);
            _old_root := GREATEST(_root_a, _root_b);
            UPDATE _con_uf SET root = _new_root WHERE root = _old_root;
        END IF;
    END LOOP;

    -- ── 5. Path compression (flatten transitive chains) ───────────────────
    LOOP
        UPDATE _con_uf u
        SET root = p.root
        FROM _con_uf p
        WHERE p.id = u.root AND p.root <> u.root;
        EXIT WHEN NOT FOUND;
    END LOOP;

    -- ── 6. Materialise cluster results ────────────────────────────────────
    -- Canonical = members[1] (array ordered by recall_count DESC, …).
    -- Only clusters with size > 1 are returned.
    -- Mean similarity = avg of all intra-cluster pairs.
    CREATE TEMP TABLE _con_clusters ON COMMIT DROP AS
    WITH cluster_agg AS (
        SELECT
            u.root,
            array_agg(u.id ORDER BY
                c.recall_count DESC,
                c.confidence   DESC,
                c.importance   DESC,
                c.created_at   ASC
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

    -- ── 7. Apply (p_dry_run=FALSE only) — all writes in the caller's tx ───
    IF NOT p_dry_run THEN
        FOR _cluster IN SELECT * FROM _con_clusters LOOP

            -- Stamp canonical with consolidated evidence count
            UPDATE pgmnemo.agent_lesson
            SET evidence_count = _cluster.sz
            WHERE id = _cluster.canonical_id;

            -- Supersede every non-canonical member
            FOREACH _mbr IN ARRAY _cluster.all_members LOOP
                CONTINUE WHEN _mbr = _cluster.canonical_id;  -- self-guard

                -- Direct state update using existing 'superseded' lifecycle value
                UPDATE pgmnemo.agent_lesson
                SET state            = 'superseded',
                    is_active        = FALSE,
                    state_changed_at = NOW()
                WHERE id = _mbr;

                -- Semantic edge: member →[SUPERSEDED_BY]→ canonical
                -- add_edge() maps SUPERSEDED_BY to edge_kind='semantic' (catch-all)
                PERFORM pgmnemo.add_edge(
                    _mbr,
                    _cluster.canonical_id,
                    'SUPERSEDED_BY',
                    _cluster.mean_sim::FLOAT8,
                    jsonb_build_object(
                        'consolidation', TRUE,
                        'cluster_size',  _cluster.sz
                    ),
                    'max'
                );
            END LOOP;
        END LOOP;
    END IF;

    -- ── 8. Return cluster summary (both dry-run and apply paths) ──────────
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
    'Canonical election: recall_count DESC, confidence DESC, importance DESC, created_at ASC. '
    'Apply (p_dry_run=FALSE): canonical.evidence_count=cluster_size; '
    'non-canonical members: state=superseded, is_active=FALSE, state_changed_at=NOW(); '
    'SUPERSEDED_BY edge (semantic) via add_edge() from each member to canonical. '
    'All writes in the caller''s transaction — roll back on error. '
    'Guards: never self-supersedes; never collapses across different roles. '
    'Added in v0.14.0.';
