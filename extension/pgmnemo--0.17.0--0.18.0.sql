-- pgmnemo upgrade: 0.17.0 → 0.18.0
-- Auto-promotion: draft → validated by confirmed benefit
-- SPDX-License-Identifier: Apache-2.0
--
-- PROBLEM (AGMEM-2, 2026-08-14):
--   74 % of the corpus (6 819 lessons) is permanently stuck in 'draft'.
--   The state machine distinguishes checked knowledge from unchecked, but almost
--   nothing ever leaves draft — including lessons that have been recalled multiple
--   times and whose downstream runs succeeded.  The corpus cannot be trusted as a
--   signal of quality because 'validated' is populated almost exclusively by manual
--   curation.
--
-- SOLUTION:
--   A data-driven promotion rule: a draft lesson that has been recalled and its
--   downstream run reported 'success' at least N times is automatically promoted
--   to 'validated'.  N is configurable via GUC; the data-justified default is 3.
--
-- THRESHOLD JUSTIFICATION (corpus analysis, 2026-08-14, n = 6 819 draft lessons):
--   • 1 072 draft lessons have last_outcome = 'success' (i.e. were recalled and a
--     run succeeded after the recall).
--   • At threshold = 3 (success_count ≥ 3, last_outcome = 'success'): 280 lessons
--     eligible immediately.  At threshold = 2: 496.  At threshold = 4: 195.
--   • Bayesian posterior (Beta(α,β) with α=β=1 uniform prior):
--       s=3, f=0 → (3+1)/(3+0+2) = 0.80  (validated-confidence floor)
--       s=2, f=0 → (2+1)/(2+0+2) = 0.75  (border case)
--   • Threshold = 3 was chosen because it gives ≥ 0.80 confidence in the pure-
--     success case, matches the "three independent confirmations" heuristic used
--     in empirical CS validation (Juristo & Moreno, Software Engineering Empirical
--     Studies), and leaves the threshold tunable via GUC for projects with
--     different risk profiles.
--   • The additional guard last_outcome = 'success' (enforced at call time by
--     reinforce()) ensures recency: a lesson whose most recent feedback was
--     'failure' is not promoted even if success_count is high.
--
-- CURATOR EXEMPTION (mirrors 0.14.2 curation-honesty fix):
--   Any lesson with metadata @> '{"_auto_promote_exempt": true}' is never
--   auto-promoted.  This lets curators pin lessons in draft (e.g. after manual
--   demotion or while authoring).  Pattern is analogous to the content_type
--   exemption in reclassify_corpus() added in 0.14.2.
--
-- REVERSIBILITY:
--   • The metadata key _auto_promoted records the promotion event (timestamp,
--     threshold, reason) so every automatic transition is auditable.
--   • A new 'validated → draft' edge is added to agent_lesson_state_transition
--     so curators can explicitly revert via transition_lesson(id, 'draft').
--   • auto_promote_drafts(p_dry_run := TRUE) reports what would be promoted
--     without writing anything.
--
-- NEW GUCs:
--   pgmnemo.auto_promote_enabled   BOOLEAN  default TRUE   — kill switch
--   pgmnemo.auto_promote_threshold INT      default 3      — success_count floor
--
-- No schema column changes.  No index changes.  Upgrade path:
--   ALTER EXTENSION pgmnemo UPDATE TO '0.18.0';
-- =============================================================================


-- =============================================================================
-- §1  State-machine: add draft→validated and validated→draft edges
-- =============================================================================
-- draft → validated: auto-promotion path (this upgrade)
-- validated → draft: revert path (curator can undo an auto-promotion)
--
-- Both edges are required: the promotion must be a valid transition, and
-- reversibility requires the inverse to also be valid.

INSERT INTO pgmnemo.agent_lesson_state_transition (from_state, to_state)
VALUES
    ('draft',     'validated'),
    ('validated', 'draft')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE pgmnemo.agent_lesson_state_transition IS
    'Valid state-machine edges for agent_lesson.state.  '
    'draft→validated added in v0.18.0 (auto-promotion).  '
    'validated→draft added in v0.18.0 (curator revert path).';


-- =============================================================================
-- §1b  Index for auto-promotion eligibility queries
-- =============================================================================
-- auto_promote_drafts() and the inline hook in reinforce() both filter on
-- (state, last_outcome, success_count).  Without an index this is a full table
-- scan on every reinforce() call.  The partial index covers only the draft/success
-- sub-range, which is the hot path.

-- NOTE: CREATE INDEX CONCURRENTLY cannot run inside a transaction block.
-- ALTER EXTENSION pgmnemo UPDATE runs inside an implicit transaction, so this
-- index is created WITHOUT CONCURRENTLY.  On a large corpus this briefly locks
-- the table for writes; run during a maintenance window or create it manually:
--   CREATE INDEX CONCURRENTLY ix_pgmnemo_auto_promote_eligible
--       ON pgmnemo.agent_lesson (success_count DESC)
--       WHERE state = 'draft' AND last_outcome = 'success' AND is_active;

CREATE INDEX IF NOT EXISTS ix_pgmnemo_auto_promote_eligible
    ON pgmnemo.agent_lesson (success_count DESC)
    WHERE state = 'draft'
      AND last_outcome = 'success'
      AND is_active;

COMMENT ON INDEX pgmnemo.ix_pgmnemo_auto_promote_eligible IS
    'Partial index on (success_count DESC) for state=''draft'' + last_outcome=''success'' + is_active. '
    'Supports auto_promote_drafts() and the inline promotion check in reinforce(). v0.18.0.';


-- =============================================================================
-- §2  reinforce(BIGINT, TEXT, BOOLEAN) — add inline auto-promotion
-- =============================================================================
-- Replaces the v0.13.0 scalar reinforce with an identical body plus the
-- auto-promotion block.  All existing behaviour is preserved; the promotion
-- fires as a side-effect when:
--   • p_outcome = 'success'
--   • current state = 'draft'
--   • GUC pgmnemo.auto_promote_enabled is TRUE (default)
--   • metadata @> '{"_auto_promote_exempt": true}' is NOT set
--   • updated success_count >= pgmnemo.auto_promote_threshold (default 3)
-- The promotion is a single UPDATE inside the same transaction as the reinforce
-- call, so it is atomic with the count update.

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id  BIGINT,
    p_outcome    TEXT,
    p_used       BOOLEAN
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _row                   pgmnemo.agent_lesson%ROWTYPE;
    _new_conf              REAL;
    _mode                  TEXT;
    _alpha                 DOUBLE PRECISION;
    _beta                  DOUBLE PRECISION;
    _success_delta         DOUBLE PRECISION;
    _fail_delta            DOUBLE PRECISION;
    _effective_used        BOOLEAN;
    -- Auto-promote (v0.18.0)
    _auto_promote_enabled  BOOLEAN;
    _promote_threshold     INT;
    _new_success           INT;
