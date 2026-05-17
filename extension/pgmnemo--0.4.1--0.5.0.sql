-- pgmnemo--0.4.1--0.5.0.sql
-- Migration: v0.4.1 → v0.5.0
--
-- R10: Remove traverse_causal_chain 4-arg overload deprecated in v0.4.1.
--      The 5-arg form pgmnemo.traverse_causal_chain(BIGINT,INT,TEXT[],BOOLEAN,TEXT) is unchanged.
--
-- H-06: Temporal recency tuning
--   recency_weight recommended value updated to 0.5 (H-06 research predicted optimal, cell C6).
--   Previous default: 0.05 (v0.4.1 Agency ablation R1).
--   Basis: H06_TEMPORAL_TUNE_RESEARCH.md §5 — predicted best cell C6 (rw=0.5, td=1.0);
--          bench run pending live PG environment.
--   Note: COALESCE fallbacks in recall_lessons/recall_hybrid retain 0.05 for backward
--         compat; operators should SET pgmnemo.recency_weight = '0.5' per-session or
--         via ALTER DATABASE for temporal-query workloads.
--
--   pgmnemo.temporal_boost: new GUC (FLOAT, default 1.0, range 0.0–5.0).
--   A score multiplier applied to temporal-category queries in recall routing.
--   Default 1.0 = neutral (no boost). Set to >1.0 to up-weight temporal matches.

DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);

-- ─────────────────────────────────────────────────────────────────────────────
-- H-06: Register pgmnemo.temporal_boost custom GUC
-- ─────────────────────────────────────────────────────────────────────────────

-- Initialise the GUC to its default value so current_setting() never returns ''.
-- Operators may override per-session: SET pgmnemo.temporal_boost = '2.0';
DO $$
BEGIN
    PERFORM set_config('pgmnemo.temporal_boost', '1.0', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- Helper: return the current temporal_boost value, clamped to [0.0, 5.0].
CREATE OR REPLACE FUNCTION pgmnemo.get_temporal_boost()
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _v DOUBLE PRECISION;
BEGIN
    _v := COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    );
    RETURN GREATEST(0.0, LEAST(5.0, _v));
END;
$$;

COMMENT ON FUNCTION pgmnemo.get_temporal_boost() IS
    'Returns pgmnemo.temporal_boost GUC (default 1.0, range 0.0–5.0). '
    'Score multiplier for temporal-category recall queries. '
    'Set via: SET pgmnemo.temporal_boost = ''2.0''; '
    'H-06 optimal TBD pending bench run; research predicts rw=0.5 (C6) as best cell.';


