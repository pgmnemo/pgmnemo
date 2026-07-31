-- pgmnemo upgrade: 0.15.1 → 0.16.0
-- SPDX-License-Identifier: Apache-2.0
--
-- 0.16.0 — A: extract_entity_keys(text) → text[]
--           B: ingest() hooks entity_keys into metadata
--
-- A rationale:
--   Live corpus audit (2026-07-31, agency_v3, 5 887 active lessons) found 127
--   rows with structural entity keys (metadata ? 'entity_key' OR 'canonical_name'),
--   of which 81 are the single bucket "project:agency" and the remaining 46 have
--   one record each.  The metadata-based entity layer has structure but no density.
--
--   extract_entity_keys() applies deterministic regex heuristics to lesson_text
--   itself — the same pattern used by classify_content_type() — to surface entity
--   keys that are implicit in the text but were never written to metadata:
--
--     project:<slug>           — "project:agency", "project:pgmnemo"
--     model:<id>               — "model:claude-sonnet-4-6", "model:gpt-4o"
--     file:<path>              — "file:apps/v3-next/routes/tasks.py"
--     failure:<CLASS>          — "failure:PHANTOM_DONE", "failure:OOM_KILL"
--     schema:<qualified>       — "schema:pgmnemo.agent_lesson", "schema:agency_v3.task"
--
--   A dry-run pass over the corpus will determine if the text-extracted keys
--   reach density thresholds (≥70% non-project:agency keys, or ≤30% singletons)
--   sufficient to justify building a recall_entity() read path.
--
-- B rationale:
--   ingest() is extended to auto-populate metadata->'entity_keys' with the
--   output of extract_entity_keys(lesson_text).  This is strictly additive:
--   existing metadata keys are preserved, and no existing behavior changes.
--   The entity_keys array is stored for future read-side use only.
-- =============================================================================


-- =============================================================================
-- A  extract_entity_keys(p_text text) → text[]
-- =============================================================================
-- Deterministic keyword/regex entity-key extractor.  No LLM, no external calls.
-- Returns a sorted, deduplicated array of entity keys found in the text.
-- Returns empty array (not NULL) when no keys are found.
--
-- Key forms:
--   project:<slug>     — matches "project:X" or "project X" context patterns
--   model:<id>         — Claude/GPT/Ollama model identifiers
--   file:<path>        — file paths (apps/..., *.py, *.sql, etc.)
--   failure:<CLASS>    — UPPER_SNAKE_CASE failure class names
--   schema:<qualified> — dotted qualified names (pgmnemo.*, agency_v3.*, etc.)
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.extract_entity_keys(p_text text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
STRICT
AS $func$
WITH
-- ── 1. project:<slug> ───────────────────────────────────────────────────────
-- Matches explicit "project:slug" tokens and "project <word>" in context.
project_keys AS (
    SELECT DISTINCT 'project:' || lower(m[1]) AS key
    FROM regexp_matches(p_text, '\mproject[:\s]([a-z][a-z0-9_-]{1,40})\M', 'gi') AS m
    WHERE lower(m[1]) NOT IN (
        -- Filter out noise words that follow "project" in natural text
        'id', 'the', 'for', 'has', 'was', 'are', 'its', 'with',
        'that', 'this', 'from', 'into', 'will', 'can', 'may',
        'level', 'scope', 'plan', 'context', 'status', 'docs',
        'directory', 'structure', 'management', 'requirements',
        'instructions', 'specific', 'related', 'based', 'wide'
    )
),

-- ── 2. model:<id> ───────────────────────────────────────────────────────────
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

-- ── 3. file:<path> ──────────────────────────────────────────────────────────
-- Paths starting with known prefixes OR ending with known extensions.
-- Must contain at least one slash to distinguish from plain words.
file_keys AS (
    SELECT DISTINCT 'file:' || m[1] AS key
    FROM regexp_matches(
        p_text,
        '\m((?:apps|src|tests|scripts|extension|alembic|routes|workflows|transactions|adapters|agents|spec|docs|web)/[a-zA-Z0-9_./-]{2,80}(?:\.[a-z]{1,6})?)\M',
        'g'
    ) AS m
    WHERE m[1] !~ '\.\.$'  -- no trailing ..
      AND m[1] !~ '//$'    -- no double-slash ending
),

-- ── 4. failure:<CLASS> ──────────────────────────────────────────────────────
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
      AND m[1] ~ '(FAIL|ERROR|BUG|CRASH|PANIC|TIMEOUT|DEAD|ZOMBIE|ORPHAN|LEAK|STALE|BROKEN|CORRUPT|ABORT|REJECT|INVALID|MISSING|CONFLICT|DUPLICATE|PHANTOM|OVERFLOW|UNDERFLOW|VIOLATION|OOM)'
),

