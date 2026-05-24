-- role_no_ambiguity.sql
-- pg_regress test: regression guard for v0.6.3 R1 AmbiguousColumn fix.
-- Verifies that recall_lessons() and recall_hybrid() return the correct
-- role column value without psycopg2.errors.AmbiguousColumn or PL/pgSQL error.
-- Root cause fixed: #variable_conflict use_column in both function bodies.

SET client_min_messages = 'warning';
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

-- Seed one lesson with a known role value
INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, embedding,
     commit_sha, verified_at)
VALUES
    ('role_v063_test', 1,
     'role_disambiguation_test',
     'Regression guard: role column must be returned without AmbiguousColumn error.',
     3,
     ('[' || repeat('0.001,', 1023) || '0.001]')::vector,
     'role_test_sha_v063',
     NOW());

-- Test 1: recall_lessons returns correct role column value
SELECT role = 'role_v063_test' AS role_matches_recall_lessons
FROM pgmnemo.recall_lessons(
    ('[' || repeat('0.001,', 1023) || '0.001]')::vector,
    1,
    'role_v063_test',
    1
)
LIMIT 1;

-- Test 2: recall_hybrid returns correct role column value
SELECT role = 'role_v063_test' AS role_matches_recall_hybrid
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.001,', 1023) || '0.001]')::vector,
    'role disambiguation regression test',
    1,
    'role_v063_test',
    1
)
LIMIT 1;

-- Cleanup
DELETE FROM pgmnemo.agent_lesson
WHERE role = 'role_v063_test' AND commit_sha = 'role_test_sha_v063';
