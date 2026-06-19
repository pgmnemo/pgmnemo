-- pgmnemo--0.9.1--0.9.2.sql
-- Incremental upgrade: pgmnemo 0.9.1 → 0.9.2
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: I1 — Flag-gated confidence-weighted recall ranking
--
-- PROBLEM: reinforce() updates confidence but its contribution to final recall
--   score is ~0.000431 (via _aux_scale * 0.025 * confidence) — operationally
--   INERT. A full 0.0→1.0 confidence swing moves ~3 RRF positions at best.
--   The outcome-learning claim is marketing, not engineering.
--
-- FIX: Additive, zero-centered confidence boost in recall_hybrid():
--   final_score += w * (confidence - 0.5)
--   where w is read from GUC pgmnemo.confidence_boost_weight.
--   Cold-start (0.5) gets zero boost/penalty.
--   Strong tie-breaker, not driver: at w=0.003, high-vs-low delta ≈ 0.0024,
--   which moves ~8-15 RRF positions depending on table depth.
--
-- GUC: pgmnemo.confidence_boost_weight
--   DEFAULT 0.0 (OFF — byte-identical to 0.9.1 behavior)
--   RANGE: [0.0, 0.01]  (clamped)
--   RECOMMENDED ACTIVATION: 0.003
--   A/B-ready: SET pgmnemo.confidence_boost_weight = '0.003' enables the boost.
--   Activation gate: pending positive A/B validation.
--
-- ITEMS:
--   #1  recall_hybrid(): add _conf_boost_w variable + GUC read + additive term
--       in the `final` CTE (before graph multiplier).
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.2';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.2'" to load this file. \quit

-- ══════════════════════════════════════════════════════════════════════════════
-- #1: recall_hybrid — confidence-weighted ranking (I1)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Changes vs 0.9.1:
--   +  DECLARE: _conf_boost_w DOUBLE PRECISION
--   +  GUC read block for pgmnemo.confidence_boost_weight (default 0.0, clamp [0,0.01])
--   +  final CTE: + _conf_boost_w * (s.confidence::DOUBLE PRECISION - 0.5)
--      added after _aux_scale block, before graph multiplier.
--   +  COMMENT updated.
--
-- Signature unchanged (8 args) — CREATE OR REPLACE is safe, no DROP needed.
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60
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
STABLE
PARALLEL SAFE
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
    _ghost_count        INT;   -- F2: ghost guidance
    _fetch_k_vec        INT;   -- #4: bounded HNSW fetch
    _fetch_k_bm25       INT;   -- #4: bounded BM25 fetch
    _conf_boost_w       DOUBLE PRECISION;  -- I1: confidence boost weight
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

    -- I1: read confidence boost weight GUC (default 0.0 = OFF, clamped [0.0, 0.01])
    BEGIN
        _conf_boost_w := GREATEST(0.0, LEAST(0.01, COALESCE(
            NULLIF(current_setting('pgmnemo.confidence_boost_weight', TRUE), '')::DOUBLE PRECISION,
            0.0)));
    EXCEPTION WHEN OTHERS THEN _conf_boost_w := 0.0;
    END;

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('english', query_text);
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    -- #4 C2 fix: fetch_k floors — HNSW arm respects ef_search, BM25 arm floors at 40
    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    RETURN QUERY
    WITH RECURSIVE
    -- Phase 1: HNSW vector retrieval (index scan)
    vec_candidates AS (
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS raw_vec_score,
            0.0::DOUBLE PRECISION AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE _has_vec
          AND al.is_active
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding   -- HNSW index scan
        LIMIT _fetch_k_vec                           -- C2: GREATEST(k*4, _ef_search)
    ),
    -- Phase 2: GIN BM25 retrieval (index scan)
    bm25_candidates AS (
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at, al.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            ts_rank_cd(
                setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv,
                _tsquery, 32
            )::DOUBLE PRECISION AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE _has_text
          AND al.is_active
          AND (al.lesson_tsv @@ _tsquery
               OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY raw_bm25_score DESC
        LIMIT _fetch_k_bm25                          -- C2: GREATEST(k*4, 40)
    ),
    -- Merge: LEFT JOIN + anti-join UNION ALL (each id exactly once)
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(b.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM vec_candidates v
        LEFT JOIN bm25_candidates b ON b.id = v.id

        UNION ALL

        SELECT
            b.id, b.role, b.project_id, b.topic, b.lesson_text,
            b.importance, b.metadata, b.commit_sha, b.artifact_hash,
            b.verified_at, b.created_at, b.confidence,
            0.0::DOUBLE PRECISION AS raw_vec_score,
            b.raw_bm25_score
        FROM bm25_candidates b
        WHERE b.id NOT IN (SELECT id FROM vec_candidates)
    ),
    -- RRF ranking over bounded candidate set
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                              AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)   AS vec_rank,
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
            -- v0.8.1 F2: ordinal RRF + cardinal raw score blend
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
              -- I1: additive zero-centered confidence boost (w=0 when GUC off → no effect)
              + _conf_boost_w * (s.confidence::DOUBLE PRECISION - 0.5)
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    )
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
    ORDER BY f.final_score DESC, f.id ASC   -- C7: tie-breaker for determinism
    LIMIT k;

    -- F2: ghost guidance — if 0 rows returned, check for unverified (ghost) lessons in scope
    IF NOT FOUND THEN
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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'v0.9.2 — I1: confidence-weighted ranking (additive, zero-centered). '
    'GUC pgmnemo.confidence_boost_weight (default 0.0 = OFF, range [0.0, 0.01]). '
    'When ON: final_score += w * (confidence - 0.5). Recommended w=0.003. '
    'Cold-start (confidence=0.5) gets zero boost. High-vs-low delta at w=0.003 ≈ 0.0024 ≈ 8-15 RRF positions. '
    'Activation gate: pending positive A/B validation. '
    'v0.8.2 — F2: NOTICE when 0 rows returned and ghost lessons exist in scope. '
    'Two-phase indexed retrieval: HNSW (pgvector) + GIN (BM25) → RRF fusion → graph proximity boost. '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'STABLE PARALLEL SAFE.';

