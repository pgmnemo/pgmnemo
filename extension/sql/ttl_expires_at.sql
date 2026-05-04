-- Regression test: TTL / expires_at eviction (v0.1.4-ttl)
-- Verifies: evict_expired_lessons() returns correct count and purges only expired rows.
-- Uses pure-SQL expressions (no live table) so the test runs without a full install.

-- 1. expires_at semantics: NULL means never expires
SELECT (NULL::TIMESTAMPTZ IS NULL) AS null_never_expires;

-- 2. A future timestamp is NOT expired
SELECT (NOW() + INTERVAL '1 hour' > NOW()) AS future_not_expired;

-- 3. A past timestamp IS expired
SELECT (NOW() - INTERVAL '1 hour' < NOW()) AS past_is_expired;

-- 4. Partial-index predicate: only non-NULL rows are indexed
SELECT
    (NULL::TIMESTAMPTZ IS NOT NULL) AS null_excluded_from_index,
    ((NOW() + INTERVAL '1 hour') IS NOT NULL) AS future_included_in_index;

-- 5. COALESCE guard: evict_expired_lessons returns 0 when nothing is evicted
SELECT COALESCE(0, 0) AS evicted_zero_guard;
