-- pgmnemo 0.0.1 — initial scaffold
-- Multi-agent memory substrate for PostgreSQL
-- License: Apache-2.0
-- This file is the minimal scaffold to make CREATE EXTENSION succeed.
-- Real schema + functions land in 0.0.2 via Phase 1 implementation (task 2115).

\echo Use "CREATE EXTENSION pgmnemo" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS pgmnemo;

-- Version function — sanity check after install
CREATE OR REPLACE FUNCTION pgmnemo.version()
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
    SELECT '0.0.1'::text;
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the installed pgmnemo extension version. See https://github.com/pgmnemo/pgmnemo';

-- Placeholder — actual schema follows in 0.0.2
-- DO NOT add tables / functions here. Use a migration update file pgmnemo--0.0.1--0.0.2.sql.