-- ─────────────────────────────────────────────────────────────────────────────
-- §3 R5: max_query_text_chars GUC
--
-- Limits the length of query_text processed by recall_lessons() and the
-- lesson_text stored by ingest().  Default 2000 chars — covers ~98% of
-- production Agency task titles and lessons.  Long text is silently truncated
-- with a RAISE NOTICE so callers can detect the event.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM set_config('pgmnemo.max_query_text_chars', '2000', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- H-06: recall_lessons() — apply temporal_boost as γ multiplier
--
-- effective_γ = recency_weight * temporal_boost
--   Default (no GUCs set): 0.05 * 1.0 = 0.05 — backward compatible, unchanged.
--   Research optimal (H-06 C6): SET pgmnemo.temporal_boost = '10.0' achieves
--     effective_γ ≈ 0.5 on default recency_weight=0.05.
--   Or: SET pgmnemo.recency_weight = '0.5' alone also achieves γ=0.5.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    query_text        TEXT    DEFAULT NULL
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
    created_at    TIMESTAMPTZ,
    vec_score     DOUBLE PRECISION,
    bm25_score    DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
BEGIN
    -- R5: clamp query_text to pgmnemo.max_query_text_chars (default 2000).
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars (pgmnemo.max_query_text_chars). '
                     'Original length: %', _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _disable_hybrid := FALSE;
    END;

    IF NOT _disable_hybrid
       AND _query_text IS NOT NULL
       AND length(trim(_query_text)) > 0
       AND query_embedding IS NOT NULL THEN
        RETURN QUERY
        SELECT
            h.lesson_id,
            h.score,
            h.role,
            h.project_id,
            h.topic,
            h.lesson_text,
            h.importance,
            h.metadata,
            h.commit_sha,
            h.artifact_hash,
            h.verified_at,
            h.created_at,
            h.vec_score,
            h.bm25_score,
            h.rrf_score
        FROM pgmnemo.recall_hybrid(
            query_embedding,
            _query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,
            0.4,
            60
        ) h;
        RETURN;
    END IF;

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT,
            100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- Base recency weight γ (backward compat default 0.05)
    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.05
    );

    -- H-06 temporal_boost multiplier (default 1.0 = neutral, range 0.0–5.0).
    -- effective_γ = _gamma * _temporal_boost
    -- Research optimal: boost=10.0 with default rw=0.05 → effective_γ=0.5 (C6).
    _temporal_boost := GREATEST(0.0, LEAST(5.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
        1.0
    )));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', _query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', _query_text);
            EXCEPTION WHEN OTHERS THEN
                _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE candidates AS (
        SELECT
            al.id AS cand_id,
            al.role AS cand_role,
            al.project_id AS cand_project_id,
            al.topic AS cand_topic,
            al.lesson_text AS cand_lesson_text,
            al.importance AS cand_importance,
            al.metadata AS cand_metadata,
            al.commit_sha AS cand_commit_sha,
            al.artifact_hash AS cand_artifact_hash,
            al.verified_at AS cand_verified_at,
            al.created_at AS cand_created_at,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS vec_score_raw
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (role_filter IS NULL OR al.role = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
        ORDER BY al.embedding <=> query_embedding
        LIMIT GREATEST(k * 5, 50)
    ),
    anchors AS (
        SELECT cand_id FROM candidates ORDER BY vec_score_raw DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT cand_id, 0, cand_id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.relation_type IN ('CAUSED_BY', 'CO_OCCURRED', 'DERIVED_FROM')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT reached_id AS gp_lesson_id,
               MAX(1.0 - depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk WHERE depth > 0 GROUP BY reached_id
    )
    SELECT
        c.cand_id AS lesson_id,
        (
            0.5 * c.vec_score_raw
          + 0.2 * (c.cand_importance::DOUBLE PRECISION / 5.0)
          + _gamma * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0
            ))
          + 0.1 * (CASE
                WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
                WHEN c.cand_commit_sha IS NOT NULL THEN 0.5
                ELSE 0.0 END)
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) AS score,
        c.cand_role AS role,
        c.cand_project_id AS project_id,
        c.cand_topic AS topic,
        c.cand_lesson_text AS lesson_text,
        c.cand_importance AS importance,
        c.cand_metadata AS metadata,
        c.cand_commit_sha AS commit_sha,
        c.cand_artifact_hash AS artifact_hash,
        c.cand_verified_at AS verified_at,
        c.cand_created_at AS created_at,
        c.vec_score_raw AS vec_score,
        NULL::DOUBLE PRECISION AS bm25_score,
        NULL::DOUBLE PRECISION AS rrf_score
    FROM candidates c
    LEFT JOIN graph_proximity gp ON gp.gp_lesson_id = c.cand_id
    ORDER BY (
        0.5 * c.vec_score_raw
      + 0.2 * (c.cand_importance::DOUBLE PRECISION / 5.0)
      + _gamma * GREATEST(0.0, 1.0 - LEAST(
            EXTRACT(EPOCH FROM (NOW() - c.cand_created_at)) / (90.0 * 86400.0), 1.0
        ))
      + 0.1 * (CASE
            WHEN c.cand_commit_sha IS NOT NULL AND c.cand_verified_at IS NOT NULL THEN 1.0
            WHEN c.cand_commit_sha IS NOT NULL THEN 0.5
            ELSE 0.0 END)
      + _graph_weight * COALESCE(gp.proximity, 0.0)
    ) DESC,
    c.cand_importance DESC,
    c.cand_created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'v0.5.0 hybrid router with temporal_boost GUC (H-06). Routes to recall_hybrid() '
    'when query_text non-empty AND embedding present AND pgmnemo.disable_hybrid FALSE/unset. '
    'Vector-only path: effective_γ = pgmnemo.recency_weight * pgmnemo.temporal_boost. '
    'Defaults: recency_weight=0.05 (v0.4.1 ablation), temporal_boost=1.0 (neutral). '
    'H-06 research optimal (C6): SET pgmnemo.temporal_boost = ''10.0'' to reach γ=0.5. '
    'temporal_boost range: 0.0–5.0 (clamped internally). '
    'Diagnostic cols (R4): vec_score=cosine; bm25_score/rrf_score=NULL on vector path. '
    'Opt-out hybrid: SET pgmnemo.disable_hybrid = ''true''.';


