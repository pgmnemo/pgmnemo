-- pgmnemo 0.5.1 → 0.6.0 upgrade migration
-- Changes:
--   §3  pgmnemo.stats()   — add ghost_count BIGINT column
--   §4  pgmnemo.ingest()  — RAISE NOTICE when bitemporal close+create fires (Q5 dedup obs.)
-- Backward compatibility: zero breaking changes (see PLAN_V060.md §2 audit).
-- Prerequisites: pgmnemo 0.5.1 installed. Requires pgvector.
-- Apply: ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';

-- ─────────────────────────────────────────────────────────────────────────────
-- §1, §2 (recall_hybrid + recall_lessons changes) deferred to v0.6.1.
--
-- The original v0.6.0 plan added bitemporal `as_of_ts` parameter to
-- recall_lessons() and made recall_hybrid() read pgmnemo.as_of_timestamp
-- GUC for temporal filtering. Implementation introduced a CTE refactor
-- that caused two runtime regressions (AmbiguousColumn on `role`,
-- UndefinedTable on `graph_walk`) caught by scripts/smoke_recall_hybrid.py.
--
-- Decision: ship v0.6.0 with the additive, side-effect-free items only
-- (ghost_count, NOTICE, recall_stats view, docs). recall_hybrid() and
-- recall_lessons() remain byte-identical to v0.5.1 — Δ=0 confirmed.
--
-- Bitemporal recall returns in v0.6.1 alongside the corrected RRF
-- variant (A-scale) after real-DB benchmark validation.
-- See spec/v060/INVESTIGATION_FIX_A_REGRESSION.md for context.

-- §3  pgmnemo.stats() — add ghost_count BIGINT (RFC Q4)
--
-- Return type changes (13 → 14 cols) → must DROP before CREATE.
-- ghost_count: active lessons with verified_at IS NULL (no provenance).
-- Distinct from orphan_count (functions not owned by extension).
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                    TEXT,
    lesson_count               BIGINT,
    embedded_count             BIGINT,
    embedding_coverage_pct     DOUBLE PRECISION,
    tsv_coverage_pct           DOUBLE PRECISION,
    mem_edge_count             BIGINT,
    recency_weight             DOUBLE PRECISION,
    ef_search                  INT,
    importance_weight          DOUBLE PRECISION,
    hybrid_enabled             BOOLEAN,
    recall_hybrid_available    BOOLEAN,
    oldest_lesson_age_days     INT,
    orphan_count               BIGINT,
    ghost_count                BIGINT     -- NEW v0.6.0: active lessons without provenance
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT
        pgmnemo.version()                                                          AS version,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.agent_lesson)                        AS lesson_count,
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson WHERE embedding IS NOT NULL)                    AS embedded_count,
        (SELECT CASE WHEN COUNT(*) > 0
                     THEN ROUND(100.0 *
                                SUM(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END)::NUMERIC
                                / COUNT(*), 2)::DOUBLE PRECISION
                     ELSE 0.0 END
         FROM pgmnemo.agent_lesson)                                                AS embedding_coverage_pct,
        (SELECT CASE WHEN COUNT(*) > 0
                     THEN ROUND(100.0 *
                                SUM(CASE WHEN lesson_tsv IS NOT NULL THEN 1 ELSE 0 END)::NUMERIC
                                / COUNT(*), 2)::DOUBLE PRECISION
                     ELSE 0.0 END
         FROM pgmnemo.agent_lesson)                                                AS tsv_coverage_pct,
        (SELECT COUNT(*)::BIGINT FROM pgmnemo.mem_edge)                            AS mem_edge_count,
        COALESCE(NULLIF(current_setting('pgmnemo.recency_weight',  TRUE), '')::DOUBLE PRECISION,
                 0.05)                                                             AS recency_weight,
        COALESCE(NULLIF(current_setting('pgmnemo.ef_search',       TRUE), '')::INT,
                 100)                                                              AS ef_search,
        COALESCE(NULLIF(current_setting('pgmnemo.importance_weight',TRUE), '')::DOUBLE PRECISION,
                 0.15)                                                             AS importance_weight,
        NOT COALESCE(current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
                     FALSE)                                                        AS hybrid_enabled,
        EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
        )                                                                          AS recall_hybrid_available,
        (SELECT COALESCE(
                    EXTRACT(EPOCH FROM (NOW() - MIN(created_at))) / 86400.0, 0
                )::INT
         FROM pgmnemo.agent_lesson)                                                AS oldest_lesson_age_days,
        -- orphan_count: pgmnemo-schema functions not owned by the extension
        (SELECT COUNT(*)::BIGINT
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         LEFT JOIN pg_depend d
             ON d.objid = p.oid AND d.deptype = 'e'
            AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
         WHERE n.nspname = 'pgmnemo'
           AND p.proname NOT LIKE '\_%' ESCAPE '\'
           AND d.objid IS NULL)                                                    AS orphan_count,
        -- ghost_count (v0.6.0): active lessons without provenance (RFC Q4)
        -- Definition: t_valid_to = 'infinity' (authoritative active-row indicator) AND verified_at IS NULL.
        -- NOTE: the RFC Q4 spec says "is_active = TRUE"; implementation uses t_valid_to = 'infinity'
        -- because _bitemporal_close_prior() trigger does NOT update is_active when closing rows.
        -- t_valid_to = 'infinity' is the correct semantic equivalent of "currently active".
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.6.0 diagnostic health-check. Adds ghost_count (RFC Q4). '
    'ghost_count: active lessons where verified_at IS NULL — no commit_sha AND no artifact_hash. '
    'Distinct from orphan_count (functions not owned by extension). '
    'Use ghost_count to track provenance migration progress: target < 5% of lesson_count '
    'before switching pgmnemo.include_unverified = off. '
    'Single-row summary; <50ms on N=10k corpus.';


