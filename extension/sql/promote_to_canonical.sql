-- SPDX-License-Identifier: Apache-2.0
-- RESTORE-C3-PROMOTE: TL-gated canonicalization promotion (Paper C-3, pure-SQL)
-- Implements: promote_to_canonical() with tech_lead role gate + audit trail

-- ─────────────────────────────────────────────────────────────────────────────
-- GUC: pgmnemo.caller_role
-- Actor identity for promote_to_canonical().  Set per-session before calling.
--   SET pgmnemo.caller_role = 'tech_lead';
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM set_config('pgmnemo.caller_role', '', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Audit table: mem_state_transition
-- Records every promotion attempt that passes the role gate.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgmnemo.mem_state_transition (
    id               BIGSERIAL    PRIMARY KEY,
    lesson_id        BIGINT       NOT NULL REFERENCES pgmnemo.agent_lesson(id),
    from_state       TEXT         NOT NULL,
    to_state         TEXT         NOT NULL,
    actor_role       TEXT         NOT NULL,
    justification    TEXT,
    transitioned_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE pgmnemo.mem_state_transition IS
    'Audit log of TL-gated state promotions via promote_to_canonical(). '
    'Each row is an immutable record of a validated→canonical transition.';

CREATE INDEX IF NOT EXISTS mem_state_transition_lesson_id_idx
    ON pgmnemo.mem_state_transition (lesson_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- Function: pgmnemo.promote_to_canonical
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.promote_to_canonical(
    lesson_id     BIGINT,
    actor_role    TEXT    DEFAULT NULL,  -- explicit override; falls back to GUC
    justification TEXT    DEFAULT NULL
)
RETURNS pgmnemo.agent_lesson
LANGUAGE plpgsql
AS $$
DECLARE
    _role   TEXT;
    _lesson pgmnemo.agent_lesson;
BEGIN
    -- Resolve actor identity: explicit param > GUC > empty
    _role := COALESCE(
        NULLIF(actor_role, ''),
        NULLIF(current_setting('pgmnemo.caller_role', TRUE), ''),
        ''
    );

    -- Role gate: only tech_lead may promote to canonical (Paper C-3)
    IF _role IS DISTINCT FROM 'tech_lead' THEN
        RAISE EXCEPTION
            'promote_to_canonical: actor_role must be ''tech_lead'', got ''%''',
            _role
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Lock and fetch lesson
    SELECT * INTO _lesson
    FROM pgmnemo.agent_lesson
    WHERE id = lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'promote_to_canonical: lesson % not found', lesson_id;
    END IF;

    -- L2 (validated) → L3 (canonical) only
    IF _lesson.state <> 'validated' THEN
        RAISE EXCEPTION
            'promote_to_canonical: lesson % is in state ''%'', expected ''validated'' (L2)',
            lesson_id, _lesson.state
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Advance state
    UPDATE pgmnemo.agent_lesson
    SET state            = 'canonical',
        state_changed_at = NOW()
    WHERE id = lesson_id
    RETURNING * INTO _lesson;

    -- Audit trail
    INSERT INTO pgmnemo.mem_state_transition
        (lesson_id, from_state, to_state, actor_role, justification)
    VALUES
        (lesson_id, 'validated', 'canonical', _role, justification);

    RETURN _lesson;
END;
$$;

COMMENT ON FUNCTION pgmnemo.promote_to_canonical(BIGINT, TEXT, TEXT) IS
    'TL-gated L2→L3 promotion. Raises insufficient_privilege if actor_role <> ''tech_lead''. '
    'Writes audit row to mem_state_transition. Actor resolved from param or pgmnemo.caller_role GUC.';
