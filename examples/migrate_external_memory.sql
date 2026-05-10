-- migrate_external_memory.sql
-- Backfill from a mock external memory table (mem.mem_item) into pgmnemo.agent_lesson.
-- Demonstrates field mapping from docs/MIGRATION.md.
-- Run as a superuser or a role with INSERT on pgmnemo.agent_lesson.
-- SPDX-License-Identifier: Apache-2.0

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 0: Create mock source table (simulates a typical agent memory schema)
-- Skip this block if you are migrating a real mem.mem_item table.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS mem;

CREATE TABLE IF NOT EXISTS mem.mem_item (
    id               BIGSERIAL    PRIMARY KEY,
    memory_text      TEXT         NOT NULL,
    layer            TEXT,                  -- e.g. 'security', 'architecture', 'qa'
    agent_role       TEXT         NOT NULL DEFAULT 'developer',
    project          INT,
    run_id           TEXT,                  -- external run identifier (text UUID or int)
    task_id          TEXT,                  -- external task identifier
    ttl_seconds      INT,                   -- retention duration from created_at
    verified         BOOLEAN      NOT NULL DEFAULT FALSE,
    status           TEXT         NOT NULL DEFAULT 'pending',
    priority         INT          NOT NULL DEFAULT 5  CHECK (priority BETWEEN 1 AND 10),
    tags             JSONB,
    git_sha          TEXT,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Insert three representative rows
INSERT INTO mem.mem_item
    (memory_text, layer, agent_role, project, run_id, task_id, ttl_seconds,
     verified, status, priority, tags, git_sha)
VALUES
    (
        'Always validate JWT expiry server-side; client clock skew can be ±5 min.',
        'security', 'developer', 42,
        '1001', '501',
        NULL,                     -- no TTL → lesson survives indefinitely
        TRUE, 'active', 8,
        '{"env": "production", "component": "auth"}',
        'deadbeef01'
    ),
    (
        'Pipeline halts when null rate in column `user_id` exceeds 5%.',
        'data-quality', 'analyst-agent', 42,
        '1002', '502',
        7776000,                  -- 90 days from creation
        FALSE, 'in_review', 6,
        '{"pipeline": "ingest-v2"}',
        NULL                      -- no git provenance → will be ghost unless artifact_hash used
    ),
    (
        'Retry flaky login tests with retry=3 before marking suite as failed.',
        'qa', 'qa-agent', 7,
        '1003', '503',
        NULL,
        TRUE, 'approved', 7,
        '{"suite": "auth-e2e"}',
        'cafebabe02'
    );


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: Relax provenance gate for backfill session
-- Rows without git_sha will become ghost lessons (verified_at IS NULL).
-- After the backfill you can update verified_at selectively (see STEP 4).
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.gate_strict = 'warn';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: Bulk INSERT with field mapping
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO pgmnemo.agent_lesson (
    -- Required fields
    role,
    lesson_text,
    topic,

    -- Optional fields with defaults
    project_id,
    importance,
    metadata,

    -- Provenance
    commit_sha,
    verified_at,

    -- Lifecycle state
    state,

    -- Provenance back-link
    source_run_id,
    source_task_id,

    -- TTL
    expires_at,

    -- Preserve original creation timestamp
    created_at,
    updated_at
)
SELECT
    -- role ← agent_role (direct copy)
    src.agent_role                                          AS role,

    -- lesson_text ← memory_text (direct copy)
    src.memory_text                                         AS lesson_text,

    -- topic ← layer (primary classification)
    COALESCE(src.layer, 'general')                          AS topic,

    -- project_id ← project (INT cast)
    src.project                                             AS project_id,

    -- importance ← priority (0-10 → 1-5 via rounding)
    GREATEST(1, LEAST(5, ROUND(src.priority / 2.0)))::SMALLINT AS importance,

    -- metadata — merge source fields for auditability
    jsonb_build_object(
        'source_system',  'mem.mem_item',
        'original_id',    src.id,
        'original_layer', src.layer,
        'original_status',src.status,
        'original_tags',  src.tags
    )                                                       AS metadata,

    -- commit_sha ← git_sha (direct copy; NULL allowed when artifact_hash set)
    src.git_sha                                             AS commit_sha,

    -- verified_at ← map verified boolean
    -- TRUE with git_sha → set timestamp; FALSE → NULL (ghost lesson)
    CASE
        WHEN src.verified AND src.git_sha IS NOT NULL THEN src.created_at
        ELSE NULL
    END                                                     AS verified_at,

    -- state ← status (vocabulary mapping per MIGRATION.md §1)
    CASE src.status
        WHEN 'pending'     THEN 'draft'
        WHEN 'new'         THEN 'draft'
        WHEN 'in_review'   THEN 'candidate'
        WHEN 'proposed'    THEN 'candidate'
        WHEN 'approved'    THEN 'validated'
        WHEN 'checked'     THEN 'validated'
        WHEN 'active'      THEN 'canonical'
        WHEN 'live'        THEN 'canonical'
        WHEN 'stale'       THEN 'deprecated'
        WHEN 'outdated'    THEN 'deprecated'
        WHEN 'replaced'    THEN 'superseded'
        WHEN 'overridden'  THEN 'superseded'
        WHEN 'deleted'     THEN 'archived'
        WHEN 'inactive'    THEN 'archived'
        WHEN 'rejected'    THEN 'rejected'
        WHEN 'conflict'    THEN 'conflicted'
        ELSE 'candidate'   -- safe default for unmapped values
    END                                                     AS state,

    -- source_run_id ← run_id (BIGINT cast; NULL when source is non-numeric text)
    CASE
        WHEN src.run_id ~ '^\d+$' THEN src.run_id::BIGINT
        ELSE NULL
    END                                                     AS source_run_id,

    -- source_task_id ← task_id (BIGINT cast; NULL when source is non-numeric text)
    CASE
        WHEN src.task_id ~ '^\d+$' THEN src.task_id::BIGINT
        ELSE NULL
    END                                                     AS source_task_id,

    -- expires_at ← created_at + ttl_seconds (NULL when no TTL)
    CASE
        WHEN src.ttl_seconds IS NOT NULL
        THEN src.created_at + (src.ttl_seconds || ' seconds')::INTERVAL
        ELSE NULL
    END                                                     AS expires_at,

    -- Preserve original timestamps
    src.created_at                                          AS created_at,
    src.created_at                                          AS updated_at

FROM mem.mem_item src
-- Skip rows that were already migrated (idempotency guard)
WHERE NOT EXISTS (
    SELECT 1
    FROM pgmnemo.agent_lesson al
    WHERE (al.metadata->>'source_system') = 'mem.mem_item'
      AND (al.metadata->>'original_id')::BIGINT = src.id
);


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: Restore provenance enforcement
-- ─────────────────────────────────────────────────────────────────────────────

SET pgmnemo.gate_strict = 'enforce';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: Evict already-expired lessons imported with a past expires_at
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.evict_expired_lessons() AS evicted_count;


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 5: Verify — recall_lessons() must return migrated rows
--
-- Ghost lessons (verified_at IS NULL) are excluded by default.
-- Enable include_unverified to verify all migrated rows are present.
-- ─────────────────────────────────────────────────────────────────────────────

-- Verify count of migrated rows
SELECT
    state,
    verified_at IS NOT NULL AS is_verified,
    COUNT(*)                AS row_count
FROM pgmnemo.agent_lesson
WHERE (metadata->>'source_system') = 'mem.mem_item'
GROUP BY state, is_verified
ORDER BY state;

-- Recall verified lessons via text search (should return the JWT security row)
SET pgmnemo.include_unverified = 'false';

SELECT
    lesson_id,
    score,
    topic,
    lesson_text,
    state,
    verified_at
FROM pgmnemo.recall_lessons(
    NULL::vector(1024),   -- no embedding (text-only recall)
    10,
    NULL,                 -- all roles
    42,                   -- project_id = 42
    'JWT expiry validation'
);

-- Also confirm ghost lessons are present when unverified recall is on
SET pgmnemo.include_unverified = 'true';

SELECT
    lesson_id,
    score,
    topic,
    lesson_text,
    state,
    verified_at
FROM pgmnemo.recall_lessons(
    NULL::vector(1024),
    10,
    NULL,
    42,
    'null rate pipeline'
);

-- Reset to default
SET pgmnemo.include_unverified = 'false';


-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 6: Optional cleanup — drop mock source table
-- Comment out if migrating a real mem.mem_item table.
-- ─────────────────────────────────────────────────────────────────────────────

-- DROP TABLE IF EXISTS mem.mem_item;
-- DROP SCHEMA IF EXISTS mem;
