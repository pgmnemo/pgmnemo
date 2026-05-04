-- pgmnemo upgrade: 0.1.3 → 0.1.4-ttl
-- Adds TTL / expires_at column to agent_lesson plus eviction helper.
-- Closes: https://github.com/pgmnemo/pgmnemo/issues/5
-- SPDX-License-Identifier: Apache-2.0

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