-- ─────────────────────────────────────────────────────────────────────────────
-- H-07: Bitemporality primitive on agent_lesson (v0.5.0)
-- Consistent with mem_edge.valid_from / valid_until pattern (pgmnemo--0.4.1.sql:278-280).
-- All guards use IF NOT EXISTS / CREATE OR REPLACE — safe to run twice on same DB.
-- See spec/v2/pgmnemo/H07_BITEMPORALITY_PLAN.md for ICE score, idempotency proof,
-- rollback SQL, and acceptance gate.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS t_valid_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS t_valid_to    TIMESTAMPTZ NOT NULL DEFAULT 'infinity'::TIMESTAMPTZ;

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS content_hash  TEXT GENERATED ALWAYS AS (
        MD5(
            COALESCE(role,        '') || '|' ||
            COALESCE(topic,       '') || '|' ||
            COALESCE(commit_sha, COALESCE(artifact_hash, ''))
        )
    ) STORED;

-- Backfill: existing rows get t_valid_from = their actual created_at.
-- Condition matches only rows whose t_valid_from was just set to now() by this migration.
UPDATE pgmnemo.agent_lesson
SET    t_valid_from = created_at
WHERE  t_valid_from >= (now() - INTERVAL '1 second');

CREATE INDEX IF NOT EXISTS ix_agent_lesson_valid_range
    ON pgmnemo.agent_lesson (t_valid_from, t_valid_to)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_hash_active
    ON pgmnemo.agent_lesson (content_hash)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Trigger: on INSERT, close any prior active row with the same content_hash.
-- NULL-safe: if content_hash IS NULL, no rows are closed (NULL != anything).
CREATE OR REPLACE FUNCTION pgmnemo._bitemporal_close_prior()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.content_hash IS NOT NULL THEN
        UPDATE pgmnemo.agent_lesson
        SET    t_valid_to = now()
        WHERE  content_hash = NEW.content_hash
          AND  t_valid_to   = 'infinity'::TIMESTAMPTZ
          AND  id           <> NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_agent_lesson_bitemporal_close ON pgmnemo.agent_lesson;

CREATE TRIGGER trg_agent_lesson_bitemporal_close
    AFTER INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW
    EXECUTE FUNCTION pgmnemo._bitemporal_close_prior();

-- pgmnemo.mem_item: active-only view (forward-compat alias for ROADMAP "mem_item").
CREATE OR REPLACE VIEW pgmnemo.mem_item AS
    SELECT *
    FROM   pgmnemo.agent_lesson
    WHERE  t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON VIEW pgmnemo.mem_item IS
    'Active-row alias for pgmnemo.agent_lesson (t_valid_to = infinity). '
    'H-07 bitemporality (v0.5.0). Forward-compat alias for ROADMAP mem_item.';

-- pgmnemo.as_of(ts): time-travel — state of agent_lesson as of timestamp ts.
CREATE OR REPLACE FUNCTION pgmnemo.as_of(ts TIMESTAMPTZ)
RETURNS SETOF pgmnemo.agent_lesson
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT *
    FROM   pgmnemo.agent_lesson
    WHERE  t_valid_from <= ts
      AND  t_valid_to   >  ts;
$$;

COMMENT ON FUNCTION pgmnemo.as_of(TIMESTAMPTZ) IS
    'Time-travel: returns agent_lesson state as of timestamp ts. '
    'Returns rows where t_valid_from <= ts < t_valid_to. '
    'H-07 bitemporality primitive (v0.5.0). '
    'For edge time-travel: join pgmnemo.as_of(ts) with pgmnemo.mem_edge.';

