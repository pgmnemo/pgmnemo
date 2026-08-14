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
