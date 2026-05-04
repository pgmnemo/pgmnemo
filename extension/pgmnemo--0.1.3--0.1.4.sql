-- pgmnemo upgrade: 0.1.3 → 0.1.4
-- Bundles three feature PRs:
--   #3 State machine — lifecycle state + allowed-transition table + transition_lesson()
--   #4 Provenance FKs — source_run_id / source_task_id columns + partial indexes
--   #5 TTL — expires_at column + evict_expired_lessons() helper
-- Also fixes: version() now reads extversion from pg_catalog dynamically (closes #1)
-- SPDX-License-Identifier: Apache-2.0

-- ─────────────────────────────────────────────────────────────────
-- Fix #1: version() dynamic pg_catalog lookup
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgmnemo.version()
    RETURNS TEXT
    LANGUAGE SQL
    STABLE
    PARALLEL SAFE
AS $$
    SELECT extversion FROM pg_extension WHERE extname = 'pgmnemo';
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the currently-installed pgmnemo version by querying pg_catalog.pg_extension — always accurate after ALTER EXTENSION UPDATE.';

-- ─────────────────────────────────────────────────────────────────
-- Feature #3: State machine for agent_lesson
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft','candidate','validated','canonical','deprecated','superseded','archived','rejected','conflicted'));

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN state_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE TABLE pgmnemo.agent_lesson_state_transition (
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
    ('conflicted', 'archived');

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

-- ─────────────────────────────────────────────────────────────────
-- Feature #4: Provenance FKs — source_run_id / source_task_id
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN source_run_id  BIGINT NULL;
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN source_task_id BIGINT NULL;

CREATE INDEX ix_pgmnemo_lesson_source_run
    ON pgmnemo.agent_lesson (source_run_id)
    WHERE source_run_id IS NOT NULL;

CREATE INDEX ix_pgmnemo_lesson_source_task
    ON pgmnemo.agent_lesson (source_task_id)
    WHERE source_task_id IS NOT NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.source_run_id IS
    'External-system FK; not REFERENCES-constrained (allows extension to be portable across host schemas).';

COMMENT ON COLUMN pgmnemo.agent_lesson.source_task_id IS
    'External-system FK; not REFERENCES-constrained (allows extension to be portable across host schemas).';

-- ─────────────────────────────────────────────────────────────────
-- Feature #5: TTL — expires_at + evict_expired_lessons()
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.expires_at IS
    'Optional hard expiry. NULL = never expires. Rows with expires_at < NOW() are considered stale and are removed by pgmnemo.evict_expired_lessons().';

CREATE INDEX IF NOT EXISTS ix_pgmnemo_agent_lesson_expires
    ON pgmnemo.agent_lesson (expires_at)
    WHERE expires_at IS NOT NULL;

CREATE OR REPLACE FUNCTION pgmnemo.evict_expired_lessons()
    RETURNS INT
    LANGUAGE plpgsql
AS $$
DECLARE
    evicted INT;
BEGIN
    WITH deleted AS (
        DELETE FROM pgmnemo.agent_lesson
        WHERE expires_at IS NOT NULL
          AND expires_at < NOW()
        RETURNING 1
    )
    SELECT COUNT(*) INTO evicted FROM deleted;
    RETURN COALESCE(evicted, 0);
END;
$$;

COMMENT ON FUNCTION pgmnemo.evict_expired_lessons() IS
    'Deletes all lessons whose expires_at is non-NULL and in the past. Returns the number of rows removed. Safe to call frequently; the partial index keeps the scan cheap.';