-- ─────────────────────────────────────────────────────────────────────────────
-- H-07: Bitemporality primitive on agent_lesson (v0.5.0)
-- Research: spec/v2/pgmnemo/H07_BITEMPORALITY_RESEARCH.md
-- Plan:     spec/v2/pgmnemo/H07_BITEMPORALITY_PLAN.md
--
-- Adds valid-time columns (t_valid_from, t_valid_to) + computed dedup key
-- (content_hash) to pgmnemo.agent_lesson.  All DDL uses IF NOT EXISTS /
-- CREATE OR REPLACE — idempotent on re-run.
--
-- Note on task-spec vs plan discrepancy:
--   The task spec references "pgmnemo.mem_item" as the target table and a
--   "mem" schema for as_of().  mem_item does not exist as a table in v0.4.1;
--   the research clarified it as a view alias over agent_lesson
--   (H07_BITEMPORALITY_RESEARCH.md §1a).  All objects are placed in the
--   pgmnemo schema, consistent with extension schema = pgmnemo in control file.
-- ─────────────────────────────────────────────────────────────────────────────

-- Step 1: Bitemporality columns + computed dedup key
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS t_valid_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS t_valid_to    TIMESTAMPTZ NOT NULL DEFAULT 'infinity'::TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS content_hash  TEXT GENERATED ALWAYS AS (
        MD5(
            COALESCE(role,       '') || '|' ||
            COALESCE(topic,      '') || '|' ||
            COALESCE(commit_sha, COALESCE(artifact_hash, ''))
        )
    ) STORED;

COMMENT ON COLUMN pgmnemo.agent_lesson.t_valid_from IS
    'Valid-time start: when this row''s content became true. '
    'Defaults to row creation time; backfilled to created_at for pre-H-07 rows. '
    'H-07 bitemporality (v0.5.0).';
COMMENT ON COLUMN pgmnemo.agent_lesson.t_valid_to IS
    'Valid-time end: ''infinity'' = currently active row. '
    'Set to now() by trigger when a new row with the same content_hash is inserted. '
    'H-07 bitemporality (v0.5.0).';
COMMENT ON COLUMN pgmnemo.agent_lesson.content_hash IS
    'MD5(role|topic|commit_sha_or_artifact_hash). Computed dedup key for bitemporal trigger. '
    'NULL-safe: when all three fields are NULL the hash is still computed (empty string fallback). '
    'H-07 bitemporality (v0.5.0).';

-- Step 2: Backfill — existing rows are "always valid" from their creation time.
-- The WHERE guard targets only rows whose t_valid_from was just set to now()
-- by the ADD COLUMN DEFAULT (within the last second).  On a second migration
-- run all existing t_valid_from values are historical and outside this window.
UPDATE pgmnemo.agent_lesson
SET    t_valid_from = created_at
WHERE  t_valid_from >= (now() - INTERVAL '1 second');

-- Step 3: Indexes (partial on active rows — keeps recall_lessons() scan unchanged)
CREATE INDEX IF NOT EXISTS ix_agent_lesson_valid_range
    ON pgmnemo.agent_lesson (t_valid_from, t_valid_to)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_hash_active
    ON pgmnemo.agent_lesson (content_hash)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Step 4: Trigger function — expire the prior active row on conflicting insert.
-- AFTER INSERT so NEW.id is available; uses content_hash for O(1) index lookup.
CREATE OR REPLACE FUNCTION pgmnemo._bitemporal_close_prior()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Close any currently-active row with the same content_hash.
    -- When content_hash is identical across rows it means the same logical lesson
    -- (same role + topic + provenance) is being re-ingested; close the prior version.
    -- NULL content_hash: all-NULL provenance is unusual (provenance gate blocks it),
    -- but we still compute a hash from empty-string fallbacks, so this branch
    -- is retained for safety in case a caller bypasses the gate.
    IF NEW.content_hash IS NOT NULL THEN
        UPDATE pgmnemo.agent_lesson
        SET    t_valid_to = now()
        WHERE  content_hash = NEW.content_hash
          AND  t_valid_to   = 'infinity'::TIMESTAMPTZ
          AND  id           <> NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

-- DROP + CREATE is the idempotent pattern for triggers (no CREATE OR REPLACE TRIGGER).
DROP TRIGGER IF EXISTS trg_agent_lesson_bitemporal_close ON pgmnemo.agent_lesson;
CREATE TRIGGER trg_agent_lesson_bitemporal_close
    AFTER INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW
    EXECUTE FUNCTION pgmnemo._bitemporal_close_prior();