BEGIN
    -- Resolve effective p_used: NULL → TRUE (backward compat)
    _effective_used := COALESCE(p_used, TRUE);

    -- Read confidence mode
    -- current_setting(..., TRUE) returns NULL when unset and never raises,
    -- so no exception wrapper: an unknown mode MUST surface, not silently
    -- fall back (a swallowed RAISE here defeats the validation entirely).
    _mode := COALESCE(
        NULLIF(current_setting('pgmnemo.confidence_mode', TRUE), ''),
        'posterior');
    IF _mode NOT IN ('posterior', 'additive') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown confidence_mode ''%'' — expected ''posterior'' or ''additive''',
            _mode;
    END IF;

    -- Lock row
    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    -- If lesson was not used, skip count update — preserve confidence
    IF NOT _effective_used THEN
        RETURN _row.confidence;
    END IF;

    -- Update outcome counters (always, regardless of mode)
    CASE p_outcome
        WHEN 'success' THEN
            UPDATE pgmnemo.agent_lesson
            SET success_count   = _row.success_count + 1,
                use_count       = _row.use_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            UPDATE pgmnemo.agent_lesson
            SET fail_count      = _row.fail_count + 1,
                use_count       = _row.use_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            -- Neutral: increment use_count but not success/fail
            UPDATE pgmnemo.agent_lesson
            SET use_count       = _row.use_count + 1,
                last_outcome    = 'neutral',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;
            RETURN _row.confidence;  -- no confidence change for neutral

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' — expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    -- ── Auto-promote draft → validated (v0.18.0) ─────────────────────────────
    -- Fires only when:
    --   (a) outcome is 'success'  (already ensured by surrounding IF)
    --   (b) lesson is currently in state 'draft'
    --   (c) GUC pgmnemo.auto_promote_enabled is not explicitly FALSE
    --   (d) lesson has no curator exemption flag in metadata
    --   (e) updated success_count reaches the configured threshold
    --
    -- The success_count is read back from the table (not from _row) so that
    -- the check reflects the just-committed increment.
    --
    -- Threshold default = 3: at success_count=3, fail_count=0 the Beta(1,1)
    -- posterior mean is 4/5 = 0.80, above the commonly used 0.75 validated-
    -- confidence floor.  Corpus analysis on 2026-08-14 showed 280 draft lessons
    -- immediately eligible (4.1 % of draft corpus, 26 % of ever-recalled drafts).
    IF p_outcome = 'success' AND _row.state = 'draft' THEN
        BEGIN
            _auto_promote_enabled := COALESCE(
                NULLIF(current_setting('pgmnemo.auto_promote_enabled', TRUE), '')::BOOLEAN,
                TRUE);
        EXCEPTION WHEN OTHERS THEN
            _auto_promote_enabled := TRUE;
        END;

        IF _auto_promote_enabled
           AND NOT COALESCE((_row.metadata @> '{"_auto_promote_exempt": true}'), FALSE)
        THEN
            BEGIN
                _promote_threshold := GREATEST(1, COALESCE(
                    NULLIF(current_setting('pgmnemo.auto_promote_threshold', TRUE), '')::INT,
                    3));
            EXCEPTION WHEN OTHERS THEN
                _promote_threshold := 3;
            END;

            SELECT success_count INTO _new_success
            FROM pgmnemo.agent_lesson WHERE id = p_lesson_id;

            IF _new_success >= _promote_threshold THEN
                UPDATE pgmnemo.agent_lesson
                SET state            = 'validated',
                    state_changed_at = NOW(),
                    metadata         = jsonb_set(
                                           COALESCE(metadata, '{}'::jsonb),
                                           '{_auto_promoted}',
                                           jsonb_build_object(
                                               'at',        to_char(NOW() AT TIME ZONE 'UTC',
                                                                    'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                               'from',      'draft',
                                               'reason',    format(
                                                                'success_count>=%s,reinforce()',
                                                                _promote_threshold),
                                               'threshold', _promote_threshold
                                           )
                                       )
                WHERE id = p_lesson_id
                  AND state = 'draft';  -- re-check: guard against concurrent transition
            END IF;
        END IF;
    END IF;
    -- ── end auto-promote ──────────────────────────────────────────────────────

    -- Compute new confidence
    IF _mode = 'posterior' THEN
        -- Read prior hyperparameters
        BEGIN
            _alpha := GREATEST(0.01, LEAST(100.0, COALESCE(
                NULLIF(current_setting('pgmnemo.confidence_prior_alpha', TRUE), '')::DOUBLE PRECISION,
                1.0)));
        EXCEPTION WHEN OTHERS THEN _alpha := 1.0;
        END;

        BEGIN
            _beta := GREATEST(0.01, LEAST(100.0, COALESCE(
                NULLIF(current_setting('pgmnemo.confidence_prior_beta', TRUE), '')::DOUBLE PRECISION,
                1.0)));
        EXCEPTION WHEN OTHERS THEN _beta := 1.0;
        END;

        -- Read updated counts (after the UPDATE above)
        SELECT success_count, fail_count INTO _row.success_count, _row.fail_count
        FROM pgmnemo.agent_lesson WHERE id = p_lesson_id;

        _new_conf := ((_row.success_count + _alpha) /
                      (_row.success_count + _row.fail_count + _alpha + _beta))::REAL;

    ELSE  -- 'additive' (legacy, deprecated)
        BEGIN
            _success_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
                NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
                0.02)));
        EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
        END;

        BEGIN
            _fail_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
                NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
                0.12)));
        EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
        END;

        IF p_outcome = 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
        ELSE  -- failure (neutral already returned above)
            _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
        END IF;
    END IF;

    -- Clamp and persist
    _new_conf := LEAST(1.0, GREATEST(0.0, _new_conf));

    UPDATE pgmnemo.agent_lesson
    SET confidence = _new_conf
    WHERE id = p_lesson_id;

    RETURN _new_conf;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT, BOOLEAN) IS
    'v0.13.0 Outcome Loop v2; v0.18.0 auto-promotion. '
    'p_outcome: ''success'' | ''failure'' | ''neutral'' (exact case). '
    'p_used: NULL/TRUE = lesson was used (counts updated, confidence recomputed); '
    '        FALSE = lesson shown but not used (no count/confidence change). '
    'Mode pgmnemo.confidence_mode: ''posterior'' (default, Beta posterior mean) '
    'or ''additive'' (legacy delta scheme, deprecated). '
    'Prior: pgmnemo.confidence_prior_alpha/beta (default 1.0/1.0 = uniform). '
    'Auto-promote (v0.18.0): after a ''success'' outcome, if the lesson is still '
    'in state=''draft'', its updated success_count ≥ pgmnemo.auto_promote_threshold '
    '(default 3), and the lesson has no metadata @> ''{\"_auto_promote_exempt\": true}'', '
    'the state is advanced to ''validated'' atomically.  The metadata key '
    '_auto_promoted records the event (at, from, reason, threshold) for audit. '
    'Kill switch: SET pgmnemo.auto_promote_enabled = ''false''.';


-- =============================================================================
-- §3  auto_promote_drafts(p_dry_run, p_limit) — batch promotion of legacy drafts
-- =============================================================================
-- Back-fills the corpus: promotes draft lessons that have already accumulated
-- enough evidence but predate the §2 hook.  Call once after upgrading to 0.18.0
-- (or periodically in maintenance windows).
--
-- Criteria match §2 exactly:
--   • state = 'draft'
--   • last_outcome = 'success'   (most recent reported outcome was success)
--   • success_count ≥ threshold  (GUC or default 3)
--   • NOT metadata @> '{"_auto_promote_exempt": true}'
--   • is_active = TRUE
--
-- p_dry_run = TRUE (default): returns the eligible set without writing.
-- p_dry_run = FALSE          : promotes them and returns the same set.
-- p_limit                    : cap on lessons processed per call (NULL = all).
--
-- Returns TABLE(lesson_id, role, topic, success_count, fail_count, dry_run).

CREATE OR REPLACE FUNCTION pgmnemo.auto_promote_drafts(
    p_dry_run   BOOLEAN DEFAULT TRUE,
    p_limit     INT     DEFAULT NULL
)
RETURNS TABLE (
    lesson_id     BIGINT,
    role          TEXT,
    topic         TEXT,
    success_count INT,
    fail_count    INT,
    dry_run       BOOLEAN
)
LANGUAGE plpgsql
AS $func$
DECLARE
    _threshold   INT;
    _ts          TEXT;
BEGIN
    -- Read threshold (same GUC as §2)
    BEGIN
        _threshold := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.auto_promote_threshold', TRUE), '')::INT,
            3));
    EXCEPTION WHEN OTHERS THEN
        _threshold := 3;
    END;

    _ts := to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

    IF p_dry_run THEN
        -- ── DRY-RUN: return eligible set, no writes ───────────────────────────
        RETURN QUERY
        SELECT
            al.id          AS lesson_id,
            al.role,
            al.topic,
            al.success_count,
            al.fail_count,
            TRUE           AS dry_run
        FROM pgmnemo.agent_lesson al
        WHERE al.state        = 'draft'
          AND al.last_outcome = 'success'
          AND al.success_count >= _threshold
          AND al.is_active
          AND NOT COALESCE((al.metadata @> '{"_auto_promote_exempt": true}'), FALSE)
        ORDER BY al.success_count DESC, al.id
        LIMIT p_limit;

    ELSE
        -- ── LIVE: promote and return the updated set ──────────────────────────
        -- Use a direct UPDATE … WHERE id IN (subquery) rather than CTE+FOR UPDATE.
        -- FOR UPDATE inside a CTE with LIMIT can produce an inefficient plan that
        -- locks the full result set before applying the limit, leading to long waits.
        RETURN QUERY
        WITH promoted AS (
            UPDATE pgmnemo.agent_lesson al
            SET state            = 'validated',
                state_changed_at = NOW(),
                metadata         = jsonb_set(
                                       COALESCE(al.metadata, '{}'::jsonb),
                                       '{_auto_promoted}',
                                       jsonb_build_object(
                                           'at',        _ts,
                                           'from',      'draft',
                                           'reason',    format(
                                                            'success_count>=%s,auto_promote_drafts()',
                                                            _threshold),
                                           'threshold', _threshold
                                       )
                                   )
            WHERE al.id IN (
                SELECT sub.id
                FROM pgmnemo.agent_lesson sub
                WHERE sub.state        = 'draft'
                  AND sub.last_outcome = 'success'
                  AND sub.success_count >= _threshold
                  AND sub.is_active
                  AND NOT COALESCE((sub.metadata @> '{"_auto_promote_exempt": true}'), FALSE)
                ORDER BY sub.success_count DESC, sub.id
                LIMIT p_limit
            )
            AND al.state = 'draft'   -- second guard: skip rows already advanced
            RETURNING al.id, al.role, al.topic, al.success_count, al.fail_count
        )
        SELECT
            p.id           AS lesson_id,
            p.role,
            p.topic,
            p.success_count,
            p.fail_count,
            FALSE          AS dry_run
        FROM promoted p
        ORDER BY p.success_count DESC, p.id;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.auto_promote_drafts(BOOLEAN, INT) IS
    'v0.18.0.  Batch-promote draft lessons that have already accumulated evidence. '
    'Promotes lessons where state=''draft'', last_outcome=''success'', '
    'success_count ≥ pgmnemo.auto_promote_threshold (default 3), is_active, '
    'and NOT metadata @> ''{\"_auto_promote_exempt\": true}''. '
    'p_dry_run=TRUE (default): returns eligible set without writing. '
    'p_dry_run=FALSE: promotes and returns promoted set. '
    'p_limit: cap on rows processed per call (NULL = all eligible). '
    'Metadata key _auto_promoted records the event (at, from, reason, threshold). '
    'Reversible: curator may call transition_lesson(id, ''draft'') to revert, '
    'or set metadata @> ''{\"_auto_promote_exempt\": true}'' to prevent future '
    'auto-promotion of a specific lesson. '
    'GUC pgmnemo.auto_promote_threshold controls the threshold for both this '
    'function and the inline hook in reinforce(). '
    'Typically called once after upgrading from < 0.18.0, then not needed '
    '(reinforce() handles new promotions inline).';

-- =============================================================================
-- PERF: Remove _stamp from read path (PGMREL-0180-IMPLEMENT)
-- 2026-08-14 · pgmnemo 0.18.0
-- =============================================================================
--
-- BEHAVIOUR BREAK: recall_hybrid() and recall_lessons() no longer update
-- last_recalled_at or recall_count. mark_stale() and corpus curation depend on
-- last_recalled_at; they will not function correctly unless callers explicitly
-- call pgmnemo.mark_recalled() after each recall.
--
-- Reason: the inline _stamp UPDATE CTE caused recall_hybrid to take
-- RowExclusiveLock (relation) + ExclusiveLock (per-row tuple) on the returned
-- lessons, held until transaction end. On a quiet system: +40 ms median overhead
-- (10× above the 4 ms retrieval baseline). Under concurrent write load: blocked
-- indefinitely, limited only by statement_timeout. The track_recall_recency GUC
-- gated only the row writes, not the relation lock — so even with the GUC off
-- the function participated in DDL lock convoys. See:
-- benchmarks/results/PGMREL-0180-BENCH-PERF-HYBRID-UNDER-WRITE-LOAD.md
--
-- RESTORING OLD BEHAVIOUR (call after each recall):
--   SELECT pgmnemo.mark_recalled(
--       ARRAY(SELECT lesson_id FROM pgmnemo.recall_hybrid(emb, text, k))
--   );
--
-- mark_recalled() is VOLATILE and takes the same locks the inline stamp did.
-- Call it asynchronously or in a separate transaction for best performance.
-- =============================================================================

-- Step 1: add mark_recalled() — explicit write-back function
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.mark_recalled(
    lesson_ids BIGINT[]
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF lesson_ids IS NULL OR array_length(lesson_ids, 1) IS NULL THEN
        RETURN;
    END IF;
    UPDATE pgmnemo.agent_lesson
    SET last_recalled_at = NOW(),
        recall_count     = recall_count + 1
    WHERE id = ANY(lesson_ids)
      AND is_active;
END;
$$;

COMMENT ON FUNCTION pgmnemo.mark_recalled(BIGINT[]) IS
    'v0.18.0 — Explicit recency write-back, separated from the recall read path. '
    'Updates last_recalled_at = NOW() and recall_count += 1 for each lesson ID '
    'in the input array. Skips IDs that are not active (is_active=false). '
    'Silently returns for NULL or empty input. '
    'VOLATILE — takes RowExclusiveLock on agent_lesson. '
    'Call after recall_hybrid() or recall_lessons() when recency tracking is needed. '
    'mark_stale() and corpus curation depend on last_recalled_at; they will not '
    'function correctly unless mark_recalled() is called after each recall. '
    'Previously this update was embedded in the recall functions themselves '
    '(the _stamp CTE, introduced in v0.9.5, removed in v0.18.0). '
    'See: benchmarks/results/PGMREL-0180-BENCH-PERF-HYBRID-UNDER-WRITE-LOAD.md';

-- Step 2: recall_hybrid — update 11-arg overload: remove _stamp CTE
-- =============================================================================
-- Note: recall_hybrid uses CREATE TEMP TABLE internally for _pgmnemo_vc and
-- _pgmnemo_bm25_work. PostgreSQL does not allow CREATE TABLE in STABLE functions.
-- The function remains VOLATILE. The performance fix is removing the _stamp CTE,
-- which was the source of RowExclusiveLock on pgmnemo.agent_lesson. Without _stamp,
-- the function takes NO locks on agent_lesson — it only reads from it.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL,
    p_content_types   text[]           DEFAULT NULL,
    p_min_score       REAL             DEFAULT NULL
)
RETURNS TABLE (
    lesson_id        BIGINT,
    score            DOUBLE PRECISION,
    vec_score        DOUBLE PRECISION,
    bm25_score       DOUBLE PRECISION,
    rrf_score        DOUBLE PRECISION,
    role             TEXT,
    project_id       INT,
    topic            TEXT,
    lesson_text      TEXT,
    importance       SMALLINT,
    metadata         JSONB,
    commit_sha       TEXT,
    artifact_hash    TEXT,
    verified_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ,
    confidence       REAL,
    match_confidence REAL
)
LANGUAGE plpgsql
VOLATILE
AS $func$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _raw_blend_weight   DOUBLE PRECISION;
    _ghost_count        INT;
    _fetch_k_vec        INT;
    _fetch_k_bm25       INT;
    _conf_boost_w       DOUBLE PRECISION;
    -- 0.10.1 additions (#87)
    _lexical_text       TEXT;
    _bm25_budget_ms     INT;
    _bm25_timed_out     BOOLEAN := FALSE;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION
            'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty -- '
            'at least one retrieval signal is required';
    END IF;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        _ef_search := 100;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;
    END;

    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
    END;

    -- v0.10.1 (#87): BM25 budget timeout (milliseconds)
    BEGIN
        _bm25_budget_ms := COALESCE(
            NULLIF(current_setting('pgmnemo.bm25_budget_ms', TRUE), '')::INT, 250);
    EXCEPTION WHEN OTHERS THEN _bm25_budget_ms := 250;
    END;

    -- v0.10.1 (#87): cap query_text length
    BEGIN
        _lexical_text := left(query_text,
            COALESCE(NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT, 2000));
    EXCEPTION WHEN OTHERS THEN _lexical_text := query_text;
    END;
    _has_text := _lexical_text IS NOT NULL AND length(trim(_lexical_text)) > 0;

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', _lexical_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', _lexical_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    -- Phase 1: HNSW vector retrieval via temp table (v0.14.1: literal LIMIT for planner)
    IF _has_vec THEN
        CREATE TEMP TABLE IF NOT EXISTS _pgmnemo_vc (
            id              BIGINT,
            role            TEXT,
            project_id      INT,
            topic           TEXT,
            lesson_text     TEXT,
            importance      SMALLINT,
            metadata        JSONB,
            commit_sha      TEXT,
            artifact_hash   TEXT,
            verified_at     TIMESTAMPTZ,
            created_at      TIMESTAMPTZ,
            confidence      REAL,
            raw_vec_score   DOUBLE PRECISION
        ) ON COMMIT DROP;
        TRUNCATE _pgmnemo_vc;

        EXECUTE format(
            $q$
            INSERT INTO _pgmnemo_vc
            SELECT
                al.id,
                al.role, al.project_id, al.topic, al.lesson_text,
                al.importance, al.metadata, al.commit_sha, al.artifact_hash,
                al.verified_at, al.created_at, al.confidence,
                (1.0 - (al.embedding <=> $1))::DOUBLE PRECISION AS raw_vec_score
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.embedding IS NOT NULL
              AND ($2 OR al.verified_at IS NOT NULL)
              AND ($3 IS NULL OR al.role = $3)
              AND ($4 IS NULL OR al.project_id = $4)
              AND ($5 IS NULL OR al.source_dag_id IS DISTINCT FROM $5)
              AND ($6 IS NULL OR al.content_type = ANY($6))
              AND ($7 IS NULL OR (al.t_valid_from <= $7 AND al.t_valid_to > $7))
              AND ($7 IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY al.embedding <=> $1
            LIMIT %s
            $q$,
            GREATEST(k * 4, _ef_search)
        )
        USING query_embedding, _include_unverified, role_filter,
              project_id_filter, exclude_dag_id, p_content_types, _as_of_ts;
    END IF;

    -- Phase 2: BM25 retrieval via temp table (with budget timeout)
    IF _has_text THEN
        CREATE TEMP TABLE IF NOT EXISTS _pgmnemo_bm25_work (
            id              BIGINT,
            raw_bm25_score  DOUBLE PRECISION
        ) ON COMMIT DROP;
        TRUNCATE _pgmnemo_bm25_work;

        BEGIN
            EXECUTE format(
                $q$
                INSERT INTO _pgmnemo_bm25_work
                SELECT al.id,
                    ts_rank_cd(al.lesson_tsv || al.topic_tsv, $1, 32)::DOUBLE PRECISION
                FROM pgmnemo.agent_lesson al
                WHERE al.is_active
                  AND ($2 OR al.verified_at IS NOT NULL)
                  AND (al.lesson_tsv @@ $1 OR al.topic_tsv @@ $1)
                  AND ($3 IS NULL OR al.role = $3)
                  AND ($4 IS NULL OR al.project_id = $4)
                  AND ($5 IS NULL OR al.source_dag_id IS DISTINCT FROM $5)
                  AND ($6 IS NULL OR al.content_type = ANY($6))
                  AND ($7 IS NULL OR (al.t_valid_from <= $7 AND al.t_valid_to > $7))
                  AND ($7 IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
                ORDER BY ts_rank_cd(al.lesson_tsv || al.topic_tsv, $1, 32) DESC
                LIMIT %s
                $q$,
                GREATEST(k * 4, 40)
            )
            USING _tsquery, _include_unverified, role_filter,
                  project_id_filter, exclude_dag_id, p_content_types, _as_of_ts;
        EXCEPTION WHEN QUERY_CANCELED THEN
            _bm25_timed_out := TRUE;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    all_candidates AS (
        -- Merge: vector candidates (temp table) LEFT JOIN bm25 results + anti-join UNION ALL
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM _pgmnemo_vc v                            -- temp table (was: vec_candidates CTE)
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        SELECT
            al.id, al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            bw.raw_bm25_score
        FROM _pgmnemo_bm25_work bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE (_has_vec IS FALSE OR bw.id NOT IN (SELECT id FROM _pgmnemo_vc))
    ),
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC) AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                           AS bm25_rank_sparse
        FROM all_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at, r.confidence,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 vec_weight  * r.raw_vec_score
               + bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    final AS (
        SELECT
            s.id,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.025 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.025 * s.confidence::DOUBLE PRECISION
                  + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0), 1.0))
                  + 0.05 * (CASE
                                WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                                WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                                ELSE 0.0 END)
                )
              + _conf_boost_w * (s.confidence::DOUBLE PRECISION - 0.5)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    final_results AS MATERIALIZED (
        SELECT
            f.id                   AS lesson_id,
            f.final_score          AS score,
            f.v_score              AS vec_score,
            f.b_score              AS bm25_score,
            f.rrf_sparse           AS rrf_score,
            f.role,
            f.project_id,
            f.topic,
            f.lesson_text,
            f.importance,
            f.metadata,
            f.commit_sha,
            f.artifact_hash,
            f.verified_at,
            f.created_at,
            f.confidence::REAL,
            LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence
        FROM final f
        WHERE (p_min_score IS NULL
               OR LEAST(1.0, GREATEST(0.0, f.v_score))::REAL >= p_min_score)
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    )
    -- v0.18.0: _stamp removed. Call mark_recalled() separately if needed.
    SELECT
        fr.lesson_id, fr.score, fr.vec_score, fr.bm25_score, fr.rrf_score,
        fr.role, fr.project_id, fr.topic, fr.lesson_text, fr.importance,
        fr.metadata, fr.commit_sha, fr.artifact_hash, fr.verified_at, fr.created_at,
        fr.confidence, fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

    IF NOT FOUND AND p_min_score IS NULL THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND al.verified_at IS NULL
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % matching lesson(s) are unverified (ingested without commit_sha/artifact_hash) '
                'and excluded by default. SET pgmnemo.include_unverified = ''on'' for this session, '
                'or pass provenance on ingest.',
                _ghost_count;
        END IF;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[], REAL) IS
    'v0.18.0 — VOLATILE (uses CREATE TEMP TABLE internally). Recency stamp (_stamp CTE) '
    'removed from read path: no longer takes RowExclusiveLock on pgmnemo.agent_lesson. '
    'Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM pgmnemo.recall_hybrid(...))) '
    'separately if you want last_recalled_at / recall_count to be updated. '
    'v0.14.1 — HNSW planner regression fix. Vector candidates fetched via EXECUTE with a '
    'literal LIMIT so the planner always sees the concrete value and chooses HNSW index scan. '
    'v0.13.0 — adds p_min_score REAL DEFAULT NULL (11th param). '
    'p_min_score: filter rows where match_confidence < p_min_score. NULL = no filter. '
    'v0.11.0 (P0.2): typed recall via p_content_types. '
    'v0.10.1 (#87): query_text cap, indexed BM25, bm25_budget_ms timeout. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'RRF fusion sparse-safe (Cormack 2009). graph_proximity via mem_edge walk (depth ≤5). '
    'VOLATILE (v0.18.0). No RowExclusiveLock on agent_lesson. mark_recalled() is the write path.';

-- Step 3: recall_lessons — update 9-arg overload: remove _stamp delegation
-- =============================================================================
-- recall_lessons delegates to recall_hybrid on the hybrid path. recall_hybrid
-- is now VOLATILE (because of CREATE TEMP TABLE) but no longer takes
-- RowExclusiveLock on agent_lesson. recall_lessons remains VOLATILE as well.
-- CREATE OR REPLACE updates the function body without DROP for extension-owned functions.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT         DEFAULT 10,
    role_filter       TEXT        DEFAULT NULL,
    project_id_filter INT         DEFAULT NULL,
    query_text        TEXT        DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ DEFAULT NULL,
    exclude_dag_id    TEXT        DEFAULT NULL,
    p_content_types   TEXT[]      DEFAULT NULL,
    p_min_score       REAL        DEFAULT NULL
)
RETURNS TABLE (
    lesson_id        BIGINT,
    score            DOUBLE PRECISION,
    role             TEXT,
    project_id       INT,
    topic            TEXT,
    lesson_text      TEXT,
    importance       SMALLINT,
    metadata         JSONB,
    commit_sha       TEXT,
    artifact_hash    TEXT,
    verified_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ,
    vec_score        DOUBLE PRECISION,
    bm25_score       DOUBLE PRECISION,
    rrf_score        DOUBLE PRECISION,
    confidence       REAL,
    match_confidence REAL
)
LANGUAGE plpgsql
VOLATILE
AS $func$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _ghost_count        INT;
BEGIN
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT, 2000);
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars. Original: %',
                     _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    _has_vec  := query_embedding IS NOT NULL;
    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _disable_hybrid := FALSE;
    END;

    -- Hybrid path delegates to recall_hybrid (now STABLE, no stamp)
    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60,
            exclude_dag_id, p_content_types, p_min_score
        ) h;
        RETURN;
    END IF;

    -- Vector-only path (no _stamp, already side-effect-free)
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION, 0.05);
    _temporal_boost := GREATEST(0.0, LEAST(20.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION, 1.0)));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;
    END;

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', _query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', _query_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    candidates AS (
        SELECT
            al.id           AS cand_id,
            al.role         AS cand_role,
            al.project_id   AS cand_project_id,
            al.topic        AS cand_topic,
            al.lesson_text  AS cand_lesson_text,
            al.importance   AS cand_importance,
            al.metadata     AS cand_metadata,
            al.commit_sha   AS cand_commit_sha,
            al.artifact_hash AS cand_artifact_hash,
            al.verified_at  AS cand_verified_at,
            al.created_at   AS cand_created_at,
            al.confidence   AS cand_confidence,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score_raw,
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score_raw
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          AND (exclude_dag_id IS NULL OR al.source_dag_id IS DISTINCT FROM exclude_dag_id)
          AND (p_content_types IS NULL OR al.content_type = ANY(p_content_types))
          AND (as_of_ts IS NULL
               OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts))
          AND (al.embedding IS NOT NULL OR _has_text)
          AND (al.t_valid_to = 'infinity'::TIMESTAMPTZ OR as_of_ts IS NOT NULL)
        ORDER BY al.embedding <=> query_embedding
        LIMIT GREATEST(k * 5, 50)
    ),
    anchors AS (
        SELECT cand_id FROM candidates ORDER BY vec_score_raw DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT cand_id, 0, cand_id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT reached_id AS gp_lesson_id,
               MAX(1.0 - depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk WHERE depth > 0 GROUP BY reached_id
    )
    SELECT
        c.cand_id        AS lesson_id,
        (
            c.vec_score_raw * (1.0 - _gamma)
          + _gamma * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0))
          + COALESCE(gp.proximity, 0.0) * _graph_weight
        )                AS score,
        c.cand_role      AS role,
        c.cand_project_id AS project_id,
        c.cand_topic     AS topic,
        c.cand_lesson_text AS lesson_text,
        c.cand_importance AS importance,
        c.cand_metadata  AS metadata,
        c.cand_commit_sha AS commit_sha,
        c.cand_artifact_hash AS artifact_hash,
        c.cand_verified_at AS verified_at,
        c.cand_created_at AS created_at,
        c.vec_score_raw  AS vec_score,
        c.ft_score_raw   AS bm25_score,
        0.0::DOUBLE PRECISION AS rrf_score,
        c.cand_confidence::REAL AS confidence,
        LEAST(1.0, GREATEST(0.0, c.vec_score_raw))::REAL AS match_confidence
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.gp_lesson_id = c.cand_id
    WHERE (p_min_score IS NULL
           OR LEAST(1.0, GREATEST(0.0, c.vec_score_raw))::REAL >= p_min_score)
    ORDER BY score DESC, c.cand_id ASC
    LIMIT k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ, TEXT, TEXT[], REAL) IS
    'v0.18.0 — VOLATILE. Recency stamp removed from recall path. No longer takes '
    'RowExclusiveLock on pgmnemo.agent_lesson. '
    'Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM pgmnemo.recall_lessons(...))) '
    'separately if you want last_recalled_at / recall_count to be updated. '
    'v0.13.0 hybrid router with diagnostic columns, typed recall, and min_score gate. '
    'Routes to recall_hybrid() when both query_embedding and query_text are present '
    '(and pgmnemo.disable_hybrid is FALSE/unset). '
    'Falls back to vector-only (HNSW + recency + graph) when query_text is absent. '
    'p_content_types TEXT[] DEFAULT NULL (8th param): typed recall pushdown. '
    'p_min_score REAL DEFAULT NULL (9th param): filter rows where match_confidence < p_min_score. '
    'GIN-indexed for BM25 retrieval via ts_rank_cd in recall_hybrid(). '
    'Respects pgmnemo.disable_hybrid, ef_search, include_unverified, recency_weight, '
    'temporal_boost, graph_proximity_weight, max_query_text_chars GUCs. VOLATILE (v0.18.0).';

-- =============================================================================
-- CONVERGENCE OVERRIDE (2026-08-18): the function bodies above drifted from the
-- flat 0.18.0 install — nine functions differed, and the migrated recall_hybrid
-- referenced a temp table it only creates when an embedding is present, so every
-- text-only call failed with 'relation "_pgmnemo_vc" does not exist' on upgraded
-- installs while fresh installs were fine. The canonical bodies below are
-- extracted verbatim from a fresh 0.18.0 install (pg_get_functiondef) and are
-- executed LAST, so an upgraded install converges to the flat one regardless of
-- what the earlier text produced. Body parity is now gate-checked.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(p_lesson_id bigint, p_outcome text)
 RETURNS real
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN pgmnemo.reinforce(p_lesson_id, p_outcome, NULL::BOOLEAN);
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(p_lesson_ids bigint[], p_outcome text)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN pgmnemo.reinforce(p_lesson_ids, p_outcome, NULL::BOOLEAN);
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(query_embedding vector, query_text text, token_budget_chars integer DEFAULT 2000, jsonb_filter jsonb DEFAULT NULL::jsonb, project_id_filter integer DEFAULT NULL::integer)
 RETURNS TABLE(id bigint, preview text, score double precision, tokens_consumed integer, navigation_path text)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 2;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _vec_weight         CONSTANT DOUBLE PRECISION := 0.4;
    _bm25_weight        CONSTANT DOUBLE PRECISION := 0.4;
    _raw_blend_weight   DOUBLE PRECISION;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.navigate_locate: both query_embedding and query_text are NULL/empty';
    END IF;

    _rrf_k_f := 60.0;
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN
        _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', left(trim(query_text), 200));   -- Fix 4+1
            EXCEPTION WHEN OTHERS THEN
                _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    raw_candidates AS (
        SELECT
            al.id,
            al.topic_tsv,
            al.lesson_tsv,
            al.lesson_text,
            al.importance,
            al.commit_sha,
            al.verified_at,
            al.created_at,
            al.metadata,
            length(al.lesson_text)                                            AS text_len,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            CASE
                WHEN _has_text AND (al.topic_tsv @@ _tsquery OR al.lesson_tsv @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(al.topic_tsv, 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (navigate_locate.project_id_filter IS NULL
               OR al.project_id = navigate_locate.project_id_filter)
          AND (navigate_locate.jsonb_filter IS NULL
               OR al.metadata @> navigate_locate.jsonb_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
          AND (
                  (_has_vec  AND al.embedding IS NOT NULL)
               OR (_has_text AND (al.topic_tsv @@ _tsquery OR al.lesson_tsv @@ _tsquery))
          )
    ),
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC)  AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK()   OVER (PARTITION BY (raw_bm25_score > 0)
                                     ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                                  AS bm25_rank_sparse,
            COUNT(*) OVER ()                                                     AS n_candidates
        FROM raw_candidates
    ),
    scored AS (
        SELECT
            r.id, r.text_len, r.lesson_text, r.metadata, r.importance,
            r.commit_sha, r.verified_at, r.created_at,
            r.vec_rank, r.n_candidates,
            CASE WHEN r.bm25_rank_sparse IS NOT NULL THEN r.bm25_rank_sparse
                 ELSE r.n_candidates + 1
            END AS bm25_rank_eff,
            (
                _vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
              + _bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                     r.n_candidates + 1)::DOUBLE PRECISION)
              + _raw_blend_weight * (
                    _vec_weight  * r.raw_vec_score
                  + _bm25_weight * r.raw_bm25_score)
            ) AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0  -- Fix 5
        UNION ALL
        SELECT
            gw.anchor_id,
            gw.depth + 1,
            CASE WHEN me.source_id = gw.reached_id
                    THEN me.target_id
                    ELSE me.source_id
               END
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = gw.reached_id OR me.target_id = gw.reached_id
        )
        WHERE gw.depth < _max_depth
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
    ),
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    ),
    final_ranked AS (
        SELECT
            s.id,
            s.text_len,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0))::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE 0.0 END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.lesson_text,
            s.metadata
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    budget_consumed AS (
        SELECT
            fr.id,
            fr.final_score,
            fr.lesson_text,
            fr.metadata,
            fr.text_len,
            SUM(fr.text_len) OVER (ORDER BY fr.final_score DESC, fr.id ASC) AS cumulative_chars
        FROM final_ranked fr
    )
    SELECT
        bc.id,
        left(bc.lesson_text, 120)::TEXT  AS preview,
        bc.final_score                   AS score,
        bc.text_len::INT                 AS tokens_consumed,
        NULL::TEXT                       AS navigation_path
    FROM budget_consumed bc
    WHERE bc.cumulative_chars <= navigate_locate.token_budget_chars
    ORDER BY bc.final_score DESC, bc.id ASC;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand(ids bigint[], expand_fields text[] DEFAULT '{}'::text[], graph_expand_depth integer DEFAULT 1, graph_expand_threshold double precision DEFAULT 0.5, relation_types text[] DEFAULT NULL::text[])
 RETURNS TABLE(id bigint, content text, expand_detail jsonb, graph_neighbor_ids bigint[], graph_neighbor_previews text[], tokens_consumed integer, navigation_path text)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
BEGIN
    IF ids IS NULL OR array_length(ids, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    -- Step 1: seed rows — the requested IDs
    seed_rows AS (
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, al.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE al.metadata ? f
                )
                ELSE NULL::JSONB
            END                                                            AS expand_detail,
            'content'::TEXT                                                AS navigation_path,
            0                                                              AS depth,
            ARRAY[al.id]                                                   AS path
        FROM pgmnemo.agent_lesson al
        WHERE al.id = ANY(ids)
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
    ),
    -- Step 2: BFS graph expansion — BIDIRECTIONAL, relation_type-gated, weight-gated
    graph_expand (node_id, lesson_text, metadata, depth, path) AS (
        SELECT sr.id, sr.lesson_text, sr.metadata, 0, sr.path
        FROM seed_rows sr

        UNION ALL

        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            ge.depth + 1,
            ge.path || al.id
        FROM graph_expand ge
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = ge.node_id OR me.target_id = ge.node_id
        )
        JOIN pgmnemo.agent_lesson al ON al.id = CASE
            WHEN me.source_id = ge.node_id THEN me.target_id
            ELSE me.source_id
        END
        WHERE ge.depth < graph_expand_depth
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND NOT (al.id = ANY(ge.path))
          AND (relation_types IS NULL OR me.relation_type = ANY(relation_types))
          AND me.weight >= graph_expand_threshold
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
    ),
    -- Step 3: expanded rows — neighbors not in seed set
    expanded_rows AS (
        SELECT DISTINCT ON (ge.node_id)
            ge.node_id AS id,
            ge.lesson_text,
            ge.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, ge.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE ge.metadata ? f
                )
                ELSE NULL::JSONB
            END AS expand_detail,
            'graph_expand'::TEXT AS navigation_path
        FROM graph_expand ge
        WHERE ge.depth > 0
          AND NOT (ge.node_id = ANY(ids))
        ORDER BY ge.node_id, ge.depth ASC
    ),
    -- Step 4a: distinct neighbors per seed
    distinct_neighbors AS (
        SELECT
            ge.path[1]   AS seed_id,
            ge.node_id,
            ge.depth,
            left(ge.lesson_text, 50)  AS neighbor_preview
        FROM graph_expand ge
        WHERE ge.depth > 0
          AND NOT (ge.node_id = ANY(ids))
        ORDER BY ge.path[1], ge.node_id, ge.depth ASC
    ),
    neighbor_summary AS (
        SELECT
            dn.seed_id,
            array_agg(dn.node_id ORDER BY dn.depth, dn.node_id)          AS neighbor_ids,
            array_agg(dn.neighbor_preview ORDER BY dn.depth, dn.node_id) AS neighbor_previews
        FROM distinct_neighbors dn
        GROUP BY dn.seed_id
    ),
    -- Step 5: union seed + expanded
    combined AS (
        SELECT sr.id,
               sr.lesson_text                                  AS content,
               sr.expand_detail,
               ns.neighbor_ids                                 AS graph_neighbor_ids,
               ns.neighbor_previews                            AS graph_neighbor_previews,
               sr.navigation_path
        FROM seed_rows sr
        LEFT JOIN neighbor_summary ns ON ns.seed_id = sr.id

        UNION ALL

        SELECT er.id,
               er.lesson_text                                  AS content,
               er.expand_detail,
               NULL::BIGINT[]                                  AS graph_neighbor_ids,
               NULL::TEXT[]                                    AS graph_neighbor_previews,
               er.navigation_path
        FROM expanded_rows er
    ),
    -- v0.9.5: materialise combined before stamping
    expand_results AS MATERIALIZED (
        SELECT
            c.id,
            c.content,
            c.expand_detail,
            c.graph_neighbor_ids,
            c.graph_neighbor_previews,
            SUM(length(c.content)) OVER (
                ORDER BY c.id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )::INT  AS tokens_consumed,
            c.navigation_path
        FROM combined c
        ORDER BY c.id ASC
    ),
    -- v0.9.5: stamp recency on all returned lesson IDs
    _stamp AS (
        UPDATE pgmnemo.agent_lesson
        SET last_recalled_at = NOW(),
            recall_count     = recall_count + 1
        WHERE id = ANY(ARRAY(SELECT er.id FROM expand_results er))
          AND COALESCE(
              NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
              TRUE)
        RETURNING id
    )
    SELECT
        er.id,
        er.content,
        er.expand_detail,
        er.graph_neighbor_ids,
        er.graph_neighbor_previews,
        er.tokens_consumed,
        er.navigation_path
    FROM expand_results er
    ORDER BY er.id ASC;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.guard_no_test_project(p_project_id integer, p_allowed_db text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.remember_fact(p_role text, p_entity_key text, p_property text, p_value text, p_confidence real DEFAULT 0.7, p_has_contact_pii boolean DEFAULT NULL::boolean, p_embedding vector DEFAULT NULL::vector, p_source_type text DEFAULT NULL::text, p_project_id integer DEFAULT NULL::integer, p_commit_sha text DEFAULT NULL::text, p_artifact_hash text DEFAULT NULL::text)
 RETURNS TABLE(id bigint, final_state text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    _topic         TEXT;
    _artifact_hash TEXT;
    _is_pii        BOOLEAN;
    _final_state   TEXT;
    _merge_state   TEXT;    -- actual post-merge state (may differ from _final_state for promote)
    _prior         pgmnemo.agent_lesson%ROWTYPE;
    _new_id        BIGINT;
    _version_n     INT;
    _eff_source    TEXT;
BEGIN
    -- Input guards
    IF p_entity_key IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_entity_key must not be NULL';
    END IF;
    IF p_entity_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: invalid entity_key ''%'' — must match slug regex', p_entity_key;
    END IF;
    IF p_property IS NULL OR length(trim(p_property)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_property must not be NULL or empty';
    END IF;
    IF p_value IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_value must not be NULL';
    END IF;
    IF p_confidence IS NOT NULL AND (p_confidence < 0.0 OR p_confidence > 1.0) THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_confidence % out of [0,1]', p_confidence;
    END IF;
    IF p_source_type IS NOT NULL AND
       p_source_type NOT IN ('system','agent_authored','auto_captured','imported') THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: invalid source_type ''%''', p_source_type;
    END IF;

    -- R2: Synthesize artifact_hash (COALESCE BEFORE gate can inspect)
    -- topic: lower(entity_key)/lower(property) per RFC-001 §D2
    _topic         := lower(p_entity_key) || '/' || lower(p_property);
    _artifact_hash := COALESCE(p_artifact_hash, 'fact-' || p_entity_key || ':' || p_property);

    -- R1/R7: PII detection — explicit override wins, else auto-detect
    _is_pii := COALESCE(
        p_has_contact_pii,
        pgmnemo._has_contact_pii(p_property) AND (p_entity_key LIKE 'person:%')
    );

    -- R1: State routing (RFC-001 §D4)
    -- PII on person:* → candidate ALWAYS (even system source)
    IF _is_pii THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'system' THEN
        _final_state := 'validated';
    ELSIF p_source_type = 'auto_captured' THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.0) >= 0.8 THEN
        _final_state := 'validated';
    ELSE
        -- agent_authored low-conf, imported, NULL source_type → candidate
        _final_state := 'candidate';
    END IF;

    _eff_source := COALESCE(p_source_type, 'agent_authored');

    -- R3: Identity/dedup on (lower(topic), project_id) with FOR UPDATE
    SELECT * INTO _prior
    FROM pgmnemo.agent_lesson
    WHERE lower(topic) = lower(_topic)
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ
    ORDER BY version_n DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        IF lower(trim(_prior.lesson_text)) = lower(trim(p_value)) THEN
            -- MERGE: same value — update confidence + promote state, no new version.
            -- Promotion rule: 'validated' wins over 'candidate'/'draft'; never demote.
            UPDATE pgmnemo.agent_lesson
            SET confidence = GREATEST(confidence, COALESCE(p_confidence, 0.7)),
                state      = CASE
                                 WHEN _final_state = 'validated'
                                      AND state NOT IN ('validated', 'canonical')
                                 THEN 'validated'
                                 ELSE state
                             END
            WHERE agent_lesson.id = _prior.id
            RETURNING agent_lesson.state INTO _merge_state;
            RETURN QUERY SELECT _prior.id, _merge_state;
            RETURN;
        ELSE
            -- SUPERSEDE: different value — close prior row via shared eviction helper, open new version
            PERFORM pgmnemo._evict_prior_lesson(_prior.id);
            _version_n := COALESCE(_prior.version_n, 0) + 1;
        END IF;
    ELSE
        _version_n := 1;
    END IF;

    -- INSERT new fact row
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        embedding, commit_sha, artifact_hash, metadata,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to
    ) VALUES (
        p_role, p_project_id, _topic, p_value, 3,
        p_embedding, p_commit_sha, _artifact_hash,
        jsonb_build_object(
            'canonical_name', p_entity_key,
            'entity_key',     p_entity_key,
            'property',       p_property
        ),
        _eff_source, 'fact', _final_state,
        COALESCE(p_confidence, 0.7),
        _version_n,
        -- validated → visible to recall; candidate → ghost (verified_at NULL)
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        NOW(),
        'infinity'::TIMESTAMPTZ
    )
    RETURNING agent_lesson.id INTO _new_id;

    RETURN QUERY SELECT _new_id, _final_state;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(p_lesson_id bigint, p_outcome text, p_used boolean)
 RETURNS real
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    _row                   pgmnemo.agent_lesson%ROWTYPE;
    _new_conf              REAL;
    _mode                  TEXT;
    _alpha                 DOUBLE PRECISION;
    _beta                  DOUBLE PRECISION;
    _success_delta         DOUBLE PRECISION;
    _fail_delta            DOUBLE PRECISION;
    _effective_used        BOOLEAN;
    -- Auto-promote (v0.18.0)
    _auto_promote_enabled  BOOLEAN;
    _promote_threshold     INT;
    _new_success           INT;
