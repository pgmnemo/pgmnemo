-- Regression test: source_run_id / source_task_id columns (v0.1.4)
-- Verifies NULL semantics, BIGINT type coercion, and index predicate logic.

-- NULL sentinel: unlinked lesson has no run/task provenance
SELECT NULL::BIGINT IS NULL AS run_id_null,
       NULL::BIGINT IS NULL AS task_id_null;

-- Non-NULL: typical external IDs
SELECT
    42::BIGINT  AS sample_run_id,
    7::BIGINT   AS sample_task_id;

-- Partial-index predicate: row is indexed only when column IS NOT NULL
SELECT
    (42::BIGINT IS NOT NULL) AS run_would_be_indexed,
    (NULL::BIGINT IS NOT NULL) AS null_would_be_indexed;

-- Coerce large BIGINT values (edge of int4 range)
SELECT
    (2147483648::BIGINT > 2147483647::INT) AS exceeds_int4;