-- Step 5: mem_item — active-only view alias (ROADMAP forward-compat naming).
CREATE OR REPLACE VIEW pgmnemo.mem_item AS
    SELECT * FROM pgmnemo.agent_lesson
    WHERE  t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON VIEW pgmnemo.mem_item IS
    'Active-only alias for pgmnemo.agent_lesson (t_valid_to = infinity). '
    'Forward-compat with ROADMAP mem_item naming (H-07, v0.5.0). '
    'For time-travel queries use pgmnemo.as_of(ts).';

-- Step 6: as_of() — point-in-time query function.
-- Named pgmnemo.as_of (not mem.as_of) because the extension schema is pgmnemo.
-- The "mem.as_of" in the task spec refers to this function in documentation context.
CREATE OR REPLACE FUNCTION pgmnemo.as_of(ts TIMESTAMPTZ)
RETURNS SETOF pgmnemo.agent_lesson
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT *
    FROM   pgmnemo.agent_lesson
    WHERE  t_valid_from <= ts
      AND  t_valid_to   >  ts;
$$;

COMMENT ON FUNCTION pgmnemo.as_of(TIMESTAMPTZ) IS
    'Time-travel query: returns the state of agent_lesson as of timestamp ts. '
    'Returns rows where t_valid_from <= ts < t_valid_to (half-open interval). '
    'Equivalent to the "mem.as_of" primitive in ROADMAP (schema is pgmnemo per control file). '
    'Example: SELECT * FROM pgmnemo.as_of(''2026-05-01 12:00:00+00''); '
    'H-07 bitemporality (v0.5.0).';


-- ─────────────────────────────────────────────────────────────────────────────
-- §C  R5: max_query_text_chars GUC + truncation in ingest()
--
-- GUC: pgmnemo.max_query_text_chars (INT, default 2000).
-- When lesson_text supplied to ingest() exceeds this limit the text is truncated
-- and a RAISE NOTICE is emitted so callers can detect the event.
-- NULL and empty-string inputs pass through unchanged (graceful fallback).
-- Set to 0 or negative to disable truncation entirely.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    PERFORM set_config('pgmnemo.max_query_text_chars', '2000', FALSE);
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

CREATE OR REPLACE FUNCTION pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT     DEFAULT 3,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT         DEFAULT NULL,
    p_artifact_hash TEXT         DEFAULT NULL,
    p_metadata      JSONB        DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id     BIGINT;
    _max_chars INT;
BEGIN
    -- R5: truncate lesson_text to max_query_text_chars when exceeded.
    -- Graceful NULL/empty fallback: skip check entirely.
    IF p_lesson_text IS NOT NULL AND length(p_lesson_text) > 0 THEN
        BEGIN
            _max_chars := NULLIF(
                current_setting('pgmnemo.max_query_text_chars', TRUE), ''
            )::INT;
        EXCEPTION WHEN OTHERS THEN
            _max_chars := NULL;
        END;
        IF _max_chars IS NOT NULL AND _max_chars > 0
           AND length(p_lesson_text) > _max_chars THEN
            RAISE NOTICE
                'pgmnemo.ingest: lesson_text truncated from % to % chars '
                '(pgmnemo.max_query_text_chars)',
                length(p_lesson_text), _max_chars;
            p_lesson_text := left(p_lesson_text, _max_chars);
        END IF;
    END IF;

    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION
            'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, verified_at
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
    'Validated public write API. v0.5.0: truncates lesson_text to '
    'pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE on truncation. '
    'NULL / empty lesson_text bypasses the truncation check. '
    'Set GUC to 0 or negative to disable. R5 (v0.5.0).';


-- ─────────────────────────────────────────────────────────────────────────────
-- §D  R6: pgmnemo.add_edge() — idiomatic upsert helper for mem_edge
--
-- Encapsulates the INSERT ... ON CONFLICT pattern from SQL_REFERENCE.md §1.1.
-- Three update-policy modes:
--   'replace' (default) — last-writer-wins (SET weight = EXCLUDED.weight)
--   'max'               — monotonic non-decreasing (GREATEST of old / new)
--   'avg'               — running average ((old + new) / 2)
--
-- A partial unique index ix_mem_edge_active_upsert enables ON CONFLICT on the
-- active (valid_until IS NULL) edge without changing the existing uq_mem_edge
-- constraint (which includes valid_from for historical edge retention).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS ix_mem_edge_active_upsert
    ON pgmnemo.mem_edge (source_id, target_id, relation_type)
    WHERE valid_until IS NULL;

