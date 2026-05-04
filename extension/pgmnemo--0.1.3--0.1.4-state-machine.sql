-- pgmnemo upgrade patch: 0.1.3 → 0.1.4 (state machine)
-- Adds lifecycle state machine to pgmnemo.agent_lesson.
-- Closes: https://github.com/pgmnemo/pgmnemo/issues/3
-- SPDX-License-Identifier: Apache-2.0

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft','candidate','validated','canonical','deprecated','superseded','archived','rejected','conflicted'));

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS state_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE TABLE IF NOT EXISTS pgmnemo.agent_lesson_state_transition (
    from_state TEXT NOT NULL,
    to_state   TEXT NOT NULL,
    PRIMARY KEY (from_state, to_state)
);

INSERT INTO pgmnemo.agent_lesson_state_transition (from_state, to_state) VALUES
    ('draft',      'candidate'),
    ('draft',      'rejected'),
    ('candidate',  'validated'),
    ('candidate',  'rejected'),
    ('candidate',  'conflicted'),
    ('validated',  'canonical'),
    ('validated',  'rejected'),
    ('canonical',  'deprecated'),
    ('canonical',  'superseded'),
    ('canonical',  'archived'),
    ('canonical',  'conflicted'),
    ('deprecated', 'archived'),
    ('deprecated', 'canonical'),
    ('superseded', 'archived'),
    ('conflicted', 'canonical'),
    ('conflicted', 'rejected'),
    ('conflicted', 'archived')
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pgmnemo.transition_lesson(lesson_id BIGINT, new_state TEXT)
RETURNS pgmnemo.agent_lesson
LANGUAGE plpgsql
AS $$
DECLARE
    _lesson pgmnemo.agent_lesson;
BEGIN
    SELECT * INTO _lesson
    FROM pgmnemo.agent_lesson
    WHERE id = lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'lesson % not found', lesson_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pgmnemo.agent_lesson_state_transition
        WHERE from_state = _lesson.state AND to_state = new_state
    ) THEN
        RAISE EXCEPTION 'invalid state transition: % → %', _lesson.state, new_state;
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET state            = new_state,
        state_changed_at = NOW()
    WHERE id = lesson_id
    RETURNING * INTO _lesson;

    RETURN _lesson;
END;
$$;

COMMENT ON TABLE pgmnemo.agent_lesson_state_transition IS
    'Allowed state transitions for pgmnemo.agent_lesson.state lifecycle.';

COMMENT ON FUNCTION pgmnemo.transition_lesson(BIGINT, TEXT) IS
    'Advance a lesson to new_state; raises if the transition is not permitted.';
