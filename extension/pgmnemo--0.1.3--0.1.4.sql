-- pgmnemo upgrade: 0.1.3 → 0.1.4
-- Fix: version() now reads extversion from pg_catalog dynamically instead of
--      returning a hard-coded string that goes stale after ALTER EXTENSION UPDATE.
-- Closes: https://github.com/pgmnemo/pgmnemo/issues/1
-- SPDX-License-Identifier: Apache-2.0

CREATE OR REPLACE FUNCTION pgmnemo.version()
    RETURNS TEXT
    LANGUAGE SQL
    STABLE
    PARALLEL SAFE
AS $$
    SELECT extversion FROM pg_extension WHERE extname = 'pgmnemo';
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the currently-installed pgmnemo version by querying pg_catalog.pg_extension — always accurate after ALTER EXTENSION UPDATE.';