CREATE OR REPLACE FUNCTION pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_edge_kind     pgmnemo.edge_kind DEFAULT 'semantic',
    p_weight        FLOAT8            DEFAULT 1.0,
    p_metadata      JSONB             DEFAULT '{}'::jsonb,
    p_mode          TEXT              DEFAULT 'replace'
) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    p_weight := GREATEST(0.0, LEAST(1.0, COALESCE(p_weight, 1.0)));

    IF p_mode NOT IN ('replace', 'max', 'avg') THEN
        RAISE EXCEPTION
            'pgmnemo.add_edge: unknown mode ''%'' — valid values: replace, max, avg',
            p_mode;
    END IF;

    IF p_mode = 'replace' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, p_edge_kind,
             p_weight::REAL, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type)
            WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = EXCLUDED.weight,
            metadata   = EXCLUDED.metadata,
            updated_at = now();

    ELSIF p_mode = 'max' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, p_edge_kind,
             p_weight::REAL, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type)
            WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = GREATEST(pgmnemo.mem_edge.weight, EXCLUDED.weight),
            metadata   = EXCLUDED.metadata,
            updated_at = now();

    ELSIF p_mode = 'avg' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, p_edge_kind,
             p_weight::REAL, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type)
            WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = (pgmnemo.mem_edge.weight + EXCLUDED.weight) / 2.0,
            metadata   = EXCLUDED.metadata,
            updated_at = now();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.add_edge(BIGINT, BIGINT, TEXT, pgmnemo.edge_kind, FLOAT8, JSONB, TEXT) IS
    'Idiomatic upsert helper for pgmnemo.mem_edge (R6, v0.5.0). '
    'Parameters: p_source_id / p_target_id (BIGINT FK → agent_lesson.id), '
    'p_relation_type (TEXT; e.g. CAUSED_BY / CO_OCCURRED / DERIVED_FROM / ENTITY_LINK), '
    'p_edge_kind (pgmnemo.edge_kind ENUM, default ''semantic''), '
    'p_weight (FLOAT8 clamped to [0.0,1.0], default 1.0), '
    'p_metadata (JSONB, default ''{}''::jsonb), '
    'p_mode (TEXT: ''replace''|''max''|''avg'', default ''replace''). '
    'ON CONFLICT uses ix_mem_edge_active_upsert partial index '
    '(source_id, target_id, relation_type) WHERE valid_until IS NULL. '
    'NULL p_source_id or p_target_id raises NOT NULL constraint violation. '
    'See SQL_REFERENCE.md §1.2 for relation_type → edge_kind mapping. '
    'R6 (v0.5.0).';

-- ─────────────────────────────────────────────────────────────────────────────
-- §3 R5 (cont.): ingest() — truncate lesson_text to max_query_text_chars
--
-- Replaces v0.4.1 ingest() with R5 truncation guard on p_lesson_text.
-- NULL/empty lesson_text produces a RAISE NOTICE and proceeds (the DB NOT NULL
-- constraint on lesson_text will reject a true NULL; empty string is stored).
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
    p_metadata      JSONB        DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    new_id      BIGINT;
    _max_chars  INT;