-- ─────────────────────────────────────────────────────────────────────────────
-- §4  pgmnemo.ingest() — RAISE NOTICE on bitemporal close+create (RFC Q5)
--
-- Pre-insert content_hash check; RAISE NOTICE if dedup close fires.
-- content_hash formula matches GENERATED ALWAYS AS column:
--   MD5(COALESCE(role,'') || '|' || COALESCE(topic,'') || '|' || COALESCE(commit_sha, artifact_hash, ''))
-- No signature change → CREATE OR REPLACE sufficient.
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
    new_id          BIGINT;
    _max_chars      INT;
    _content_hash   TEXT;
    _prior_count    INT;
BEGIN
    -- R5: clamp lesson_text
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) = 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text is NULL or empty — proceeding.';
    ELSIF _max_chars > 0 AND length(p_lesson_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text truncated to % chars '
                     '(pgmnemo.max_query_text_chars). Original length: %',
                     _max_chars, length(p_lesson_text);
        p_lesson_text := left(p_lesson_text, _max_chars);
    END IF;

    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- Q5: compute content_hash to detect upcoming bitemporal close (dedup observability)
    -- Replicates GENERATED ALWAYS AS formula from agent_lesson.content_hash column.
    _content_hash := MD5(
        COALESCE(p_role, '')        || '|' ||
        COALESCE(p_topic, '')       || '|' ||
        COALESCE(p_commit_sha, COALESCE(p_artifact_hash, ''))
    );

    SELECT COUNT(*)::INT INTO _prior_count
    FROM pgmnemo.agent_lesson
    WHERE content_hash = _content_hash
      AND t_valid_to   = 'infinity'::TIMESTAMPTZ;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance, embedding,
        commit_sha, artifact_hash, metadata, verified_at
    ) VALUES (
        p_role, p_project_id, p_topic, p_lesson_text, p_importance, p_embedding,
        p_commit_sha, p_artifact_hash, p_metadata,
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
    ) RETURNING id INTO new_id;

    -- Q5: RAISE NOTICE if bitemporal close+create fired (trigger trg_agent_lesson_bitemporal_close)
    IF _prior_count > 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: bitemporal close+create fired — closed % prior version(s) '
                     '(content_hash=%). New lesson_id=%. '
                     'Prior row(s) now have t_valid_to=NOW().',
                     _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API (v0.6.0 + Q5). '
    'Q5: RAISE NOTICE when bitemporal close+create fires (dedup observability). '
    'Caller receives NOTICE "bitemporal close+create fired — closed N prior version(s)". '
    'On idempotent re-run (same args): NOTICE fires again if prior row was already closed+recreated. '
    'Truncates p_lesson_text to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'R5 (v0.5.0).';

-- ─── R9: recall hit-count metric view ────────────────────────────────────────
-- RFC R9 (deferred from v0.4.1). Requires track_functions = 'pl' or
-- 'all' in postgresql.conf; rows only appear after the first call post-reset.

CREATE OR REPLACE VIEW pgmnemo.recall_stats AS
SELECT
    n.nspname   AS schema,
    p.proname   AS function_name,
    s.calls,
    s.total_time,
    s.self_time,
    NOW()       AS observed_at
FROM pg_stat_user_functions s
JOIN pg_proc      p ON p.oid = s.funcid
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo'
  AND p.proname IN ('recall_lessons', 'recall_hybrid', 'ingest');

COMMENT ON VIEW pgmnemo.recall_stats IS
    'Observability view for recall/ingest call counts (R9, v0.6.0). '
    'Requires track_functions = ''pl'' or ''all'' in postgresql.conf. '
    'Rows appear only after first call following a pg_stat_reset().';