BEGIN
    -- Resolve effective p_used: NULL → TRUE (backward compat)
    _effective_used := COALESCE(p_used, TRUE);

    -- Read confidence mode
    -- current_setting(..., TRUE) returns NULL when unset and never raises,
    -- so no exception wrapper: an unknown mode MUST surface, not silently
    -- fall back (a swallowed RAISE here defeats the validation entirely).
    _mode := COALESCE(
        NULLIF(current_setting('pgmnemo.confidence_mode', TRUE), ''),
        'posterior');
    IF _mode NOT IN ('posterior', 'additive') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown confidence_mode ''%'' — expected ''posterior'' or ''additive''',
            _mode;
    END IF;

    -- Lock row
    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    -- If lesson was not used, skip count update — preserve confidence
    IF NOT _effective_used THEN
        RETURN _row.confidence;
    END IF;

    -- Update outcome counters (always, regardless of mode)
    CASE p_outcome
        WHEN 'success' THEN
            UPDATE pgmnemo.agent_lesson
            SET success_count   = _row.success_count + 1,
                use_count       = _row.use_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            UPDATE pgmnemo.agent_lesson
            SET fail_count      = _row.fail_count + 1,
                use_count       = _row.use_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            -- Neutral: increment use_count but not success/fail
            UPDATE pgmnemo.agent_lesson
            SET use_count       = _row.use_count + 1,
                last_outcome    = 'neutral',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;
            RETURN _row.confidence;  -- no confidence change for neutral

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' — expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    -- ── Auto-promote draft → validated (v0.18.0) ─────────────────────────────
    -- Fires only when:
    --   (a) outcome is 'success'  (already ensured by surrounding IF)
    --   (b) lesson is currently in state 'draft'
    --   (c) GUC pgmnemo.auto_promote_enabled is not explicitly FALSE
    --   (d) lesson has no curator exemption flag in metadata
    --   (e) updated success_count reaches the configured threshold
    --
    -- The success_count is read back from the table (not from _row) so that
    -- the check reflects the just-committed increment.
    --
    -- Threshold default = 3: at success_count=3, fail_count=0 the Beta(1,1)
    -- posterior mean is 4/5 = 0.80, above the commonly used 0.75 validated-
    -- confidence floor.  Corpus analysis on 2026-08-14 showed 280 draft lessons
    -- immediately eligible (4.1 % of draft corpus, 26 % of ever-recalled drafts).
    IF p_outcome = 'success' AND _row.state = 'draft' THEN
        BEGIN
            _auto_promote_enabled := COALESCE(
                NULLIF(current_setting('pgmnemo.auto_promote_enabled', TRUE), '')::BOOLEAN,
                TRUE);
        EXCEPTION WHEN OTHERS THEN
            _auto_promote_enabled := TRUE;
        END;

        IF _auto_promote_enabled
           AND NOT COALESCE((_row.metadata @> '{"_auto_promote_exempt": true}'), FALSE)
        THEN
            BEGIN
                _promote_threshold := GREATEST(1, COALESCE(
                    NULLIF(current_setting('pgmnemo.auto_promote_threshold', TRUE), '')::INT,
                    3));
            EXCEPTION WHEN OTHERS THEN
                _promote_threshold := 3;
            END;

            SELECT success_count INTO _new_success
            FROM pgmnemo.agent_lesson WHERE id = p_lesson_id;

            IF _new_success >= _promote_threshold THEN
                UPDATE pgmnemo.agent_lesson
                SET state            = 'validated',
                    state_changed_at = NOW(),
                    metadata         = jsonb_set(
                                           COALESCE(metadata, '{}'::jsonb),
                                           '{_auto_promoted}',
                                           jsonb_build_object(
                                               'at',        to_char(NOW() AT TIME ZONE 'UTC',
                                                                    'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                               'from',      'draft',
                                               'reason',    format(
                                                                'success_count>=%s,reinforce()',
                                                                _promote_threshold),
                                               'threshold', _promote_threshold
                                           )
                                       )
                WHERE id = p_lesson_id
                  AND state = 'draft';  -- re-check: guard against concurrent transition
            END IF;
        END IF;
    END IF;
    -- ── end auto-promote ──────────────────────────────────────────────────────

    -- Compute new confidence
    IF _mode = 'posterior' THEN
        -- Read prior hyperparameters
        BEGIN
            _alpha := GREATEST(0.01, LEAST(100.0, COALESCE(
                NULLIF(current_setting('pgmnemo.confidence_prior_alpha', TRUE), '')::DOUBLE PRECISION,
                1.0)));
        EXCEPTION WHEN OTHERS THEN _alpha := 1.0;
        END;

        BEGIN
            _beta := GREATEST(0.01, LEAST(100.0, COALESCE(
                NULLIF(current_setting('pgmnemo.confidence_prior_beta', TRUE), '')::DOUBLE PRECISION,
                1.0)));
        EXCEPTION WHEN OTHERS THEN _beta := 1.0;
        END;

        -- Read updated counts (after the UPDATE above)
        SELECT success_count, fail_count INTO _row.success_count, _row.fail_count
        FROM pgmnemo.agent_lesson WHERE id = p_lesson_id;

        _new_conf := ((_row.success_count + _alpha) /
                      (_row.success_count + _row.fail_count + _alpha + _beta))::REAL;

    ELSE  -- 'additive' (legacy, deprecated)
        BEGIN
            _success_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
                NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
                0.02)));
        EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
        END;

        BEGIN
            _fail_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
                NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
                0.12)));
        EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
        END;

        IF p_outcome = 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
        ELSE  -- failure (neutral already returned above)
            _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
        END IF;
    END IF;

    -- Clamp and persist
    _new_conf := LEAST(1.0, GREATEST(0.0, _new_conf));

    UPDATE pgmnemo.agent_lesson
    SET confidence = _new_conf
    WHERE id = p_lesson_id;

    RETURN _new_conf;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(p_lesson_ids bigint[], p_outcome text, p_used boolean)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    _id              BIGINT;
    _count           INT := 0;
    _effective_used  BOOLEAN;
BEGIN
    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    IF p_outcome NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' — expected ''success'', ''failure'', or ''neutral''',
            p_outcome;
    END IF;

    _effective_used := COALESCE(p_used, TRUE);

    FOREACH _id IN ARRAY p_lesson_ids LOOP
        BEGIN
            PERFORM pgmnemo.reinforce(_id, p_outcome, _effective_used);
            -- v0.7.1 contract: return value counts confidence-updated lessons.
            -- Neutral outcomes are stamped (last_outcome, use attribution) but
            -- do not change confidence, so they are not counted.
            IF p_outcome <> 'neutral' THEN
                _count := _count + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Skip missing lesson_ids silently (batch contract)
            NULL;
        END;
    END LOOP;

    RETURN _count;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(query_embedding vector, query_text text, k integer DEFAULT 10, role_filter text DEFAULT NULL::text, project_id_filter integer DEFAULT NULL::integer, vec_weight double precision DEFAULT 0.4, bm25_weight double precision DEFAULT 0.4, rrf_k integer DEFAULT 60, exclude_dag_id text DEFAULT NULL::text, p_content_types text[] DEFAULT NULL::text[], p_min_score real DEFAULT NULL::real)
 RETURNS TABLE(lesson_id bigint, score double precision, vec_score double precision, bm25_score double precision, rrf_score double precision, role text, project_id integer, topic text, lesson_text text, importance smallint, metadata jsonb, commit_sha text, artifact_hash text, verified_at timestamp with time zone, created_at timestamp with time zone, confidence real, match_confidence real)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _raw_blend_weight   DOUBLE PRECISION;
    _ghost_count        INT;
    _fetch_k_vec        INT;
    _fetch_k_bm25       INT;
    _conf_boost_w       DOUBLE PRECISION;
    -- 0.10.1 additions (#87)
    _lexical_text       TEXT;
    _bm25_budget_ms     INT;
    _bm25_timed_out     BOOLEAN := FALSE;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION
            'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty -- '
            'at least one retrieval signal is required';
    END IF;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        _ef_search := 100;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default, reconciled in v0.17.0
    END;

    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
    END;

    BEGIN
        _bm25_budget_ms := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.bm25_budget_ms', TRUE), '')::INT, 250));
    EXCEPTION WHEN OTHERS THEN _bm25_budget_ms := 250;
    END;

    IF _has_text THEN
        _lexical_text := left(trim(query_text), 200);
        BEGIN
            _tsquery := websearch_to_tsquery('simple', _lexical_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', _lexical_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    -- ── BM25 candidates (unchanged from v0.14.0) ──────────────────────────────
    BEGIN
        CREATE TEMP TABLE _pgmnemo_bm25_work (
            id             BIGINT          PRIMARY KEY,
            raw_bm25_score DOUBLE PRECISION NOT NULL DEFAULT 0.0
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_bm25_work;
    END;

    IF _has_text THEN
        BEGIN
            EXECUTE format('SET LOCAL statement_timeout = %s', _bm25_budget_ms);

            INSERT INTO _pgmnemo_bm25_work (id, raw_bm25_score)
            SELECT
                al.id,
                ts_rank_cd(al.full_text, _tsquery, 32)::DOUBLE PRECISION
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.full_text @@ _tsquery
              AND (_include_unverified OR al.verified_at IS NOT NULL)
              AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
              AND (recall_hybrid.project_id_filter IS NULL
                   OR al.project_id = recall_hybrid.project_id_filter)
              AND (recall_hybrid.exclude_dag_id IS NULL
                   OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
              AND (recall_hybrid.p_content_types IS NULL
                   OR al.content_type = ANY(recall_hybrid.p_content_types))
              AND (_as_of_ts IS NULL
                   OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
              AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY 2 DESC
            LIMIT _fetch_k_bm25;

            EXECUTE 'SET LOCAL statement_timeout = 0';

        EXCEPTION WHEN query_canceled THEN
            _bm25_timed_out := TRUE;
            _has_text       := FALSE;
            RAISE NOTICE
                'pgmnemo.recall_hybrid: BM25 signal exceeded %ms budget — degrading to '
                'vector-only recall. Tune pgmnemo.bm25_budget_ms or shorten query_text.',
                _bm25_budget_ms;
        END;
    END IF;

    -- ── Phase 1: vector candidates — executed as a standalone EXECUTE statement ──
    --
    -- FIX (v0.14.1): When LIMIT is a plpgsql local variable, PostgreSQL compiles
    -- the RETURN QUERY block with a generic, parameter-blind plan that does not
    -- know the LIMIT value.  Without a concrete small-limit hint, the cost model
    -- prefers Seq Scan + top-N heapsort over the HNSW index scan, causing 10–1000×
    -- latency regressions on large corpora (confirmed with EXPLAIN on 3000–7440
    -- row corpus: HNSW cost 448 vs SeqScan 413 in generic plan; SeqScan wins
    -- without a concrete LIMIT, but HNSW wins when the planner sees the value).
    --
    -- Embedding _fetch_k_vec as a literal integer in the SQL text (via format())
    -- lets the planner see the concrete value and reliably choose the HNSW index
    -- scan.  The temp table is ON COMMIT DROP; a duplicate-table exception (same
    -- transaction, re-entrant call) is handled by truncating before reuse.

    BEGIN
        CREATE TEMP TABLE _pgmnemo_vc (
            id             BIGINT,
            role           TEXT,
            project_id     INT,
            topic          TEXT,
            lesson_text    TEXT,
            importance     SMALLINT,
            metadata       JSONB,
            commit_sha     TEXT,
            artifact_hash  TEXT,
            verified_at    TIMESTAMPTZ,
            created_at     TIMESTAMPTZ,
            confidence     REAL,
            raw_vec_score  DOUBLE PRECISION
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_vc;
    END;

    IF _has_vec THEN
        EXECUTE format($vec_sql$
            INSERT INTO _pgmnemo_vc
            SELECT
                al.id,
                al.role,        al.project_id, al.topic,      al.lesson_text,
                al.importance,  al.metadata,   al.commit_sha, al.artifact_hash,
                al.verified_at, al.created_at, al.confidence,
                (1.0 - (al.embedding <=> $1))::DOUBLE PRECISION  AS raw_vec_score
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.embedding IS NOT NULL
              AND ($2 OR al.verified_at IS NOT NULL)
              AND ($3 IS NULL OR al.role = $3)
              AND ($4 IS NULL OR al.project_id = $4)
              AND ($5 IS NULL OR al.source_dag_id IS DISTINCT FROM $5)
              AND ($6 IS NULL OR al.content_type = ANY($6))
              AND ($7 IS NULL OR (al.t_valid_from <= $7 AND al.t_valid_to > $7))
              AND ($7 IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY al.embedding <=> $1   -- HNSW index scan (literal LIMIT below)
            LIMIT %s                        -- literal value: planner sees k*4 or ef_search
        $vec_sql$, _fetch_k_vec)
        USING query_embedding, _include_unverified, role_filter, project_id_filter,
              exclude_dag_id, p_content_types, _as_of_ts;
    END IF;
    -- If _has_vec = FALSE: _pgmnemo_vc remains empty; all_candidates UNION ALL
    -- below will only contain rows from _pgmnemo_bm25_work.

    RETURN QUERY
    WITH RECURSIVE
    -- Merge: vector candidates (temp table) LEFT JOIN bm25 results + anti-join UNION ALL
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM _pgmnemo_vc v                            -- temp table (was: vec_candidates CTE)
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        SELECT
            al.id, al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            bw.raw_bm25_score
        FROM _pgmnemo_bm25_work bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE bw.id NOT IN (SELECT id FROM _pgmnemo_vc)
    ),
    -- RRF ranking over bounded candidate set
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC) AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                           AS bm25_rank_sparse
        FROM all_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at, r.confidence,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 vec_weight  * r.raw_vec_score
               + bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    final AS (
        SELECT
            s.id,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.025 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.025 * s.confidence::DOUBLE PRECISION
                  + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0), 1.0))
                  + 0.05 * (CASE
                                WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                                WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                                ELSE 0.0 END)
                )
              + _conf_boost_w * (s.confidence::DOUBLE PRECISION - 0.5)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    final_results AS MATERIALIZED (
        SELECT
            f.id                   AS lesson_id,
            f.final_score          AS score,
            f.v_score              AS vec_score,
            f.b_score              AS bm25_score,
            f.rrf_sparse           AS rrf_score,
            f.role,
            f.project_id,
            f.topic,
            f.lesson_text,
            f.importance,
            f.metadata,
            f.commit_sha,
            f.artifact_hash,
            f.verified_at,
            f.created_at,
            f.confidence::REAL,
            LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence
        FROM final f
        WHERE (p_min_score IS NULL
               OR LEAST(1.0, GREATEST(0.0, f.v_score))::REAL >= p_min_score)
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    )
    -- v0.18.0: _stamp removed — recall_hybrid is now STABLE.
    -- Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM ...)) separately
    -- if you want recency to be tracked.
    SELECT
        fr.lesson_id, fr.score, fr.vec_score, fr.bm25_score, fr.rrf_score,
        fr.role, fr.project_id, fr.topic, fr.lesson_text, fr.importance,
        fr.metadata, fr.commit_sha, fr.artifact_hash, fr.verified_at, fr.created_at,
        fr.confidence, fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

    IF NOT FOUND AND p_min_score IS NULL THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND al.verified_at IS NULL
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % matching lesson(s) are unverified (ingested without commit_sha/artifact_hash) '
                'and excluded by default. SET pgmnemo.include_unverified = ''on'' for this session, '
                'or pass provenance on ingest.',
                _ghost_count;
        END IF;
    END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(query_embedding vector, k integer DEFAULT 10, role_filter text DEFAULT NULL::text, project_id_filter integer DEFAULT NULL::integer, query_text text DEFAULT NULL::text, as_of_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, exclude_dag_id text DEFAULT NULL::text, p_content_types text[] DEFAULT NULL::text[], p_min_score real DEFAULT NULL::real)
 RETURNS TABLE(lesson_id bigint, score double precision, role text, project_id integer, topic text, lesson_text text, importance smallint, metadata jsonb, commit_sha text, artifact_hash text, verified_at timestamp with time zone, created_at timestamp with time zone, vec_score double precision, bm25_score double precision, rrf_score double precision, confidence real, match_confidence real)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _ghost_count        INT;