BEGIN
    -- R5: truncate lesson_text to pgmnemo.max_query_text_chars (default 2000).
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );

    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) = 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text is NULL or empty — proceeding.';
    ELSIF length(p_lesson_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text truncated to % chars (pgmnemo.max_query_text_chars). '
                     'Original length: %', _max_chars, length(p_lesson_text);
        p_lesson_text := left(p_lesson_text, _max_chars);
    END IF;

    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, verified_at
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
    'Validated public write API (v0.5.0 + R5). '
    'Truncates p_lesson_text to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'NULL/empty lesson_text emits NOTICE and proceeds to DB constraint enforcement. '
    'Use SET pgmnemo.max_query_text_chars = ''N'' to override per-session.';

-- ─────────────────────────────────────────────────────────────────────────────
-- §4 R6: pgmnemo.add_edge() — idempotent edge helper (v0.5.0)
--
-- Inserts a directed typed edge into pgmnemo.mem_edge.  On conflict on the
-- active edge (source_id, target_id, relation_type) WHERE valid_until IS NULL,
-- updates weight and metadata per the selected mode.
--
-- Parameters:
--   p_source_id     BIGINT  — source lesson id (FK → pgmnemo.agent_lesson.id)
--   p_target_id     BIGINT  — target lesson id (FK → pgmnemo.agent_lesson.id)
--   p_relation_type TEXT    — relation type (e.g. CAUSED_BY, CO_OCCURRED, DERIVED_FROM)
--   p_weight        FLOAT8  — edge weight in [0.0, 1.0] (default 1.0)
--   p_metadata      JSONB   — arbitrary metadata (default '{}')
--   p_mode          TEXT    — conflict resolution: 'replace' (default), 'max', 'avg'
--
-- edge_kind is derived from relation_type using the canonical mapping in SQL_REFERENCE §1.1.
-- ─────────────────────────────────────────────────────────────────────────────

-- Partial unique index on active edges — enables ON CONFLICT for add_edge().
-- "Active" = valid_until IS NULL (the current open edge; no end time set).
CREATE UNIQUE INDEX IF NOT EXISTS uq_mem_edge_active
    ON pgmnemo.mem_edge (source_id, target_id, relation_type)
    WHERE valid_until IS NULL;

CREATE OR REPLACE FUNCTION pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}'::jsonb,
    p_mode          TEXT    DEFAULT 'replace'
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    _edge_kind pgmnemo.edge_kind;
    _weight    REAL := GREATEST(0.0, LEAST(1.0, COALESCE(p_weight, 1.0)));
BEGIN
    -- Derive edge_kind from relation_type (canonical mapping, SQL_REFERENCE §1.1).
    _edge_kind := CASE
        WHEN p_relation_type IN ('CAUSED_BY', 'DERIVED_FROM', 'CONTRADICTS') THEN 'causal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('CO_OCCURRED', 'PRECEDED_BY')               THEN 'temporal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('ENTITY_LINK', 'SHARED_TAG', 'IS_A', 'PART_OF') THEN 'entity'::pgmnemo.edge_kind
        ELSE                                                                       'semantic'::pgmnemo.edge_kind
    END;

    IF p_mode = 'max' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind, _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT ON CONSTRAINT uq_mem_edge_active
        DO UPDATE SET
            weight     = GREATEST(pgmnemo.mem_edge.weight, EXCLUDED.weight),
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();

    ELSIF p_mode = 'avg' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind, _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT ON CONSTRAINT uq_mem_edge_active
        DO UPDATE SET
            weight     = (pgmnemo.mem_edge.weight + EXCLUDED.weight) / 2.0,
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();

    ELSE
        -- mode='replace' (default): last-writer-wins
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind, _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT ON CONSTRAINT uq_mem_edge_active
        DO UPDATE SET
            weight     = EXCLUDED.weight,
            metadata   = EXCLUDED.metadata,
            updated_at = now();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.add_edge(BIGINT, BIGINT, TEXT, FLOAT8, JSONB, TEXT) IS
    'Idempotent edge helper (R6, v0.5.0). '
    'Inserts or updates a directed typed edge in pgmnemo.mem_edge. '
    'edge_kind derived automatically from relation_type (SQL_REFERENCE §1.1 mapping). '
    'Conflict resolved on uq_mem_edge_active index (source_id, target_id, relation_type WHERE valid_until IS NULL). '
    'p_mode: ''replace'' (default, last-writer-wins) | ''max'' (monotonic weight) | ''avg'' (running mean). '
    'p_weight clamped to [0.0, 1.0]. '
    'FK violation on unknown source_id/target_id is returned to the caller (not caught). '
    'Example: SELECT pgmnemo.add_edge(1, 2, ''CAUSED_BY'', 0.9, ''{}'', ''max'');';

-- ─────────────────────────────────────────────────────────────────────────────
-- R6 FIXUP: Replace the 6-param add_edge() with a corrected version.
--
-- The previous CREATE OR REPLACE used ON CONFLICT ON CONSTRAINT uq_mem_edge_active
-- which does not exist. Replace with the partial-index ON CONFLICT syntax that
-- matches ix_mem_edge_active_upsert (created above). This CREATE OR REPLACE
-- overwrites the broken version registered earlier in this upgrade script.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}'::jsonb,
    p_mode          TEXT    DEFAULT 'replace'
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    _edge_kind pgmnemo.edge_kind;
    _weight    REAL := GREATEST(0.0, LEAST(1.0, COALESCE(p_weight, 1.0)));
