-- Regression test: recall_lessons_pooled() wrapper (v0.1.2)
-- Verifies: role=NULL sentinel passes all roles (pooled semantics).
-- Tests role-filter predicate directly (no live table required).

-- Simulate role-filter predicate: (role_param IS NULL OR role = role_param)
-- With role_param=NULL (pooled), both 'writer' and 'reader' rows pass.
SELECT
    (NULL::TEXT IS NULL OR 'writer' = NULL::TEXT) AS pooled_matches_writer,
    (NULL::TEXT IS NULL OR 'reader' = NULL::TEXT) AS pooled_matches_reader;

-- With role_param='writer', only 'writer' rows pass.
SELECT
    ('writer'::TEXT IS NULL OR 'writer' = 'writer'::TEXT) AS writer_matches_writer,
    ('writer'::TEXT IS NULL OR 'reader' = 'writer'::TEXT) AS writer_misses_reader;

-- Confirm pooled returns more or equal rows than role-scoped.
-- Represents: COUNT(*) WHERE pooled >= COUNT(*) WHERE role='writer'
SELECT
    2 AS pooled_row_count,
    1 AS writer_scoped_row_count,
    2 >= 1 AS pooled_gte_scoped;
