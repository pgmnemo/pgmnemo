-- pgmnemo--0.12.2--0.13.0.sql
-- Upgrade: 0.12.2 → 0.13.0 — Outcome Loop v2 (posterior confidence + use-attribution + min_score)
-- SPDX-License-Identifier: Apache-2.0

-- §1: Add use_count column (tracks confirmed attribution separate from recall_count)
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS use_count INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN pgmnemo.agent_lesson.use_count IS
    'Number of times this lesson was confirmed used (p_used=TRUE or NULL). '
    'Separate from recall_count (shown) and success_count+fail_count (outcome). '
    'Added in v0.13.0.';

-- §2a: Backfill use_count from existing observations
UPDATE pgmnemo.agent_lesson
SET use_count = success_count + fail_count
WHERE success_count + fail_count > 0;

-- §2b: Recompute confidence via Beta(1,1) posterior for lessons with observations
UPDATE pgmnemo.agent_lesson
SET confidence = LEAST(1.0, GREATEST(0.0,
    (success_count + 1.0) / (success_count + fail_count + 2.0)
))::REAL
WHERE success_count + fail_count > 0;

-- §2c: Reset confidence to 0.5 for zero-observation lessons (prior mean with Beta(1,1))
UPDATE pgmnemo.agent_lesson
SET confidence = 0.5
WHERE success_count = 0 AND fail_count = 0
  AND confidence != 0.5;

-- §3: New 3-param scalar reinforce (v0.13.0 — posterior confidence + use-attribution)
-- NOTE: p_used has NO DEFAULT — use the 2-param shim (§5) for backward compat (p_used=NULL).
-- Removing DEFAULT prevents ambiguity with the 2-param overload during resolution.
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id  BIGINT,
    p_outcome    TEXT,
    p_used       BOOLEAN
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _row            pgmnemo.agent_lesson%ROWTYPE;
    _new_conf       REAL;
    _mode           TEXT;
    _alpha          DOUBLE PRECISION;
    _beta           DOUBLE PRECISION;
    _success_delta  DOUBLE PRECISION;
    _fail_delta     DOUBLE PRECISION;
    _effective_used BOOLEAN;
