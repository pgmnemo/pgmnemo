-- SPDX-License-Identifier: Apache-2.0
-- pgmnemo 0.0.1 — Multi-agent memory substrate for PostgreSQL
-- Copyright 2026 Alex Gaydabura and pgmnemo contributors
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- W2.3: agent_lesson DDL + recall_lessons() PL/pgSQL
-- Implements: BUILD_MVP_EXT_PHASE1.md §1 (DDL) + §6 (gate_strict GUC decisions)
-- Requires: pgvector extension (vector type, ivfflat operator class)

\echo Use "CREATE EXTENSION pgmnemo" to load this file. \quit

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pgmnemo;

-- ---------------------------------------------------------------------------
-- GUC: pgmnemo.gate_strict
--
-- Controls provenance enforcement at INSERT time.  Three modes per §6 decision:
--   off      — allow inserts missing commit_sha and artifact_hash (dev/test mode)
--   warn     — allow but RAISE WARNING  (audit trail preserved; staging mode)
--   enforce  — RAISE EXCEPTION, row rejected (default; production-safe)
--
-- Set per-session:  SET pgmnemo.gate_strict = 'warn';
-- Set globally:     ALTER SYSTEM SET pgmnemo.gate_strict = 'enforce';
-- PG14+: no C registration needed; current_setting() with TRUE (missing_ok) is
-- used throughout so the GUC can be absent without error.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE pgmnemo.agent_lesson (
    id               BIGSERIAL    PRIMARY KEY,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- Lesson content
    role             TEXT         NOT NULL,
    project_id       INT,
    topic            TEXT         NOT NULL,
    lesson_text      TEXT         NOT NULL,
    importance       SMALLINT     NOT NULL DEFAULT 3 CHECK (importance BETWEEN 1 AND 5),

    -- Rich metadata (arbitrary structured context: tags, source agent config, model version)
    metadata         JSONB,

    -- Origin
    source_run_id    TEXT,

    -- Provenance gate (BUILD_MVP_EXT_PHASE1.md §1 + §6)
    -- At least one of commit_sha or artifact_hash MUST be non-NULL.
    -- Enforcement level is controlled by GUC pgmnemo.gate_strict.
    commit_sha       TEXT,         -- git commit SHA of the agent run that produced this lesson
    artifact_hash    TEXT,         -- SHA-256 of any non-git artifact (file, blob, signed claim)
    verified_at      TIMESTAMPTZ,  -- set when provenance was validated; NULL = unverified (ghost)

    -- Full-text search vectors (generated, maintained automatically by PG)
    topic_tsv        TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(topic, ''))) STORED,
    lesson_tsv       TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(lesson_text, ''))) STORED,
    -- Combined weighted tsvector: topic=A (higher weight), lesson_text=B
    full_text        TSVECTOR GENERATED ALWAYS AS (
                         setweight(to_tsvector('english', coalesce(topic, '')), 'A') ||
                         setweight(to_tsvector('english', coalesce(lesson_text, '')), 'B')
                     ) STORED,

    -- Dense vector embedding for semantic recall (pgvector, 1024-dim)
    embedding        vector(1024),

    -- Soft-delete
    is_active        BOOLEAN      NOT NULL DEFAULT TRUE,
    resolved_at      TIMESTAMPTZ
);

COMMENT ON TABLE pgmnemo.agent_lesson IS
    'Durable, provenance-gated agent lessons. '
    'Rows with verified_at IS NULL are ghost lessons excluded from recall_lessons() by default. '
    'Provenance gate enforces commit_sha OR artifact_hash presence on INSERT.';

COMMENT ON COLUMN pgmnemo.agent_lesson.metadata IS
    'Arbitrary structured context: tags, source agent config, model version, run metadata, etc.';
COMMENT ON COLUMN pgmnemo.agent_lesson.commit_sha IS
    'Git commit SHA that generated or justified this lesson. '
    'Required unless artifact_hash is set (enforced by enforce_provenance_gate trigger).';
COMMENT ON COLUMN pgmnemo.agent_lesson.artifact_hash IS
    'SHA-256 hex of an external artifact (file, API response, signed claim) '
    'when no git commit applies. Required unless commit_sha is set.';
COMMENT ON COLUMN pgmnemo.agent_lesson.verified_at IS
    'Timestamp at which commit_sha or artifact_hash was successfully verified. '
    'NULL = ghost lesson, excluded from recall by default.';
