-- pgmnemo 0.16.0 -> 0.16.1
-- Failure-class vocabulary. The rule recognised a token as a failure class only
-- when it contained one of FAIL/ERROR/BUG/... . Measured against 5,730 real
-- failing runs, that missed 59% of them — including the single most common class,
-- whose name contains none of those words, plus EXCEEDED, UNMET and CEILING.
-- Widened to the words failure classes actually use.

CREATE OR REPLACE FUNCTION pgmnemo.extract_entity_keys(p_text text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
STRICT
AS $func$
WITH
-- ── 1. model:<id> ───────────────────────────────────────────────────────────
-- Claude model IDs: claude-{family}-{version}, e.g. claude-sonnet-4-6
-- GPT model IDs: gpt-{version}, e.g. gpt-4o, gpt-4-turbo
-- Ollama: llama-*, mistral-*, gemma-*
model_keys AS (
    SELECT DISTINCT 'model:' || lower(m[1]) AS key
    FROM regexp_matches(
        p_text,
        '\m(claude[-_][a-z0-9][-a-z0-9_.]{2,30}|gpt[-_][a-z0-9][-a-z0-9_.]{1,20}|llama[-_][a-z0-9][-a-z0-9_.]{1,20}|mistral[-_][a-z0-9][-a-z0-9_.]{1,20}|gemma[-_][a-z0-9][-a-z0-9_.]{1,20})\M',
        'gi'
    ) AS m
),

-- ── 2. file:<path> ──────────────────────────────────────────────────────────
-- Paths starting with known prefixes OR ending with known extensions.
-- Must contain at least one slash to distinguish from plain words.
-- 0.16.0-D: exclude one-time artifacts (spec/reports/*, docs/reports/*,
--           *.md reports) — only source code and config files retained.
file_keys AS (
    SELECT DISTINCT 'file:' || m[1] AS key
    FROM regexp_matches(
        p_text,
        '\m((?:apps|src|tests|scripts|extension|alembic|routes|workflows|transactions|adapters|agents)/[a-zA-Z0-9_./-]{2,80}(?:\.[a-z]{1,6})?)\M',
        'g'
    ) AS m
    WHERE m[1] !~ '\.\.$'  -- no trailing ..
      AND m[1] !~ '//$'    -- no double-slash ending
      -- 0.16.0-D: exclude report/spec artifacts — they are one-time references
      AND m[1] !~ '\.md$'  -- no markdown files (reports, READMEs)
),

-- ── 3. failure:<CLASS> ──────────────────────────────────────────────────────
-- UPPER_SNAKE_CASE tokens ≥ 2 segments that look like failure class names.
-- Must appear near failure-context words to avoid matching random constants.
failure_keys AS (
    SELECT DISTINCT 'failure:' || m[1] AS key
    FROM regexp_matches(
        p_text,
        '\m([A-Z][A-Z0-9]+(?:_[A-Z][A-Z0-9]+)+)\M',
        'g'
    ) AS m
    WHERE length(m[1]) >= 6
      AND length(m[1]) <= 40
      -- The token itself MUST suggest a failure/error class
      AND m[1] ~ '(FAIL|ERROR|BUG|CRASH|PANIC|TIMEOUT|DEAD|ZOMBIE|ORPHAN|LEAK|STALE|BROKEN|CORRUPT|ABORT|REJECT|INVALID|MISSING|CONFLICT|DUPLICATE|PHANTOM|OVERFLOW|UNDERFLOW|VIOLATION|OOM|EXCEEDED|CEILING|LIMIT|UNMET|DENIED|REFUSED|FORBIDDEN|UNAUTHORIZED|CANCELLED|CANCELED|SUPERSEDED|STORM|THROTTL|QUOTA|BLOCKED|HANG|STALL|LOST|UNAVAILABLE|UNREACHABLE|RETRY|EXHAUSTED|DEGRADED|SKIPPED|EMPTY|NOT_FOUND|NOTFOUND)'
),

-- ── 4. schema:<qualified> ───────────────────────────────────────────────────
-- Dotted qualified names: schema.object. Deliberately generic — a memory
-- extension must not hardcode one deployment's schema names, or the rule
-- silently does nothing for everyone else. Any lowercase dotted identifier
-- pair qualifies, minus the source-file extensions that also look dotted
-- (those are already covered by the file: category above).
schema_keys AS (
    SELECT DISTINCT 'schema:' || lower(m[1]) AS key
    FROM regexp_matches(
        p_text,
        '\m([a-z_][a-z0-9_]{1,60}\.[a-z_][a-z0-9_]{1,60})\M',
        'gi'
    ) AS m
    -- Filter out function call noise (method-like .word() patterns)
    WHERE m[1] !~ '\(\s*$'
      -- ...and dotted tokens that are really filenames, not schema objects
      AND lower(split_part(m[1], '.', 2)) NOT IN (
          'py','sql','md','ts','js','tsx','jsx','sh','yml','yaml','json','toml',
          'txt','csv','html','css','go','rs','rb','java','c','h','cpp','ini','cfg',
          'lock','log','out','env','xml','conf','png','svg','jpg','gz','zip','com',
          'org','net','io','dev','local'
      )
),

-- ── Combine, sort, deduplicate ──────────────────────────────────────────────
all_keys AS (
    SELECT key FROM model_keys
    UNION
    SELECT key FROM file_keys
    UNION
    SELECT key FROM failure_keys
    UNION
    SELECT key FROM schema_keys
)
SELECT COALESCE(array_agg(key ORDER BY key), '{}'::text[])
FROM all_keys;
$func$;

COMMENT ON FUNCTION pgmnemo.extract_entity_keys(TEXT) IS
    'Extract entity keys (model/file/failure/schema) from lesson text with '
    'deterministic shape rules; no LLM call. 0.16.1 widened the failure-class '
    'vocabulary — the previous word list recognised 41% of real failure tokens.';