BEGIN
    -- Resolve effective p_used: NULL → TRUE (backward compat)
    _effective_used := COALESCE(p_used, TRUE);

    -- Read confidence mode
    -- current_setting(..., TRUE) returns NULL when unset and never raises,
    -- so no exception wrapper: an unknown mode MUST surface, not silently
    -- fall back (a swallowed RAISE here defeats the validation entirely).
    _mode := COALESCE(
        NULLIF(current_setting('pgmnemo.confidence_mode', TRUE), ''),
        'posterior');
    IF _mode NOT IN ('posterior', 'additive') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown confidence_mode ''%'' — expected ''posterior'' or ''additive''',
            _mode;
    END IF;

    -- Lock row
    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    -- If lesson was not used, skip count update — preserve confidence
    IF NOT _effective_used THEN
        RETURN _row.confidence;
    END IF;

    -- Update outcome counters (always, regardless of mode)
    CASE p_outcome
        WHEN 'success' THEN
            UPDATE pgmnemo.agent_lesson
            SET success_count   = _row.success_count + 1,
                use_count       = _row.use_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            UPDATE pgmnemo.agent_lesson
            SET fail_count      = _row.fail_count + 1,
                use_count       = _row.use_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            -- Neutral: increment use_count but not success/fail
            UPDATE pgmnemo.agent_lesson
            SET use_count       = _row.use_count + 1,
                last_outcome    = 'neutral',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;
            RETURN _row.confidence;  -- no confidence change for neutral

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' — expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    -- Compute new confidence
    IF _mode = 'posterior' THEN
        -- Read prior hyperparameters
        BEGIN
            _alpha := GREATEST(0.01, LEAST(100.0, COALESCE(
                NULLIF(current_setting('pgmnemo.confidence_prior_alpha', TRUE), '')::DOUBLE PRECISION,
                1.0)));
        EXCEPTION WHEN OTHERS THEN _alpha := 1.0;
        END;

        BEGIN
            _beta := GREATEST(0.01, LEAST(100.0, COALESCE(
                NULLIF(current_setting('pgmnemo.confidence_prior_beta', TRUE), '')::DOUBLE PRECISION,
                1.0)));
        EXCEPTION WHEN OTHERS THEN _beta := 1.0;
        END;

        -- Read updated counts (after the UPDATE above)
        SELECT success_count, fail_count INTO _row.success_count, _row.fail_count
        FROM pgmnemo.agent_lesson WHERE id = p_lesson_id;

        _new_conf := ((_row.success_count + _alpha) /
                      (_row.success_count + _row.fail_count + _alpha + _beta))::REAL;

    ELSE  -- 'additive' (legacy, deprecated)
        BEGIN
            _success_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
                NULLIF(current_setting('pgmnemo.reinforce_success_delta', TRUE), '')::DOUBLE PRECISION,
                0.02)));
        EXCEPTION WHEN OTHERS THEN _success_delta := 0.02;
        END;

        BEGIN
            _fail_delta := GREATEST(0.001, LEAST(0.5, COALESCE(
                NULLIF(current_setting('pgmnemo.reinforce_fail_delta', TRUE), '')::DOUBLE PRECISION,
                0.12)));
        EXCEPTION WHEN OTHERS THEN _fail_delta := 0.12;
        END;

        IF p_outcome = 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
        ELSE  -- failure (neutral already returned above)
            _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
        END IF;
    END IF;

    -- Clamp and persist
    _new_conf := LEAST(1.0, GREATEST(0.0, _new_conf));

    UPDATE pgmnemo.agent_lesson
    SET confidence = _new_conf
    WHERE id = p_lesson_id;

    RETURN _new_conf;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT, BOOLEAN) IS
    'v0.13.0 Outcome Loop v2. '
    'p_outcome: ''success'' | ''failure'' | ''neutral'' (exact case). '
    'p_used: NULL/TRUE = lesson was used (counts updated, confidence recomputed); '
    '        FALSE = lesson shown but not used (no count/confidence change). '
    'Mode pgmnemo.confidence_mode: ''posterior'' (default, Beta posterior mean) '
    'or ''additive'' (legacy delta scheme, deprecated). '
    'Prior: pgmnemo.confidence_prior_alpha/beta (default 1.0/1.0 = uniform).';

-- §4: New 3-param batch reinforce (delegates to scalar form)
-- NOTE: p_used has NO DEFAULT — use 2-param shim (§5b) for backward compat.
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_ids  BIGINT[],
    p_outcome     TEXT,
    p_used        BOOLEAN
)
RETURNS INT
LANGUAGE plpgsql
AS $func$
DECLARE
    _id              BIGINT;
    _count           INT := 0;
    _effective_used  BOOLEAN;
BEGIN
    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    IF p_outcome NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' — expected ''success'', ''failure'', or ''neutral''',
            p_outcome;
    END IF;

    _effective_used := COALESCE(p_used, TRUE);

    FOREACH _id IN ARRAY p_lesson_ids LOOP
        BEGIN
            PERFORM pgmnemo.reinforce(_id, p_outcome, _effective_used);
            _count := _count + 1;
        EXCEPTION WHEN OTHERS THEN
            -- Skip missing lesson_ids silently (batch contract)
            NULL;
        END;
    END LOOP;

    RETURN _count;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT[], TEXT, BOOLEAN) IS
    'v0.13.0 batch reinforce. Delegates to scalar form per id. '
    'Skips missing/errored ids silently. Returns count updated.';

-- §5: Update 2-param scalar reinforce to delegate to 3-param (backward compat)
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
BEGIN
    RETURN pgmnemo.reinforce(p_lesson_id, p_outcome, NULL::BOOLEAN);
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'v0.13.0 compat shim: delegates to reinforce(BIGINT, TEXT, BOOLEAN) with p_used=NULL. '
    'DEPRECATED: use 3-param form. Will be removed in v0.14.0.';