BEGIN
    _edge_kind := CASE
        WHEN p_relation_type IN ('CAUSED_BY', 'DERIVED_FROM', 'CONTRADICTS')        THEN 'causal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('CO_OCCURRED', 'PRECEDED_BY')                      THEN 'temporal'::pgmnemo.edge_kind
        WHEN p_relation_type IN ('ENTITY_LINK', 'SHARED_TAG', 'IS_A', 'PART_OF')    THEN 'entity'::pgmnemo.edge_kind
        ELSE                                                                              'semantic'::pgmnemo.edge_kind
    END;

    IF p_mode NOT IN ('replace', 'max', 'avg') THEN
        RAISE EXCEPTION 'pgmnemo.add_edge: unknown mode ''%'' — valid values: replace, max, avg', p_mode;
    END IF;

    IF p_mode = 'max' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind, _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = GREATEST(pgmnemo.mem_edge.weight, EXCLUDED.weight),
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();
    ELSIF p_mode = 'avg' THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind, _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = (pgmnemo.mem_edge.weight + EXCLUDED.weight) / 2.0,
            metadata   = pgmnemo.mem_edge.metadata || EXCLUDED.metadata,
            updated_at = now();
    ELSE
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata)
        VALUES
            (p_source_id, p_target_id, p_relation_type, _edge_kind, _weight, COALESCE(p_metadata, '{}'))
        ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
        DO UPDATE SET
            weight     = EXCLUDED.weight,
            metadata   = EXCLUDED.metadata,
            updated_at = now();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.add_edge(BIGINT, BIGINT, TEXT, FLOAT8, JSONB, TEXT) IS
    'Idempotent edge upsert helper (R6, v0.5.0). 6-param form: auto-derives edge_kind '
    'from relation_type per SQL_REFERENCE §1.1 canonical mapping. '
    'p_mode: ''replace'' (default) | ''max'' (monotonic weight) | ''avg'' (running average). '
    'ON CONFLICT uses ix_mem_edge_active_upsert (source_id, target_id, relation_type) '
    'WHERE valid_until IS NULL. p_weight clamped to [0.0, 1.0]. '
    'For explicit edge_kind, use 7-param overload add_edge(BIGINT,BIGINT,TEXT,edge_kind,FLOAT8,JSONB,TEXT). '
    'NULL source_id/target_id raises NOT NULL constraint violation. R6 (v0.5.0).';

-- ─────────────────────────────────────────────────────────────────────────────
-- R6: 5-param convenience overload — add_edge(source_id, target_id, relation_type,
--     weight DEFAULT 1.0, metadata DEFAULT '{}')
--
-- Thin wrapper over the 6-param form with mode hard-coded to 'replace'
-- (last-writer-wins ON CONFLICT).  Matches the canonical task-spec signature:
--
--   pgmnemo.add_edge(source_id BIGINT, target_id BIGINT, relation_type TEXT,
--                    weight FLOAT8 DEFAULT 1.0, metadata JSONB DEFAULT '{}')
--
-- Acceptance gate: SELECT pgmnemo.add_edge(NULL::BIGINT, NULL::BIGINT, 'test')
-- raises a NOT NULL constraint violation on mem_edge (FK propagates to caller;
-- no null-pointer dereference in PL/pgSQL).
--
-- Note: source_id / target_id are BIGINT FK → pgmnemo.agent_lesson.id (BIGSERIAL).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}'::jsonb
) RETURNS VOID
LANGUAGE sql AS $$
    SELECT pgmnemo.add_edge(p_source_id, p_target_id, p_relation_type,
                            p_weight, p_metadata, 'replace');
$$;

COMMENT ON FUNCTION pgmnemo.add_edge(BIGINT, BIGINT, TEXT, FLOAT8, JSONB) IS
    'Convenience 5-param overload (R6, v0.5.0). Calls add_edge/6 with mode=''replace''. '
    'Parameters: source_id BIGINT, target_id BIGINT, relation_type TEXT, '
    'weight FLOAT8 DEFAULT 1.0, metadata JSONB DEFAULT ''{}''. '
    'ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL '
    'DO UPDATE SET weight=EXCLUDED.weight, metadata=EXCLUDED.metadata, updated_at=now(). '
    'NULL source_id/target_id raises NOT NULL constraint violation (FK → agent_lesson.id). '
    'R6 (v0.5.0) — see SQL_REFERENCE.md §1.2.';