BEGIN
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT, 2000);
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars. Original: %',
                     _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    _has_vec  := query_embedding IS NOT NULL;
    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _disable_hybrid := FALSE;
    END;

    -- Hybrid path delegates to recall_hybrid (which handles stamping + exclude_dag_id)
    -- P0.2: p_content_types forwarded as the 10th argument of recall_hybrid().
    -- v0.13.0: p_min_score forwarded as the 11th argument of recall_hybrid().
    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60,
            exclude_dag_id, p_content_types, p_min_score  -- pass p_min_score
        ) h;
        RETURN;
    END IF;

    -- Vector-only path (pgmnemo.disable_hybrid = 'true' or no query_text)
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION, 0.05);
    _temporal_boost := GREATEST(0.0, LEAST(20.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION, 1.0)));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));  -- Fix 5: OPT-IN default (was 0.2)
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(_query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', left(trim(_query_text), 200));   -- Fix 4+1
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    candidates AS (
        SELECT
            al.id,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.commit_sha,
            al.artifact_hash,
            al.verified_at,
            al.created_at,
            al.confidence,
            CASE
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery     -- Fix 2: indexed full_text
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL
               OR al.project_id = recall_lessons.project_id_filter)
          AND (recall_lessons.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_lessons.exclude_dag_id)
          AND (al.embedding IS NOT NULL OR _has_text)
          -- P0.2: typed recall pushdown (ix_pgmnemo_content_type_active)
          AND (recall_lessons.p_content_types IS NULL
               OR al.content_type = ANY(recall_lessons.p_content_types))
    ),
    anchors AS (
        SELECT id FROM candidates ORDER BY vec_score DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0  -- Fix 5
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    scored AS (
        SELECT
            c.id, c.role, c.project_id, c.topic, c.lesson_text, c.importance,
            c.metadata, c.commit_sha, c.artifact_hash, c.verified_at, c.created_at,
            c.confidence,
            c.vec_score,
            c.ft_score,
            (c.vec_score + _gamma * GREATEST(0.0, 1.0 - LEAST(
                 EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0), 1.0
             ))) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
             + c.ft_score * 0.1
             AS combined_score
        FROM candidates c
        LEFT JOIN graph_proximity gp ON gp.lesson_id = c.id
    )
    SELECT
        s.id                  AS lesson_id,
        s.combined_score      AS score,
        s.role,
        s.project_id,
        s.topic,
        s.lesson_text,
        s.importance,
        s.metadata,
        s.commit_sha,
        s.artifact_hash,
        s.verified_at,
        s.created_at,
        s.vec_score,
        s.ft_score            AS bm25_score,
        0.0::DOUBLE PRECISION AS rrf_score,
        s.confidence::REAL,
        LEAST(1.0, GREATEST(0.0, s.vec_score))::REAL AS match_confidence
    FROM scored s
    WHERE (p_min_score IS NULL
           OR LEAST(1.0, GREATEST(0.0, s.vec_score))::REAL >= p_min_score)
    ORDER BY s.combined_score DESC, s.id ASC
    LIMIT k;

    IF NOT FOUND THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active AND al.t_valid_to = 'infinity'::TIMESTAMPTZ AND al.verified_at IS NULL
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL
               OR al.project_id = recall_lessons.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % unverified lesson(s) excluded. '
                'SET pgmnemo.include_unverified = ''on'' to include them.',
                _ghost_count;
        END IF;
    END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.undo_consolidate(p_canonical_id bigint DEFAULT NULL::bigint, p_dry_run boolean DEFAULT true)
 RETURNS TABLE(canonical_id bigint, restored_ids bigint[], restored_count integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
    _cluster RECORD;
BEGIN
    FOR _cluster IN
        SELECT
            me.target_id                                                AS cid,
            array_agg(me.source_id          ORDER BY me.source_id)     AS member_ids,
            array_agg(
                COALESCE(me.metadata->>'prior_state', 'candidate')
                ORDER BY me.source_id
            )                                                           AS prior_states,
            count(*)::INT                                               AS sz,
            array_agg(me.id                 ORDER BY me.source_id)     AS edge_ids
        FROM pgmnemo.mem_edge me
        WHERE me.relation_type = 'SUPERSEDED_BY'
          AND me.valid_until   IS NULL
          AND me.metadata @> '{"consolidation":true}'::jsonb
          AND (p_canonical_id IS NULL OR me.target_id = p_canonical_id)
        GROUP BY me.target_id
    LOOP
        IF NOT p_dry_run THEN
            UPDATE pgmnemo.agent_lesson al
            SET state            = u.prior_state,
                is_active        = TRUE,
                state_changed_at = NOW()
            FROM (
                SELECT mid, prior_state
                FROM unnest(_cluster.member_ids, _cluster.prior_states) AS t(mid, prior_state)
            ) u
            WHERE al.id    = u.mid
              AND al.state = 'superseded';

            DELETE FROM pgmnemo.mem_edge
            WHERE id = ANY(_cluster.edge_ids);

            UPDATE pgmnemo.agent_lesson
            SET evidence_count = 1
            WHERE id = _cluster.cid;
        END IF;

        canonical_id    := _cluster.cid;
        restored_ids    := _cluster.member_ids;
        restored_count  := _cluster.sz;
        RETURN NEXT;
    END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.recall_entity(p_entity_key text, p_k integer DEFAULT 10)
 RETURNS TABLE(lesson_id bigint, role text, project_id integer, topic text, lesson_text text, importance smallint, metadata jsonb, content_type text, entity_keys text[], created_at timestamp with time zone)
 LANGUAGE plpgsql
AS $function$
DECLARE
    _include_unverified BOOLEAN;
    _track_recency      BOOLEAN;
BEGIN
    -- GUC: include_unverified (same pattern as recall_hybrid/recall_fast)
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    -- GUC: track_recall_recency
    BEGIN
        _track_recency := COALESCE(
            NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN, TRUE);
    EXCEPTION WHEN OTHERS THEN _track_recency := TRUE;
    END;

    RETURN QUERY
    WITH matched AS (
        SELECT
            al.id,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.content_type,
            -- Extract entity_keys from metadata for convenience
            CASE
                WHEN al.metadata ? 'entity_keys'
                THEN ARRAY(SELECT jsonb_array_elements_text(al.metadata->'entity_keys'))
                ELSE '{}'::TEXT[]
            END AS entity_keys,
            al.created_at
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          -- Entity key containment: metadata->'entity_keys' @> '["key"]'
          AND al.metadata->'entity_keys' @> jsonb_build_array(p_entity_key)
        ORDER BY al.importance DESC, al.created_at DESC
        LIMIT p_k
    ),
    stamped AS (
        UPDATE pgmnemo.agent_lesson al2
        SET
            last_recalled_at = NOW(),
            recall_count     = al2.recall_count + 1
        FROM matched m
        WHERE al2.id = m.id
          AND _track_recency
        RETURNING al2.id
    )
    SELECT
        m.id          AS lesson_id,
        m.role,
        m.project_id,
        m.topic,
        m.lesson_text,
        m.importance,
        m.metadata,
        m.content_type,
        m.entity_keys,
        m.created_at
    FROM matched m
    -- stamped CTE is a side-effect sink; reference to prevent optimiser elision
    LEFT JOIN stamped s ON s.id = m.id
    ORDER BY m.importance DESC, m.created_at DESC;
END;
$function$
;

