-- pgmnemo upgrade patch: 0.1.3 → 0.1.4 (provenance FKs)
-- Adds run-level provenance columns to pgmnemo.agent_lesson.
-- Closes: https://github.com/pgmnemo/pgmnemo/issues/4
-- SPDX-License-Identifier: Apache-2.0

ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS source_run_id  BIGINT NULL;
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS source_task_id BIGINT NULL;

CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_source_run
    ON pgmnemo.agent_lesson (source_run_id)
    WHERE source_run_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_source_task
    ON pgmnemo.agent_lesson (source_task_id)
    WHERE source_task_id IS NOT NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.source_run_id IS
    'External-system FK; not REFERENCES-constrained (allows extension to be portable across host schemas).';

COMMENT ON COLUMN pgmnemo.agent_lesson.source_task_id IS
    'External-system FK; not REFERENCES-constrained (allows extension to be portable across host schemas).';
