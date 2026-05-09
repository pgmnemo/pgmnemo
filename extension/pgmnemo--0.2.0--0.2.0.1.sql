-- pgmnemo hotfix: 0.2.0 → 0.2.0.1
-- PGMNEMO-HOTFIX-3: All upgrade DDL made idempotent (ADD COLUMN IF NOT EXISTS,
-- CREATE INDEX IF NOT EXISTS) in pgmnemo--0.1.4--0.2.0*.sql scripts.
-- This script is a no-op version bump; the idempotency fix is in the 0.1.4→0.2.0 scripts.
-- SPDX-License-Identifier: Apache-2.0

-- Ensure the version function returns the updated extversion.
CREATE OR REPLACE FUNCTION pgmnemo.version()
    RETURNS TEXT
    LANGUAGE SQL
    STABLE
    PARALLEL SAFE
AS $$
    SELECT extversion FROM pg_extension WHERE extname = 'pgmnemo';
$$;