-- ── 5. schema:<qualified> ───────────────────────────────────────────────────
-- Dotted qualified names: schema.object or db.table patterns.
-- Must match known schema/db prefixes to avoid false positives.
schema_keys AS (
    SELECT DISTINCT 'schema:' || lower(m[1]) AS key
    FROM regexp_matches(
        p_text,
        '\m((?:pgmnemo|agency_v3|execas|public|pg_catalog)\.[a-z_][a-z0-9_]{1,60})\M',
        'gi'
    ) AS m
    -- Filter out function call noise (method-like .word() patterns)
    WHERE m[1] !~ '\(\s*$'
),

-- ── Combine, sort, deduplicate ──────────────────────────────────────────────
all_keys AS (
    SELECT key FROM project_keys
    UNION
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

COMMENT ON FUNCTION pgmnemo.extract_entity_keys(text) IS
    'Deterministic regex entity-key extractor (v0.16.0). No LLM. '
    'Returns: sorted, deduplicated text[] of entity keys found in lesson_text. '
    'Key forms: project:<slug>, model:<id>, file:<path>, failure:<CLASS>, schema:<qualified>. '
    'IMMUTABLE + STRICT: NULL input → NULL output; result is purely a function of the text. '
    'Used by ingest() to auto-populate metadata->''entity_keys''. '
    'Density gate: if dry-run shows >=70%% non-project:agency keys AND <=30%% singleton keys, '
    'entity layer is viable for recall_entity().';


-- =============================================================================
-- B  ingest() — hook entity_keys into metadata (v0.16.0)
-- =============================================================================
-- Strategy:
--   • CREATE OR REPLACE the 10-param signature from 0.14.0 — same parameter list,
--     no DROP needed since the signature is identical.
--   • Auto-populates metadata->'entity_keys' using extract_entity_keys(p_lesson_text).
--   • Existing callers are backward compatible — the parameter list is identical.
--   • The entity_keys array is stored in metadata for future read-side use only.
--   • All existing quality gates (F1, F2, F3) are preserved unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.ingest(
    p_role           TEXT,
    p_project_id     INT,
    p_topic          TEXT,
    p_lesson_text    TEXT,
    p_importance     SMALLINT     DEFAULT 3,
    p_embedding      vector(1024) DEFAULT NULL,
    p_commit_sha     TEXT         DEFAULT NULL,
    p_artifact_hash  TEXT         DEFAULT NULL,
    p_metadata       JSONB        DEFAULT '{}'::jsonb,
    p_content_type   TEXT         DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql AS $func$
DECLARE
    new_id                  BIGINT;
    _content_hash           TEXT;
    _prior_count            INT;
    _dedup_id               BIGINT;
    _dedup_sim              DOUBLE PRECISION;
    _tokens                 TEXT[];
    _token                  TEXT;
    _token_counts           JSONB;
    _max_freq               INT;
    _total_tokens           INT;
    _trimmed_text           TEXT;
    _effective_content_type TEXT;
    _effective_metadata     JSONB;
    _entity_keys            TEXT[];
BEGIN
    -- F1: minimum length guard
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) < 20 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars)';
    END IF;

    -- F2: token-frequency repetition guard
    _trimmed_text := trim(p_lesson_text);
    _tokens := regexp_split_to_array(
        regexp_replace(_trimmed_text, '\s+', ' ', 'g'), ' ');
    _total_tokens := array_length(_tokens, 1);

    IF _total_tokens > 0 THEN
        _token_counts := '{}'::JSONB;
        FOREACH _token IN ARRAY _tokens LOOP
            _token_counts := jsonb_set(
                _token_counts,
                ARRAY[_token],
                to_jsonb(COALESCE((_token_counts->>_token)::INT, 0) + 1)
            );
        END LOOP;

        SELECT MAX(value::INT)
        INTO _max_freq
        FROM jsonb_each_text(_token_counts);

        IF _max_freq::DOUBLE PRECISION / _total_tokens::DOUBLE PRECISION > 0.8 THEN
            RAISE EXCEPTION 'pgmnemo.ingest: lesson_text appears to be repetitive content';
        END IF;
    END IF;

    -- Embedding dimension guard
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch -- expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- F3: near-duplicate embedding guard
    IF p_embedding IS NOT NULL THEN
        SELECT id, (1.0 - (embedding <=> p_embedding))
        INTO _dedup_id, _dedup_sim
        FROM pgmnemo.agent_lesson
        WHERE is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
          AND embedding IS NOT NULL
          AND project_id = p_project_id
          AND (1.0 - (embedding <=> p_embedding)) > 0.98
        ORDER BY embedding <=> p_embedding
        LIMIT 1;

        IF FOUND THEN
            RAISE WARNING
                'pgmnemo.ingest: near-duplicate detected -- cosine similarity % > 0.98 '
                'to existing lesson_id=% (project_id=%). Returning existing lesson_id.',
                ROUND(_dedup_sim::NUMERIC, 4), _dedup_id, p_project_id;
            RETURN _dedup_id;
        END IF;
    END IF;

    -- Resolve effective content_type
    _effective_content_type := COALESCE(
        p_content_type,
        pgmnemo.classify_content_type(p_lesson_text)
    );

    -- v0.16.0: auto-populate entity_keys in metadata
    _entity_keys := pgmnemo.extract_entity_keys(p_lesson_text);
    _effective_metadata := p_metadata;
    IF array_length(_entity_keys, 1) > 0 THEN
        _effective_metadata := _effective_metadata || jsonb_build_object('entity_keys', _entity_keys);
    END IF;

    -- Bitemporal dedup observability
    _content_hash := MD5(
        COALESCE(p_role, '')  || '|' ||
        COALESCE(p_topic, '') || '|' ||
        COALESCE(p_commit_sha, COALESCE(p_artifact_hash, ''))
    );

    SELECT COUNT(*)::INT INTO _prior_count
    FROM pgmnemo.agent_lesson
    WHERE content_hash = _content_hash
      AND t_valid_to   = 'infinity'::TIMESTAMPTZ;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, content_type, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, _effective_metadata, _effective_content_type,
        NOW()
    ) RETURNING id INTO new_id;

    IF _prior_count > 0 THEN
        RAISE NOTICE
            'pgmnemo.ingest: bitemporal close+create fired -- closed % prior version(s) '
            '(content_hash=%). New lesson_id=%.',
            _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB, TEXT) IS
    'Validated public write API v0.16.0. '
    'F1 (min-length): RAISE EXCEPTION when lesson_text < 20 chars. '
    'F2 (repetition): RAISE EXCEPTION when most-frequent token > 80%% of all tokens. '
    'F3 (dedup-warn): RAISE WARNING + RETURN existing lesson_id when cosine_sim > 0.98. '
    'v0.14.0: p_content_type (10th param, DEFAULT NULL) — auto-derived when NULL. '
    'v0.16.0: auto-populates metadata->''entity_keys'' via extract_entity_keys(lesson_text). '
    'Entity keys are strictly additive — existing metadata keys are preserved.';
