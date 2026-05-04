-- Regression: version() returns the live extversion from pg_catalog
SELECT pgmnemo.version() = (SELECT extversion FROM pg_extension WHERE extname = 'pgmnemo') AS version_matches_catalog;

-- Regression: extension namespace is 'pgmnemo' (control schema= directive respected)
SELECT pg_extension.extnamespace::regnamespace::text = 'pgmnemo' AS schema_is_pgmnemo
FROM pg_extension
WHERE extname = 'pgmnemo';
