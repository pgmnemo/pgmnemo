-- pgmnemo upgrade: 0.1.1 → 0.1.2
-- D-RMD-V012: tri-state prov_strength (0.0/0.4/1.0) + recall_lessons_pooled() wrapper
-- SPDX-License-Identifier: Apache-2.0
--
-- Changes:
--   1. recall_lessons(): prov_strength middle value 0.5→0.4 (commit-only case),
--      per RESEARCH_PROVENANCE_GATE.md §6.1 tri-state recommendation.
--   2. recall_lessons_pooled(query_embedding, k, app_id): thin wrapper that calls
--      recall_lessons() with role=NULL (pooled/cross-role recall), per
--      RESEARCH_RLS_PATTERNS.md §5 D4 Option C recommendation.
--   No new GUCs. No schema changes. Backward compatible.
--
-- Deviation from §6.1: formula uses `commit_sha IS NOT NULL` (not OR artifact_hash)
-- for the 0.4 case. artifact_hash bonus is DEFERRED to v0.2.x per research D2 note
-- ("artifact_hash is optional for lightweight ingestion paths").

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
    _gamma              DOUBLE PRECISION;
BEGIN
    BEGIN
        _include_unverified := coalesce(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.2
    );

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
            CASE
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
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
          AND (al.embedding IS NOT NULL OR _has_text)
    )
    SELECT
        c.id                                          AS lesson_id,
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
                     WHEN c.commit_sha IS NOT NULL                               THEN 0.4
                     ELSE                                                             0.0
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
                     WHEN c.commit_sha IS NOT NULL                               THEN 0.4
                     ELSE                                                             0.0
                   END)::DOUBLE PRECISION
        ) DESC,
        c.importance DESC,
        c.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'Hybrid recall — paper §6.4 formula with GUC-controlled γ: '
    '0.5×cosine_similarity + 0.2×(importance/5) + γ×recency(90d) + 0.1×prov_strength. '
    'prov_strength: 1.0=commit+verified, 0.4=commit-only, 0.0=no provenance (tri-state v0.1.2). '
    'γ = pgmnemo.recency_weight (default 0.2). '
    'role=NULL returns all roles pooled; use recall_lessons_pooled() for explicit cross-role recall.';


CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons_pooled(
    query_embedding  vector(1024),
    k                INT  DEFAULT 10,
    app_id           INT  DEFAULT NULL
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
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT * FROM pgmnemo.recall_lessons(query_embedding, k, NULL, app_id, NULL);
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons_pooled(vector, INT, INT) IS
    'Cross-role recall wrapper for R3 ablation: calls recall_lessons() with role=NULL '
    '(pooled — no role filter). Returns lessons from all roles within the given app_id. '
    'Per RESEARCH_RLS_PATTERNS.md §5 D4: canonical entrypoint for RO-1/RO-2 ablation.';
