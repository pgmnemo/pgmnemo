-- pgmnemo upgrade: 0.1.0 → 0.1.1
-- D-RMD-R1-GUC: expose γ as runtime-tunable GUC pgmnemo.recency_weight
-- SPDX-License-Identifier: Apache-2.0

-- Replaces recall_lessons() so γ is read from GUC at call time.
-- No signature change — CREATE OR REPLACE is sufficient.
-- SQL-only GUC: no C-extension change; PostgreSQL accepts arbitrary
-- class.name settings via current_setting() without prior declaration.

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
    _gamma              DOUBLE PRECISION;
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

    -- Read γ from GUC; fall back to 0.2 if not set or empty string
    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.2
    );

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
          AND (recall_lessons.role       IS NULL OR al.role       = recall_lessons.role)
          AND (recall_lessons.project_id IS NULL OR al.project_id = recall_lessons.project_id)
          -- Require embedding when no text query (avoid returning random unrelated rows)
          AND (al.embedding IS NOT NULL OR _has_text)
    )
    SELECT
        c.id                                          AS lesson_id,
        -- Paper §6.4 formula with GUC-controlled γ (pgmnemo.recency_weight, default 0.2)
        (
            0.5 * c.vec_score
          + 0.2 * (c.importance::DOUBLE PRECISION / 5.0)
          + _gamma * GREATEST(0.0,
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
          + _gamma * GREATEST(0.0,
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
    'Hybrid recall — paper §6.4 formula with GUC-controlled γ: '
    '0.5×cosine_similarity + 0.2×(importance/5) + γ×recency(90d) + 0.1×provenance_strength. '
    'γ = pgmnemo.recency_weight (default 0.2). Set to 0.0 to disable recency for R1 ablation. '
    'query_text is optional; when NULL the full-text component is 0 (pure vector recall). '
    'Filters: role (exact) + project_id. '
    'Excludes ghost lessons (verified_at IS NULL) unless pgmnemo.include_unverified=on.';
