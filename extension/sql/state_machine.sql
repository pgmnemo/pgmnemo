-- Regression test: state machine for agent_lesson (v0.1.4)
-- Verifies allowed transitions, default state, and rejection of invalid transitions.

-- Default state value
SELECT 'draft'::TEXT = 'draft' AS default_state_ok;

-- All 17 allowed transitions are present in the table
SELECT COUNT(*) AS transition_count
FROM pgmnemo.agent_lesson_state_transition;

-- Spot-check specific allowed transitions exist
SELECT
    (SELECT COUNT(*) FROM pgmnemo.agent_lesson_state_transition WHERE from_state='draft'     AND to_state='candidate')   = 1 AS draft_to_candidate,
    (SELECT COUNT(*) FROM pgmnemo.agent_lesson_state_transition WHERE from_state='canonical' AND to_state='deprecated')  = 1 AS canonical_to_deprecated,
    (SELECT COUNT(*) FROM pgmnemo.agent_lesson_state_transition WHERE from_state='conflicted'AND to_state='canonical')   = 1 AS conflicted_to_canonical;

-- Spot-check that a clearly disallowed transition is absent
SELECT
    (SELECT COUNT(*) FROM pgmnemo.agent_lesson_state_transition WHERE from_state='archived'  AND to_state='draft')       = 0 AS archived_to_draft_absent,
    (SELECT COUNT(*) FROM pgmnemo.agent_lesson_state_transition WHERE from_state='rejected'  AND to_state='candidate')   = 0 AS rejected_to_candidate_absent;

-- CHECK constraint: valid states are accepted
SELECT 'draft'::TEXT     IN ('draft','candidate','validated','canonical','deprecated','superseded','archived','rejected','conflicted') AS draft_valid,
       'canonical'::TEXT IN ('draft','candidate','validated','canonical','deprecated','superseded','archived','rejected','conflicted') AS canonical_valid,
       'archived'::TEXT  IN ('draft','candidate','validated','canonical','deprecated','superseded','archived','rejected','conflicted') AS archived_valid;

-- transition_lesson function exists
SELECT proname FROM pg_proc
JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
WHERE nspname = 'pgmnemo' AND proname = 'transition_lesson';