-- §5b: Update 2-param batch reinforce to delegate to 3-param
-- BACKWARD-COMPAT: neutral returns 0 (no writes) matching pre-v0.13.0 contract.
-- Callers upgrading to 3-param can pass p_used=TRUE to get use_count tracking for neutral.
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_ids BIGINT[],
    p_outcome    TEXT
)
RETURNS INT
LANGUAGE plpgsql
AS $func$
BEGIN
    -- Legacy contract: 2-param batch with 'neutral' is a no-op, returns 0.
    -- Use 3-param form with p_used=TRUE to track attribution on neutral outcomes.
    IF p_outcome = 'neutral' THEN
        RETURN 0;
    END IF;
    RETURN pgmnemo.reinforce(p_lesson_ids, p_outcome, NULL::BOOLEAN);
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT[], TEXT) IS
    'v0.13.0 compat shim: delegates to reinforce(BIGINT[], TEXT, BOOLEAN) with p_used=NULL. '
    'Neutral outcome returns 0 (no writes) to preserve pre-v0.13.0 contract. '
    'DEPRECATED: use 3-param form. Will be removed in v0.14.0.';

-- §6: recall_hybrid — add p_min_score (11th param)
--
-- Drop old 10-param overload to prevent ambiguous-function errors.
-- The 11-param version is backward-compatible: p_min_score DEFAULT NULL.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_hybrid(
    vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[]
);

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL,
    p_content_types   text[]           DEFAULT NULL,
    p_min_score       REAL             DEFAULT NULL   -- NEW: selectivity gate on match_confidence
)
RETURNS TABLE (
    lesson_id        BIGINT,
    score            DOUBLE PRECISION,
    vec_score        DOUBLE PRECISION,
    bm25_score       DOUBLE PRECISION,
    rrf_score        DOUBLE PRECISION,
    role             TEXT,
    project_id       INT,
    topic            TEXT,
    lesson_text      TEXT,
    importance       SMALLINT,
    metadata         JSONB,
    commit_sha       TEXT,
    artifact_hash    TEXT,
    verified_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ,
    confidence       REAL,
    match_confidence REAL
)
LANGUAGE plpgsql
VOLATILE
AS $func$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _raw_blend_weight   DOUBLE PRECISION;
    _ghost_count        INT;
    _fetch_k_vec        INT;
    _fetch_k_bm25       INT;
    _conf_boost_w       DOUBLE PRECISION;
    -- 0.10.1 additions (#87)
    _lexical_text       TEXT;
    _bm25_budget_ms     INT;
    _bm25_timed_out     BOOLEAN := FALSE;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION
            'pgmnemo.recall_hybrid: both query_embedding and query_text are NULL/empty -- '
            'at least one retrieval signal is required';
    END IF;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    vec_weight  := GREATEST(0.0, LEAST(1.0, vec_weight));
    bm25_weight := GREATEST(0.0, LEAST(1.0, bm25_weight));
    _rrf_k_f    := GREATEST(1.0, rrf_k::DOUBLE PRECISION);
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        _ef_search := 100;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.2;
    END;

    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
    END;

    BEGIN
        _bm25_budget_ms := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.bm25_budget_ms', TRUE), '')::INT, 250));
    EXCEPTION WHEN OTHERS THEN _bm25_budget_ms := 250;
    END;

    IF _has_text THEN
        _lexical_text := left(trim(query_text), 200);
        BEGIN
            _tsquery := websearch_to_tsquery('simple', _lexical_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', _lexical_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    BEGIN
        CREATE TEMP TABLE _pgmnemo_bm25_work (
            id             BIGINT         PRIMARY KEY,
            raw_bm25_score DOUBLE PRECISION NOT NULL DEFAULT 0.0
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_bm25_work;
    END;

    IF _has_text THEN
        BEGIN
            EXECUTE format('SET LOCAL statement_timeout = %s', _bm25_budget_ms);

            INSERT INTO _pgmnemo_bm25_work (id, raw_bm25_score)
            SELECT
                al.id,
                ts_rank_cd(al.full_text, _tsquery, 32)::DOUBLE PRECISION
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.full_text @@ _tsquery
              AND (_include_unverified OR al.verified_at IS NOT NULL)
              AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
              AND (recall_hybrid.project_id_filter IS NULL
                   OR al.project_id = recall_hybrid.project_id_filter)
              AND (recall_hybrid.exclude_dag_id IS NULL
                   OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
              -- P0.2: typed recall pushdown into BM25 subplan (ix_pgmnemo_content_type_active)
              AND (recall_hybrid.p_content_types IS NULL
                   OR al.content_type = ANY(recall_hybrid.p_content_types))
              AND (_as_of_ts IS NULL
                   OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
              AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY 2 DESC
            LIMIT _fetch_k_bm25;

            EXECUTE 'SET LOCAL statement_timeout = 0';

        EXCEPTION WHEN query_canceled THEN
            _bm25_timed_out := TRUE;
            _has_text       := FALSE;
            RAISE NOTICE
                'pgmnemo.recall_hybrid: BM25 signal exceeded %ms budget — degrading to '
                'vector-only recall. Tune pgmnemo.bm25_budget_ms or shorten query_text.',
                _bm25_budget_ms;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    vec_candidates AS (
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS raw_vec_score
        FROM pgmnemo.agent_lesson al
        WHERE _has_vec
          AND al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (recall_hybrid.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
          -- P0.2: typed recall pushdown into vector subplan (ix_pgmnemo_content_type_active)
          AND (recall_hybrid.p_content_types IS NULL
               OR al.content_type = ANY(recall_hybrid.p_content_types))
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT _fetch_k_vec
    ),
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM vec_candidates v
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        SELECT
            al.id, al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            bw.raw_bm25_score
        FROM _pgmnemo_bm25_work bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE bw.id NOT IN (SELECT id FROM vec_candidates)
    ),
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC) AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                           AS bm25_rank_sparse
        FROM all_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at, r.confidence,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 vec_weight  * r.raw_vec_score
               + bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    final AS (
        SELECT
            s.id,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.025 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.025 * s.confidence::DOUBLE PRECISION
                  + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                               EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0), 1.0))
                  + 0.05 * (CASE
                                WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                                WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                                ELSE 0.0 END)
                )
              + _conf_boost_w * (s.confidence::DOUBLE PRECISION - 0.5)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    final_results AS MATERIALIZED (
        SELECT
            f.id                   AS lesson_id,
            f.final_score          AS score,
            f.v_score              AS vec_score,
            f.b_score              AS bm25_score,
            f.rrf_sparse           AS rrf_score,
            f.role,
            f.project_id,
            f.topic,
            f.lesson_text,
            f.importance,
            f.metadata,
            f.commit_sha,
            f.artifact_hash,
            f.verified_at,
            f.created_at,
            f.confidence::REAL,
            LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence
        FROM final f
        WHERE (p_min_score IS NULL
               OR LEAST(1.0, GREATEST(0.0, f.v_score))::REAL >= p_min_score)
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    ),
    _stamp AS (
        UPDATE pgmnemo.agent_lesson
        SET last_recalled_at = NOW(),
            recall_count     = recall_count + 1
        WHERE id = ANY(ARRAY(SELECT lesson_id FROM final_results))
          AND COALESCE(
              NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
              TRUE)
        RETURNING id
    )
    SELECT
        fr.lesson_id, fr.score, fr.vec_score, fr.bm25_score, fr.rrf_score,
        fr.role, fr.project_id, fr.topic, fr.lesson_text, fr.importance,
        fr.metadata, fr.commit_sha, fr.artifact_hash, fr.verified_at, fr.created_at,
        fr.confidence, fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

    IF NOT FOUND AND p_min_score IS NULL THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND al.verified_at IS NULL
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % matching lesson(s) are unverified (ingested without commit_sha/artifact_hash) '
                'and excluded by default. SET pgmnemo.include_unverified = ''on'' for this session, '
                'or pass provenance on ingest.',
                _ghost_count;
        END IF;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[], REAL) IS
    'v0.13.0 — Outcome Loop v2: adds p_min_score REAL DEFAULT NULL (11th param). '
    'p_min_score: filter rows where match_confidence (= vec_score clamped to [0,1]) < p_min_score. '
    'NULL = no filter (backward-compatible). Ghost-lesson NOTICE fires only when p_min_score IS NULL. '
    'Inherits v0.11.0 (RFC-001 §D2 / P0.2: typed recall) and v0.10.1 (#87) fixes: '
    'query_text cap, indexed full_text BM25, bm25_budget_ms timeout, simple tsconfig. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'graph_proximity via mem_edge causal/temporal walk (depth ≤5). '
    'VOLATILE (side-effects: recency stamp, temp table _pgmnemo_bm25_work).';