COMMENT ON COLUMN pgmnemo.agent_lesson.full_text IS
    'Weighted tsvector: topic (weight A) || lesson_text (weight B). '
    'Used by recall_lessons() for full-text scoring component.';
COMMENT ON COLUMN pgmnemo.agent_lesson.embedding IS
    '1024-dim dense vector embedding for semantic recall via pgvector cosine similarity.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- GIN on metadata JSONB for key/value and containment lookups
CREATE INDEX pgmnemo_agent_lesson_metadata_idx
    ON pgmnemo.agent_lesson USING GIN (metadata)
    WHERE is_active AND metadata IS NOT NULL;

-- GIN on combined full_text tsvector (primary FTS index for recall_lessons)
CREATE INDEX pgmnemo_agent_lesson_full_text_idx
    ON pgmnemo.agent_lesson USING GIN (full_text)
    WHERE is_active;

-- GIN on individual tsvectors (kept for targeted single-field queries)
CREATE INDEX pgmnemo_agent_lesson_topic_tsv_idx
    ON pgmnemo.agent_lesson USING GIN (topic_tsv)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_lesson_tsv_idx
    ON pgmnemo.agent_lesson USING GIN (lesson_tsv)
    WHERE is_active;

-- B-tree composite: supports (role, project_id, created_at DESC) range scans
-- Used by recall_lessons() role/project filters + time ordering.
CREATE INDEX pgmnemo_agent_lesson_role_proj_time_idx
    ON pgmnemo.agent_lesson (role, project_id, created_at DESC)
    WHERE is_active;

-- B-tree single-column fallbacks for partial-key queries
CREATE INDEX pgmnemo_agent_lesson_role_idx
    ON pgmnemo.agent_lesson (role)
    WHERE is_active;

CREATE INDEX pgmnemo_agent_lesson_project_idx
    ON pgmnemo.agent_lesson (project_id)
    WHERE is_active AND project_id IS NOT NULL;

CREATE INDEX pgmnemo_agent_lesson_verified_idx
    ON pgmnemo.agent_lesson (verified_at)
    WHERE is_active AND verified_at IS NOT NULL;

-- ivfflat index on embedding for approximate nearest-neighbour recall.
-- lists=100 tuned for 100-row W2.3 fixture; HNSW deferred to W3 (production scale).
-- NOTE: ivfflat requires rows present before index build for good cluster centroids.
-- For an empty table this creates the index structure; fill data before recall.
CREATE INDEX pgmnemo_agent_lesson_embedding_idx
    ON pgmnemo.agent_lesson USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100)
    WHERE is_active AND embedding IS NOT NULL;

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgmnemo._set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER agent_lesson_updated_at
    BEFORE UPDATE ON pgmnemo.agent_lesson
    FOR EACH ROW EXECUTE FUNCTION pgmnemo._set_updated_at();

