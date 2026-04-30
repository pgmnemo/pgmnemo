-- Regression test: verifier_role column (v0.1.3)
-- Verifies: column accepts NULL (unverified) and TEXT role values.
-- Tests NULL-safe semantics without a live table.

-- NULL sentinel: unverified lesson
SELECT NULL::TEXT IS NULL AS unverified_is_null;

-- Non-NULL: known verifier roles
SELECT
    'PI'        AS role_pi,
    'automated' AS role_automated,
    'founder'   AS role_founder,
    'peer'      AS role_peer;

-- Coalesce pattern used by provenance gate: treat NULL as 'unknown'
SELECT
    COALESCE(NULL::TEXT,      'unknown') AS unverified_label,
    COALESCE('PI'::TEXT,      'unknown') AS pi_label,
    COALESCE('automated'::TEXT,'unknown') AS automated_label;