-- §7: recall_fast — add p_min_score (7th param)
--
-- Drop old 6-param overload to prevent ambiguous-function errors.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT, TEXT[]);

CREATE OR REPLACE FUNCTION pgmnemo.recall_fast(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    exclude_dag_id    TEXT    DEFAULT NULL,
    p_content_types   TEXT[]  DEFAULT NULL,
    p_min_score       REAL    DEFAULT NULL  -- NEW
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
VOLATILE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _track_recency      BOOLEAN;
BEGIN
    -- Set HNSW ef_search from GUC (same pattern as recall_hybrid)
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    BEGIN
        _track_recency := COALESCE(
            NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN, TRUE);
    EXCEPTION WHEN OTHERS THEN _track_recency := TRUE;
    END;

    -- #84: reject NULL query_embedding early — HNSW-only path has no text fallback.
    -- recall_hybrid() accepts NULL query_embedding when query_text is present; recall_fast
    -- is vector-only and cannot fall back to BM25, so NULL embedding is always an error.
    IF query_embedding IS NULL THEN
        RAISE EXCEPTION
            'pgmnemo.recall_fast: query_embedding IS NULL -- '
            'a vector embedding is required for HNSW search. '
            'recall_fast has no text-only fallback; use recall_hybrid() '
            'if you have query_text but no embedding.';
    END IF;

    RETURN QUERY
    WITH fast_ranked AS (
        SELECT
            al.id,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS vec_score,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.commit_sha,
            al.artifact_hash,
            al.verified_at,
            al.created_at
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_fast.role_filter IS NULL
               OR al.role = recall_fast.role_filter)
          AND (recall_fast.project_id_filter IS NULL
               OR al.project_id = recall_fast.project_id_filter)
          AND (recall_fast.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_fast.exclude_dag_id)
          -- P0.2: typed recall pushdown (ix_pgmnemo_content_type_active)
          AND (recall_fast.p_content_types IS NULL
               OR al.content_type = ANY(recall_fast.p_content_types))
        ORDER BY al.embedding <=> query_embedding
        LIMIT k
    ),
    stamped AS (
        UPDATE pgmnemo.agent_lesson al2
        SET
            last_recalled_at = NOW(),
            recall_count     = al2.recall_count + 1
        FROM fast_ranked fr
        WHERE al2.id = fr.id
          AND _track_recency
        RETURNING al2.id
    )
    SELECT
        fr.id          AS lesson_id,
        fr.vec_score   AS score,
        fr.role,
        fr.project_id,
        fr.topic,
        fr.lesson_text,
        fr.importance,
        fr.metadata,
        fr.commit_sha,
        fr.artifact_hash,
        fr.verified_at,
        fr.created_at
    FROM fast_ranked fr
    -- stamped CTE is a side-effect sink; reference it to prevent optimiser elision
    LEFT JOIN stamped s ON s.id = fr.id
    WHERE (p_min_score IS NULL OR fr.vec_score::REAL >= p_min_score)
    ORDER BY fr.vec_score DESC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT, TEXT[], REAL) IS
    'HNSW-only vector recall — O(k log n), no BM25/graph/RRF. '
    'Uses ORDER BY embedding <=> query LIMIT k to activate the HNSW index. '
    'score = cosine similarity (1 - distance). '
    'Respects include_unverified, ef_search, track_recall_recency GUCs. '
    'Filters: role_filter, project_id_filter, exclude_dag_id (same as recall_hybrid). '
    'v0.10.0: default MCP recall path. Use recall_hybrid for full 6-signal fusion. '
    'v0.10.1 #84: raises EXCEPTION when query_embedding IS NULL (no text-only fallback). '
    'v0.11.1: p_content_types TEXT[] DEFAULT NULL (6th param) — typed recall pushdown '
    'using ix_pgmnemo_content_type_active. NULL=all types (backward-compatible). '
    'Non-NULL restricts candidates to the given content_type values before HNSW ranking. '
    'v0.13.0: p_min_score REAL DEFAULT NULL (7th param) — post-rank filter on vec_score.';