-- ══════════════════════════════════════════════════════════════════════════════
-- #2: reinforce() — base-rate-adjusted deltas + GUC-configurable (D1)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- PROBLEM: Shipped deltas (+0.10/-0.15) caused confidence to saturate, destroying discriminability.
--   At 83.5% base success rate, +0.10 saturates to ceiling — confidence always
--   drifts toward 1.0 and fails to differentiate.
--   Base-rate-adjusted deltas (+0.02/-0.12) restore discriminability; consistent
--   positive signal observed).
--
-- FIX: Change reinforce() defaults to +0.02/-0.12.
--   Expose as GUCs so operators can retune per-workload without extension upgrade.
--
-- GUCs:
--   pgmnemo.reinforce_success_delta  DEFAULT 0.02  RANGE [0.001, 0.5]
--   pgmnemo.reinforce_fail_delta     DEFAULT 0.12  RANGE [0.001, 0.5]  (applied negative)
--
-- Both scalar and batch forms (BIGINT, TEXT) and (BIGINT[], TEXT) are updated.
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.2';

-- Scalar reinforce(): GUC-aware delta reads, new base-rate-adjusted defaults
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
)
RETURNS REAL
LANGUAGE plpgsql
AS $func$
#variable_conflict use_column
DECLARE
    _row           pgmnemo.agent_lesson%ROWTYPE;
    _new_conf      REAL;
    _success_delta DOUBLE PRECISION;
    _fail_delta    DOUBLE PRECISION;