-- ---------------------------------------------------------------------------
-- Provenance gate trigger
--
-- BEFORE INSERT — rejects (or warns) when both commit_sha AND artifact_hash are NULL.
-- Enforcement level set via GUC pgmnemo.gate_strict (default 'enforce').
--
-- 'enforce' — RAISE EXCEPTION; row is rejected (production default per §6)
-- 'warn'    — RAISE WARNING;  row is accepted; ghost lesson (staging/audit)
-- 'off'     — no action;      row accepted silently (dev/test only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgmnemo._enforce_provenance_gate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    _gate TEXT;
BEGIN
    -- Provenance present — fast path (either is sufficient)
    IF NEW.commit_sha IS NOT NULL OR NEW.artifact_hash IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- Read GUC; default to 'enforce' when unset or on any error
    BEGIN
        _gate := lower(trim(coalesce(current_setting('pgmnemo.gate_strict', TRUE), '')));
        IF _gate = '' THEN
            _gate := 'enforce';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        _gate := 'enforce';
    END;

    CASE _gate
        WHEN 'enforce' THEN
            RAISE EXCEPTION
                'pgmnemo provenance gate [enforce]: INSERT rejected — '
                'commit_sha or artifact_hash is required. '
                'Supply at least one provenance field, or SET pgmnemo.gate_strict = ''warn'' '
                'to allow unprovenanced writes with an audit warning.';

        WHEN 'warn' THEN
            RAISE WARNING
                'pgmnemo provenance gate [warn]: INSERT accepted without commit_sha or artifact_hash. '
                'Row will be a ghost lesson (verified_at IS NULL) and excluded from recall by default.';
            RETURN NEW;

        ELSE
            -- 'off' or any unrecognized value — allow silently
            RETURN NEW;
    END CASE;
END;
$$;

CREATE TRIGGER enforce_provenance_gate
    BEFORE INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW EXECUTE FUNCTION pgmnemo._enforce_provenance_gate();

COMMENT ON FUNCTION pgmnemo._enforce_provenance_gate() IS
    'Provenance gate trigger: rejects INSERTs where both commit_sha and artifact_hash are NULL. '
    'Controlled by GUC pgmnemo.gate_strict (enforce|warn|off, default enforce). '
    'Implements BUILD_MVP_EXT_PHASE1.md §6 gate_strict decision.';

-- ---------------------------------------------------------------------------
-- recall_lessons(query_embedding, k, role, project_id, query_text)
--
-- Hybrid recall: 40% full-text rank (tsvector) + 60% semantic similarity (cosine).
-- When query_text IS NULL the full-text component is 0 (pure vector recall).
--
-- Parameters:
--   query_embedding — 1024-dim query vector (caller computes from embedding model)
--   k               — max rows to return (default 10)
--   role            — exact role filter (NULL = all roles)
--   project_id      — project filter (NULL = all projects)
--   query_text      — optional free-text query; enables full-text component (default NULL)
--
-- Scoring formula:
--   score = 0.4 * ts_rank_cd(full_text, tsquery)    [0 when query_text IS NULL]
--         + 0.6 * (1 - (embedding <=> query_embedding))   [cosine similarity]
--
-- GUC pgmnemo.include_unverified = 'on' to include ghost lessons (verified_at IS NULL).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding  vector(1024),
    k                INT     DEFAULT 10,
    role             TEXT    DEFAULT NULL,
    project_id       INT     DEFAULT NULL,
    query_text       TEXT    DEFAULT NULL
)
RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,
    role          TEXT,
    project_id    INT,
    topic         TEXT,
    lesson_text   TEXT,
    importance    SMALLINT,
    metadata      JSONB,
    commit_sha    TEXT,
    artifact_hash TEXT,
    verified_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
BEGIN
    -- Respect caller opt-in for ghost lessons (default: exclude unverified)
    BEGIN
        _include_unverified := coalesce(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- Compile text query when provided; fall back to plainto_tsquery on parse error
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', query_text);
            EXCEPTION WHEN OTHERS THEN
                _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH candidates AS (
        SELECT
            al.id,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.commit_sha,
            al.artifact_hash,
            al.verified_at,
            al.created_at,
            al.full_text,
            -- Cosine similarity via pgvector: 1 - distance (range 0..1, higher = more similar)
            CASE
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
            -- Full-text score: ts_rank_cd against compiled tsquery (0 when no text query)
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_lessons.role     IS NULL OR al.role       = recall_lessons.role)
          AND (recall_lessons.project_id IS NULL OR al.project_id = recall_lessons.project_id)
          -- Require embedding when no text query (avoid returning random unrelated rows)
          AND (al.embedding IS NOT NULL OR _has_text)
    )
    SELECT
        c.id                                          AS lesson_id,
        (0.4 * c.ft_score + 0.6 * c.vec_score)       AS score,
        c.role,
        c.project_id,
        c.topic,
        c.lesson_text,
        c.importance,
        c.metadata,
        c.commit_sha,
        c.artifact_hash,
        c.verified_at,
        c.created_at
    FROM candidates c
    ORDER BY
        (0.4 * c.ft_score + 0.6 * c.vec_score) DESC,
        c.importance DESC,
        c.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'Hybrid recall: 40% full-text (tsvector) + 60% cosine semantic similarity. '
    'query_text is optional; when NULL the full-text component is 0 (pure vector recall). '
    'Filters: role (exact) + project_id. '
    'Excludes ghost lessons (verified_at IS NULL) unless pgmnemo.include_unverified=on.';

-- ---------------------------------------------------------------------------
-- version()
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgmnemo.version()
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE PARALLEL SAFE
AS $$
    SELECT '0.0.1'::text;
$$;

COMMENT ON FUNCTION pgmnemo.version() IS
    'Returns the installed pgmnemo extension version.';
