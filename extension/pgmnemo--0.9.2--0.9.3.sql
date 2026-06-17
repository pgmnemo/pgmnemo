-- pgmnemo--0.9.2--0.9.3.sql
-- Incremental upgrade: pgmnemo 0.9.2 → 0.9.3
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: D1 — Base-rate-adjusted reinforce() deltas + GUC-configurable
--
-- PROBLEM: OL-260605 validation (task 9091) showed shipped deltas (+0.10/-0.15)
--   give r_pb = -0.051 (confidence does NOT predict success).
--   At 83.5% base success rate, raw +0.10 saturates toward ceiling for most lessons.
--   Base-rate-adjusted deltas (+0.02/-0.12) give r_pb = +0.107..+0.124 — the ONLY
--   positive signal observed. Small positive delta preserves headroom near the ceiling;
--   larger negative delta keeps failure signal dominant below 0.5.
--
-- FIX:
--   1. Change default deltas:
--        success: +0.10 → +0.02
--        failure: -0.15 → -0.12
--   2. Make GUC-configurable:
--        pgmnemo.reinforce_success_delta (default 0.02, range [0.0, 0.5])
--        pgmnemo.reinforce_fail_delta    (default 0.12, range [0.0, 0.5], applied negative)
--   Both clamp to [0.0, 0.5]; applied via GREATEST/LEAST per existing pattern.
--
-- ITEMS:
--   #1  reinforce(BIGINT, TEXT)   — scalar form: add GUC reads, use new deltas
--   #2  reinforce(BIGINT[], TEXT) — batch form:  add GUC reads, use new deltas
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.3';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.3'" to load this file. \quit

-- ══════════════════════════════════════════════════════════════════════════════
-- #1: reinforce(BIGINT, TEXT) — scalar form (D1)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Changes vs 0.9.2:
--   +  DECLARE: _success_delta DOUBLE PRECISION, _fail_delta DOUBLE PRECISION
--   +  GUC read block for pgmnemo.reinforce_success_delta (default 0.02, clamp [0.0, 0.5])
--   +  GUC read block for pgmnemo.reinforce_fail_delta    (default 0.12, clamp [0.0, 0.5])
--   ~  success branch: hardcoded 0.10 → _success_delta::REAL
--   ~  failure branch: hardcoded 0.15 → _fail_delta::REAL
--   +  COMMENT updated.
--
-- Signature unchanged — CREATE OR REPLACE is safe, no DROP needed.
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _row            pgmnemo.agent_lesson%ROWTYPE;
    _new_conf       REAL;
    _success_delta  DOUBLE PRECISION;
    _fail_delta     DOUBLE PRECISION;
BEGIN
    -- D1: read base-rate-adjusted delta GUCs
    -- pgmnemo.reinforce_success_delta default 0.02, clamp [0.0, 0.5]
    BEGIN
        _success_delta := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
            0.02)));
    EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
    END;

    -- pgmnemo.reinforce_fail_delta default 0.12, clamp [0.0, 0.5], applied negative
    BEGIN
        _fail_delta := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
            0.12)));
    EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
    END;

    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    CASE p_outcome
        WHEN 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                success_count   = _row.success_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                fail_count      = _row.fail_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            _new_conf := _row.confidence;

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    RETURN _new_conf;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'Outcome-learning update (v0.9.3 D1): adjusts confidence for lesson p_lesson_id. '
    'Exact case required: ''success'' | ''failure'' | ''neutral''. '
    'success: confidence += pgmnemo.reinforce_success_delta (default 0.02, clamped to 1.0); '
    '         increments success_count; sets last_outcome/at. '
    'failure: confidence -= pgmnemo.reinforce_fail_delta    (default 0.12, clamped to 0.0); '
    '         increments fail_count; sets last_outcome/at. '
    'neutral: no-op -- returns current confidence without any write. '
    'Unknown outcome string: RAISE EXCEPTION. '
    'Row-locked (SELECT ... FOR UPDATE) for concurrent-safe update on hot lessons. '
    'GUCs: pgmnemo.reinforce_success_delta [0.0,0.5] default 0.02; '
    '      pgmnemo.reinforce_fail_delta    [0.0,0.5] default 0.12 (applied negative). '
    'Rationale: OL-260605 base-rate 83.5% -- raw +0.10 saturates ceiling; '
    '           +0.02/-0.12 gives r_pb = +0.107..+0.124 vs -0.051 for old defaults.';

-- ══════════════════════════════════════════════════════════════════════════════
-- #2: reinforce(BIGINT[], TEXT) — batch form (D1)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Changes vs 0.9.2:
--   +  DECLARE: _success_delta DOUBLE PRECISION, _fail_delta DOUBLE PRECISION
--   +  GUC read blocks before loop (read once, apply N times consistently)
--   ~  success branch: hardcoded 0.10 → _success_delta::REAL
--   ~  failure branch: hardcoded 0.15 → _fail_delta::REAL
--   +  COMMENT updated.
--
-- Signature unchanged — CREATE OR REPLACE is safe, no DROP needed.
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_ids BIGINT[],
    p_outcome    TEXT
)
RETURNS INT
LANGUAGE plpgsql
AS $func$
DECLARE
    _id             BIGINT;
    _row            pgmnemo.agent_lesson%ROWTYPE;
    _new_conf       REAL;
    _updated        INT := 0;
    _success_delta  DOUBLE PRECISION;
    _fail_delta     DOUBLE PRECISION;
BEGIN
    -- Validate outcome up-front so the caller gets a clear error on bad input.
    IF p_outcome NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
            p_outcome;
    END IF;

    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    -- D1: read base-rate-adjusted delta GUCs once before iterating
    -- pgmnemo.reinforce_success_delta default 0.02, clamp [0.001, 0.5]
    BEGIN
        _success_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
            0.02)));
    EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
    END;

    -- pgmnemo.reinforce_fail_delta default 0.12, clamp [0.001, 0.5], applied negative
    BEGIN
        _fail_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
            0.12)));
    EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
    END;

    FOREACH _id IN ARRAY p_lesson_ids LOOP
        SELECT * INTO _row
        FROM pgmnemo.agent_lesson
        WHERE id = _id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- skip missing; no RAISE (bitemporal supersession / TTL normal)
        END IF;

        CASE p_outcome
            WHEN 'success' THEN
                _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    success_count   = _row.success_count + 1,
                    last_outcome    = 'success',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'failure' THEN
                _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    fail_count      = _row.fail_count + 1,
                    last_outcome    = 'failure',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'neutral' THEN
                NULL;  -- no-op; does not increment _updated
        END CASE;
    END LOOP;

    RETURN _updated;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT[], TEXT) IS
    'Batch confidence update v0.9.3 D1. Iterates p_lesson_ids; skips missing IDs silently (no RAISE). '
    'Returns count of rows actually updated (neutral outcome does not increment count). '
    'Unknown outcome string raises RAISE EXCEPTION (caller programming error). '
    'Empty or NULL array returns 0. '
    'success: +pgmnemo.reinforce_success_delta (default 0.02, clamped to 1.0), '
    'failure: -pgmnemo.reinforce_fail_delta    (default 0.12, clamped to 0.0), '
    'neutral: no-op. '
    'GUCs read once before the loop -- consistent deltas across all IDs in one batch call. '
    'Scalar form reinforce(BIGINT, TEXT) updated identically. '
    'Rationale: OL-260605 base-rate 83.5% -- raw +0.10 saturates ceiling; '
    '           +0.02/-0.12 gives r_pb = +0.107..+0.124 vs -0.051 for old defaults.';