BEGIN
    -- D1: read reinforce deltas from GUC (base-rate-adjusted defaults)
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

    SELECT * INTO _row
    FROM pgmnemo.agent_lesson
    WHERE id = p_lesson_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reinforce: lesson_id % not found', p_lesson_id;
    END IF;

    CASE p_outcome
        WHEN 'success' THEN
            _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                success_count   = _row.success_count + 1,
                last_outcome    = 'success',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'failure' THEN
            _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
            UPDATE pgmnemo.agent_lesson
            SET confidence      = _new_conf,
                fail_count      = _row.fail_count + 1,
                last_outcome    = 'failure',
                last_outcome_at = NOW()
            WHERE id = p_lesson_id;

        WHEN 'neutral' THEN
            _new_conf := _row.confidence;

        ELSE
            RAISE EXCEPTION
                'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
                p_outcome;
    END CASE;

    RETURN _new_conf;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT, TEXT) IS
    'Outcome-learning update (v0.9.2/D1): adjusts confidence for lesson p_lesson_id. '
    'Exact case required: ''success'' | ''failure'' | ''neutral''. '
    'success: confidence += pgmnemo.reinforce_success_delta (default 0.02, clamped [0.001,0.5]). '
    'failure: confidence -= pgmnemo.reinforce_fail_delta    (default 0.12, clamped [0.001,0.5]). '
    'neutral: no-op — returns current confidence without any write. '
    'Unknown outcome string: RAISE EXCEPTION. '
    'Row-locked (SELECT ... FOR UPDATE) for concurrent-safe update on hot lessons. '
    'Defaults base-rate-adjusted for 83.5% success workload.';

-- Batch reinforce(): GUC-aware delta reads
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_ids BIGINT[],
    p_outcome    TEXT
)
RETURNS INT
LANGUAGE plpgsql
AS $func$
DECLARE
    _id            BIGINT;
    _row           pgmnemo.agent_lesson%ROWTYPE;
    _new_conf      REAL;
    _updated       INT := 0;
    _success_delta DOUBLE PRECISION;
    _fail_delta    DOUBLE PRECISION;
BEGIN
    -- Validate outcome up-front so the caller gets a clear error on bad input.
    IF p_outcome NOT IN ('success', 'failure', 'neutral') THEN
        RAISE EXCEPTION
            'pgmnemo.reinforce: unknown outcome ''%'' -- expected ''success'', ''failure'', or ''neutral''',
            p_outcome;
    END IF;

    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    -- D1: read reinforce deltas from GUC (base-rate-adjusted defaults)
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

    FOREACH _id IN ARRAY p_lesson_ids LOOP
        SELECT * INTO _row
        FROM pgmnemo.agent_lesson
        WHERE id = _id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- skip missing; no RAISE (bitemporal supersession / TTL normal)
        END IF;

        CASE p_outcome
            WHEN 'success' THEN
                _new_conf := LEAST(1.0, _row.confidence + _success_delta::REAL);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    success_count   = _row.success_count + 1,
                    last_outcome    = 'success',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'failure' THEN
                _new_conf := GREATEST(0.0, _row.confidence - _fail_delta::REAL);
                UPDATE pgmnemo.agent_lesson
                SET confidence      = _new_conf,
                    fail_count      = _row.fail_count + 1,
                    last_outcome    = 'failure',
                    last_outcome_at = NOW()
                WHERE id = _id;
                _updated := _updated + 1;

            WHEN 'neutral' THEN
                NULL;  -- no-op; does not increment _updated
        END CASE;
    END LOOP;

    RETURN _updated;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.reinforce(BIGINT[], TEXT) IS
    'Batch confidence update v0.9.2/D1. Iterates p_lesson_ids; skips missing IDs silently (no RAISE). '
    'Returns count of rows actually updated (neutral outcome does not increment count). '
    'Unknown outcome string raises RAISE EXCEPTION (caller programming error). '
    'Empty or NULL array returns 0. '
    'success: +pgmnemo.reinforce_success_delta (default 0.02), failure: -pgmnemo.reinforce_fail_delta (default 0.12). '
    'Scalar form reinforce(BIGINT, TEXT) unchanged (same GUC reads).';

COMMENT ON COLUMN pgmnemo.agent_lesson.confidence IS
    'Outcome-track-record confidence score [0.0, 1.0]. '
    'Default 0.5 (cold-start neutral). '
    'Updated by pgmnemo.reinforce(): success +pgmnemo.reinforce_success_delta (default 0.02), '
    'failure -pgmnemo.reinforce_fail_delta (default 0.12), neutral no-op. '
    'Clamped to [0.0, 1.0] by CHECK constraint + reinforce() logic. '
    'Defaults base-rate-adjusted for 83.5% base success rate.';