-- §8: recall_lessons — add p_min_score (9th param)
--
-- Drop old 8-param overload to prevent ambiguous-function errors.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ, TEXT, TEXT[]);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT         DEFAULT 10,
    role_filter       TEXT        DEFAULT NULL,
    project_id_filter INT         DEFAULT NULL,
    query_text        TEXT        DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ DEFAULT NULL,
    exclude_dag_id    TEXT        DEFAULT NULL,
    p_content_types   TEXT[]      DEFAULT NULL,
    p_min_score       REAL        DEFAULT NULL  -- NEW
)
RETURNS TABLE (
    lesson_id        BIGINT,
    score            DOUBLE PRECISION,
    role             TEXT,
    project_id       INT,
    topic            TEXT,
    lesson_text      TEXT,
    importance       SMALLINT,
    metadata         JSONB,
    commit_sha       TEXT,
    artifact_hash    TEXT,
    verified_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ,
    vec_score        DOUBLE PRECISION,
    bm25_score       DOUBLE PRECISION,
    rrf_score        DOUBLE PRECISION,
    confidence       REAL,
    match_confidence REAL
)
LANGUAGE plpgsql
VOLATILE
AS $func$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _ghost_count        INT;
BEGIN
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT, 2000);
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars. Original: %',
                     _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    _has_vec  := query_embedding IS NOT NULL;
    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;

    IF NOT _has_vec AND _has_text THEN
        RAISE NOTICE
            'pgmnemo: query_embedding IS NULL -- falling back to text-only recall; no semantic similarity';
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _disable_hybrid := FALSE;
    END;

    -- Hybrid path delegates to recall_hybrid (which handles stamping + exclude_dag_id)
    -- P0.2: p_content_types forwarded as the 10th argument of recall_hybrid().
    -- v0.13.0: p_min_score forwarded as the 11th argument of recall_hybrid().
    IF NOT _disable_hybrid AND _has_vec AND _has_text THEN
        IF as_of_ts IS NOT NULL THEN
            PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
        END IF;

        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score,
            h.confidence, h.match_confidence
        FROM pgmnemo.recall_hybrid(
            query_embedding, _query_text, k,
            role_filter, project_id_filter, 0.4, 0.4, 60,
            exclude_dag_id, p_content_types, p_min_score  -- pass p_min_score
        ) h;
        RETURN;
    END IF;

    -- Vector-only path (pgmnemo.disable_hybrid = 'true' or no query_text)
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100);
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION, 0.05);
    _temporal_boost := GREATEST(0.0, LEAST(20.0, COALESCE(
        NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION, 1.0)));
    _gamma := _gamma * _temporal_boost;

    BEGIN
        _graph_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));  -- Fix 5: OPT-IN default (was 0.2)
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;

    _has_text := _query_text IS NOT NULL AND length(trim(_query_text)) > 0;
    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(_query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', left(trim(_query_text), 200));   -- Fix 4+1
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    candidates AS (
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
            al.confidence,
            CASE
                WHEN al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS vec_score,
            CASE
                WHEN _has_text AND al.full_text @@ _tsquery     -- Fix 2: indexed full_text
                THEN ts_rank_cd(al.full_text, _tsquery)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS ft_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL
               OR al.project_id = recall_lessons.project_id_filter)
          AND (recall_lessons.exclude_dag_id IS NULL
               OR al.source_dag_id IS DISTINCT FROM recall_lessons.exclude_dag_id)
          AND (al.embedding IS NOT NULL OR _has_text)
          -- P0.2: typed recall pushdown (ix_pgmnemo_content_type_active)
          AND (recall_lessons.p_content_types IS NULL
               OR al.content_type = ANY(recall_lessons.p_content_types))
    ),
    anchors AS (
        SELECT id FROM candidates ORDER BY vec_score DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0  -- Fix 5
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),
    scored AS (
        SELECT
            c.id, c.role, c.project_id, c.topic, c.lesson_text, c.importance,
            c.metadata, c.commit_sha, c.artifact_hash, c.verified_at, c.created_at,
            c.confidence,
            c.vec_score,
            c.ft_score,
            (c.vec_score + _gamma * GREATEST(0.0, 1.0 - LEAST(
                 EXTRACT(EPOCH FROM (NOW() - c.created_at)) / (90.0 * 86400.0), 1.0
             ))) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
             + c.ft_score * 0.1
             AS combined_score
        FROM candidates c
        LEFT JOIN graph_proximity gp ON gp.lesson_id = c.id
    )
    SELECT
        s.id                  AS lesson_id,
        s.combined_score      AS score,
        s.role,
        s.project_id,
        s.topic,
        s.lesson_text,
        s.importance,
        s.metadata,
        s.commit_sha,
        s.artifact_hash,
        s.verified_at,
        s.created_at,
        s.vec_score,
        s.ft_score            AS bm25_score,
        0.0::DOUBLE PRECISION AS rrf_score,
        s.confidence::REAL,
        LEAST(1.0, GREATEST(0.0, s.vec_score))::REAL AS match_confidence
    FROM scored s
    WHERE (p_min_score IS NULL
           OR LEAST(1.0, GREATEST(0.0, s.vec_score))::REAL >= p_min_score)
    ORDER BY s.combined_score DESC, s.id ASC
    LIMIT k;

    IF NOT FOUND THEN
        SELECT COUNT(*)::INT INTO _ghost_count
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active AND al.t_valid_to = 'infinity'::TIMESTAMPTZ AND al.verified_at IS NULL
          AND (recall_lessons.role_filter IS NULL OR al.role = recall_lessons.role_filter)
          AND (recall_lessons.project_id_filter IS NULL
               OR al.project_id = recall_lessons.project_id_filter);
        IF _ghost_count > 0 THEN
            RAISE NOTICE
                'pgmnemo: % unverified lesson(s) excluded. '
                'SET pgmnemo.include_unverified = ''on'' to include them.',
                _ghost_count;
        END IF;
    END IF;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ, TEXT, TEXT[], REAL) IS
    'v0.13.0 hybrid router with diagnostic columns, typed recall, and min_score gate. '
    'Routes to recall_hybrid() when both query_embedding and query_text are present '
    '(and pgmnemo.disable_hybrid is FALSE/unset). '
    'Falls back to vector-only (HNSW + recency + graph) when query_text is absent. '
    'p_content_types TEXT[] DEFAULT NULL (8th param, v0.11.1): typed recall pushdown. '
    'p_min_score REAL DEFAULT NULL (9th param, v0.13.0): filter rows where '
    'match_confidence (vec_score clamped [0,1]) < p_min_score. NULL=no filter. '
    'On the hybrid path: both p_content_types and p_min_score forwarded to recall_hybrid(). '
    'On the vector-only path: p_min_score applied as WHERE filter on match_confidence. '
    'GIN-indexed for BM25 retrieval via ts_rank_cd in recall_hybrid(). '
    'Respects pgmnemo.disable_hybrid, ef_search, include_unverified, recency_weight, '
    'temporal_boost, graph_proximity_weight, max_query_text_chars GUCs.';

-- §9: recall_lessons_pooled — add p_min_score (4th param)
--
-- Drop old 3-param overload.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons_pooled(vector, INT, INT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons_pooled(
    query_embedding  vector(1024),
    k                INT              DEFAULT 10,
    app_id           INT              DEFAULT NULL,
    p_min_score      REAL             DEFAULT NULL  -- NEW
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
    SELECT lesson_id, score, role, project_id, topic, lesson_text,
           importance, metadata, commit_sha, artifact_hash, verified_at, created_at
    FROM pgmnemo.recall_lessons(query_embedding, k, NULL::TEXT, app_id, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT[], p_min_score);
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons_pooled(vector, INT, INT, REAL) IS
    'v0.13.0: Cross-role recall wrapper: calls recall_lessons() with role=NULL (pooled). '
    'p_min_score: filter rows where match_confidence < p_min_score (NULL=no filter). '
    'DEPRECATED 3-param form: use 4-param form.';

-- End of pgmnemo--0.12.2--0.13.0.sql
