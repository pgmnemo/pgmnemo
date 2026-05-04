-- pgmnemo--0.0.1--0.1.0.sql
-- HNSW index swap (BLK-4)
-- Replaces ivfflat(lists=100) with HNSW per paper Appendix A.
-- Requires: pgvector >= 0.7.0 (HNSW operator class support).
-- The control file `requires = 'vector'` is sufficient; pgvector 0.7+ ships
-- HNSW natively and is available in all supported benchmark environments.

DROP INDEX IF EXISTS pgmnemo.pgmnemo_agent_lesson_embedding_idx;
CREATE INDEX IF NOT EXISTS pgmnemo_agent_lesson_embedding_idx
  ON pgmnemo.agent_lesson
  USING hnsw (embedding vector_cosine_ops)
  WITH (m=16, ef_construction=64)
  WHERE is_active AND embedding IS NOT NULL;

-- ---------------------------------------------------------------------------
-- EXT-BD-4: Recency-weighted scoring in recall_lessons() (BLK-3 fix)
--
-- Replaces v0.0.1 fixed FTS+cosine formula with paper §6.4 LOCKED formula:
--   α=0.5  semantic similarity (cosine via pgvector)
--   β=0.2  importance/5 — layer-weight proxy per PI §2.1 footnote / paper §3.4
--   γ=0.2  recency decay — linear over 90-day window, floored at 0
--   δ=0.1  provenance strength — commit+verified=1.0, commit-only=0.5, none=0.0
--
-- Full-text scoring (ft_score) is retained in the candidates CTE for the
-- embedding-or-text filter guard but is no longer a scoring coefficient.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding  vector(1024),
    k                INT     DEFAULT 10,
    role_filter      TEXT    DEFAULT NULL,
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
            -- α: cosine similarity via pgvector (1 - distance, range 0..1)
            CASE
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
            -- ft_score retained for embedding-or-text guard (not a scoring coeff in v0.1.0)
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id IS NULL OR al.project_id = recall_lessons.project_id)
          -- Require embedding when no text query (avoid returning random unrelated rows)
          AND (al.embedding IS NOT NULL OR _has_text)
    )
    SELECT
        c.id                                          AS lesson_id,
        -- Paper §6.4 LOCKED scoring formula (α=0.5, β=0.2, γ=0.2, δ=0.1)
        (
            0.5 * c.vec_score
          + 0.2 * (c.importance::DOUBLE PRECISION / 5.0)
          + 0.2 * GREATEST(0.0,
                    1.0 - LEAST(
                        EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0),
                        1.0
                    )
                  )::DOUBLE PRECISION
          + 0.1 * (CASE
                     WHEN c.commit_sha IS NOT NULL AND c.verified_at IS NOT NULL THEN 1.0
                     WHEN c.commit_sha IS NOT NULL                               THEN 0.5
                     ELSE 0.0
                   END)::DOUBLE PRECISION
        )                                             AS score,
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
        (
            0.5 * c.vec_score
          + 0.2 * (c.importance::DOUBLE PRECISION / 5.0)
          + 0.2 * GREATEST(0.0,
                    1.0 - LEAST(
                        EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0),
                        1.0
                    )
                  )::DOUBLE PRECISION
          + 0.1 * (CASE
                     WHEN c.commit_sha IS NOT NULL AND c.verified_at IS NOT NULL THEN 1.0
                     WHEN c.commit_sha IS NOT NULL                               THEN 0.5
                     ELSE 0.0
                   END)::DOUBLE PRECISION
        ) DESC,
        c.importance DESC,
        c.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'Hybrid recall — paper §6.4 LOCKED formula: '
    '0.5×cosine_similarity + 0.2×(importance/5) + 0.2×recency(90d) + 0.1×provenance_strength. '
    'query_text is optional; when NULL the full-text component is 0 (pure vector recall). '
    'Filters: role (exact) + project_id. '
    'Excludes ghost lessons (verified_at IS NULL) unless pgmnemo.include_unverified=on.';

-- ---------------------------------------------------------------------------
-- EXT-BD-5: pgmnemo.ingest() — validated public write API (BLK-5 fix)
--
-- Provides a clean, validated write path for Track C (dogfooding) and
-- Track B (benchmarks). Callers should use this instead of raw INSERT to:
--   1. Validate embedding dimension (must be 1024 if provided).
--   2. Auto-set verified_at when provenance fields are present.
--   3. Allow the existing gate trigger to fire naturally on INSERT.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT  DEFAULT 3,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT      DEFAULT NULL,
    p_artifact_hash TEXT      DEFAULT NULL,
    p_metadata      JSONB     DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id BIGINT;
BEGIN
    -- Validate embedding dim if provided
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- Insert (gate trigger fires naturally based on commit_sha/artifact_hash + GUC)
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata,
        verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
    ) RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API. Use this instead of raw INSERT.';
