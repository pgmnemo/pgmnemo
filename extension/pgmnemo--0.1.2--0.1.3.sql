-- pgmnemo upgrade: 0.1.2 → 0.1.3
-- D-RMD-V013: add verifier_role TEXT column to mem.agent_lesson
-- Source: RESEARCH_PROVENANCE_GATE.md §5 HIGH-priority; Insight INS-007
-- SPDX-License-Identifier: Apache-2.0
--
-- Changes:
--   1. ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS verifier_role TEXT
--      NULL = unverified or unknown; non-NULL = role that verified the lesson.
--   No new GUCs. No function changes. Backward compatible.

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS verifier_role TEXT;

COMMENT ON COLUMN pgmnemo.agent_lesson.verifier_role IS
    'Role that verified the lesson (e.g. PI, automated, founder, peer). NULL = unverified or unknown.';
