-- typed_write_api.sql
-- pgmnemo W2 draft — typed ingest / mem_write() with p_content_type
-- Reconstructed from context for MEM-ERA-W1 salvage (original was uncommitted, lost).
-- This draft captures the design intent; implementation is for W2 iteration.
--
-- Context:
--   P0.2 (v0.11.0) added p_content_types filter to recall_hybrid (read path).
--   W2 completes the roundtrip: write path must also accept content_type on ingest.
--
--   Current pgmnemo.ingest() (0.11.0) has NO p_content_type parameter.
--   agent_lesson.content_type TEXT column exists since v0.9.0.
--   Index ix_pgmnemo_content_type_active covers (content_type) WHERE is_active = TRUE.
--
-- Design:
--   Option A: New overload of pgmnemo.ingest() with p_content_type as last param.
--   Option B: New alias pgmnemo.mem_write() as ergonomic typed facade.
--   This draft implements BOTH: overload for backward compat + mem_write() facade.
--
-- SPDX-License-Identifier: Apache-2.0
-- Status: DRAFT (uncommitted — recreated for W2 from MEM-ERA-W1 salvage)

-- ─────────────────────────────────────────────────────────────────────────────
-- pgmnemo.ingest — v0.12.0 typed overload (adds p_content_type as 10th param)
--
-- Backward compat: 9-param callers continue to work (DEFAULT NULL = untyped).
-- New callers pass p_content_type to tag lessons for typed recall.
--
-- Valid content_type values (advisory — enforced by application convention):
--   procedure, fact, entity, event, decision, risk, dependency, assumption
--   (NULL = untyped; passes through existing unfiltered recall paths unchanged)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT     DEFAULT 3,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT         DEFAULT NULL,
    p_artifact_hash TEXT         DEFAULT NULL,
    p_metadata      JSONB        DEFAULT '{}'::jsonb,
    p_content_type  TEXT         DEFAULT NULL    -- W2: typed write; NULL = untyped (compat)
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id      BIGINT;
    _max_chars  INT;
BEGIN
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        8000
    );

    IF length(p_lesson_text) > _max_chars THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too long (% chars, max %)',
            length(p_lesson_text), _max_chars;
    END IF;

    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, content_type, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata, p_content_type,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
    ) RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT,INT,TEXT,TEXT,SMALLINT,vector,TEXT,TEXT,JSONB,TEXT)
    IS 'v0.12.0 typed overload: adds p_content_type for typed recall roundtrip (P0.2 read + W2 write)';

-- ─────────────────────────────────────────────────────────────────────────────
-- pgmnemo.mem_write — ergonomic typed write facade (W2 primary API)
--
-- Simplified parameter order optimized for agent SDK callers:
--   (role, topic, lesson_text, content_type, importance, project_id, commit_sha)
-- Embeds provenance pattern: commit_sha present → marks verified_at = NOW().
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.mem_write(
    p_role          TEXT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_content_type  TEXT         DEFAULT NULL,   -- typed write; NULL = untyped
    p_importance    SMALLINT     DEFAULT 3,
    p_project_id    INT          DEFAULT NULL,
    p_commit_sha    TEXT         DEFAULT NULL,
    p_metadata      JSONB        DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE sql AS $$
    SELECT pgmnemo.ingest(
        p_role, p_project_id, p_topic, p_lesson_text,
        p_importance, NULL, p_commit_sha, NULL, p_metadata, p_content_type
    );
$$;

COMMENT ON FUNCTION pgmnemo.mem_write(TEXT,TEXT,TEXT,TEXT,SMALLINT,INT,TEXT,JSONB)
    IS 'W2 typed write facade — ergonomic API for agent SDK; wraps ingest() with content_type first-class';

-- ─────────────────────────────────────────────────────────────────────────────
-- Regression smoke (inline — run via pg_regress as test/typed_write_api.sql)
-- ─────────────────────────────────────────────────────────────────────────────

-- W2-T1: mem_write() returns a valid lesson_id
-- SELECT pgmnemo.mem_write('w2_test', 'write API smoke', 'content here', 'procedure') > 0;

-- W2-T2: Written row is retrievable via typed recall_hybrid
-- SELECT count(*) FROM pgmnemo.recall_hybrid(NULL, 'content here', 10, 'w2_test',
--     NULL, 0.4, 0.4, 60, NULL, ARRAY['procedure']) WHERE lesson_text LIKE '%content%';

-- W2-T3: content_type NULL does NOT filter
-- SELECT count(*) FROM pgmnemo.recall_hybrid(NULL, 'content here', 10, 'w2_test') WHERE lesson_text LIKE '%content%';
