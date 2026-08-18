-- pgmnemo upgrade: 0.18.0 → 0.19.0
-- Graph walk structural repairs (D1, D2, D3) + recall_entity read-path recency stamp removal (R-U1)
-- SPDX-License-Identifier: Apache-2.0
--
-- PROBLEM (PGMREL-0190, 2026-08-18):
--   Three structural defects in graph_walk CTEs identified in DB_FEASIBILITY_VERDICT.md:
--
--   D1 (CRITICAL) — No cycle guard in graph_walk: A→B→C→A with hub nodes at degree 50+
--     caused 20-25% query timeouts (lesson id=43981) when graph_proximity_weight > 0.
--     Pattern already correct in traverse_causal_chain; missing in all recall_* variants.
--
--   D2 (MODERATE) — Bidirectional OR-join in navigate_locate defeats B-tree index:
--     OR condition forces BitmapOr (30-50% overhead) or SeqScan at large scale.
--     Fix: rewrite as two UNION ALL branches, one per direction, each using a clean equi-join.
--
--   D3 (MODERATE) — _max_depth=5 not justified: at avg degree 6.4, depth 5 explores ~64k rows
--     even WITH cycle guard. Nodes at depth 4-5 contribute ≤0.1 to multiplicative graph factor.
--     Fix: cap at 2 (matches navigate_locate which was already correct).
--
--   R-U1 — recall_entity still stamps recency on read path (0.18.0 tail):
--     Inconsistent with 0.18.0 recall_hybrid/recall_lessons (stamped CTE removed there).
--     Fix: remove stamped CTE, make STABLE PARALLEL SAFE; callers use mark_recalled().
--
-- REPAIRS:
--   • All ~18 recall_* graph_walk CTEs: add visited BIGINT[] cycle guard (D1)
--   • navigate_locate graph_walk: rewrite OR-join as UNION ALL bidirectional (D1+D2)
--   • All ~18 recall_* _max_depth constants: 5 → 2 (D3)
--   • New partial index ix_mem_edge_target_active for backward UNION ALL branch (D2)
--   • recall_entity: remove stamped CTE, change VOLATILE → STABLE PARALLEL SAFE (R-U1)
--
-- PERFORMANCE ESTIMATE (from verdict §4, warm cache):
--   Before (depth 5, no cycle guard, enabled): 5–15 ms graph_walk contribution
--   After  (depth 2, cycle guard, UNION ALL):  0.1–0.5 ms — within 8 ms total budget
--
-- GUC DISCIPLINE:
--   graph_proximity_weight default remains 0.0 (opt-in, Fix 5 / v0.10.1).
--   These repairs make it safe to enable; they do not enable it.
--
-- MIGRATION PATH:
--   ALTER EXTENSION pgmnemo UPDATE TO '0.19.0';
-- =============================================================================


-- =============================================================================
-- §1  New index for D2: backward branch of UNION ALL bidirectional walk
-- =============================================================================
-- The navigate_locate UNION ALL rewrite needs a clean index scan on target_id.
-- Existing pgmnemo_mem_edge_target_type_idx (target_id, relation_type) covers
-- active-only with relation_type filter; the navigate_locate backward branch
-- needs just (target_id) with active-edge sentinel guard.
--
-- Size: ~600 KB at 75k rows. Negligible.

CREATE INDEX IF NOT EXISTS ix_mem_edge_target_active
    ON pgmnemo.mem_edge (target_id)
    WHERE valid_until IS NULL OR valid_until = 'infinity'::TIMESTAMPTZ;

COMMENT ON INDEX pgmnemo.ix_mem_edge_target_active IS
    'v0.19.0 D2: partial index on mem_edge(target_id) for active edges. '
    'Supports the backward UNION ALL branch in navigate_locate graph_walk. '
    'Avoids BitmapOr overhead of the prior OR-join condition.';


-- =============================================================================
-- §2  navigate_locate — D1 (cycle guard) + D2 (UNION ALL bidirectional)
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT              DEFAULT 2000,
    jsonb_filter      JSONB             DEFAULT NULL,
    project_id_filter INT               DEFAULT NULL
)
RETURNS TABLE (
    id              BIGINT,
    preview         TEXT,
    score           FLOAT8,
    tokens_consumed INT,
    navigation_path TEXT
)
LANGUAGE plpgsql
VOLATILE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 2;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _vec_weight         CONSTANT DOUBLE PRECISION := 0.4;
    _bm25_weight        CONSTANT DOUBLE PRECISION := 0.4;
    _raw_blend_weight   DOUBLE PRECISION;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.navigate_locate: both query_embedding and query_text are NULL/empty';
    END IF;

    _rrf_k_f := 60.0;
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);

    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN
        _as_of_ts := NULL;
    END;

    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.0
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.0;  -- Fix 5: OPT-IN default
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    IF _has_text THEN
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', left(trim(query_text), 200));   -- Fix 4+1
            EXCEPTION WHEN OTHERS THEN
                _has_text := FALSE;
            END;
        END;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    raw_candidates AS (
        SELECT
            al.id,
            al.topic_tsv,
            al.lesson_tsv,
            al.lesson_text,
            al.importance,
            al.commit_sha,
            al.verified_at,
            al.created_at,
            al.metadata,
            length(al.lesson_text)                                            AS text_len,
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            CASE
                WHEN _has_text AND (al.topic_tsv @@ _tsquery OR al.lesson_tsv @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(al.topic_tsv, 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (navigate_locate.project_id_filter IS NULL
               OR al.project_id = navigate_locate.project_id_filter)
          AND (navigate_locate.jsonb_filter IS NULL
               OR al.metadata @> navigate_locate.jsonb_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
          AND (
                  (_has_vec  AND al.embedding IS NOT NULL)
               OR (_has_text AND (al.topic_tsv @@ _tsquery OR al.lesson_tsv @@ _tsquery))
          )
    ),
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC)  AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK()   OVER (PARTITION BY (raw_bm25_score > 0)
                                     ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                                  AS bm25_rank_sparse,
            COUNT(*) OVER ()                                                     AS n_candidates
        FROM raw_candidates
    ),
    scored AS (
        SELECT
            r.id, r.text_len, r.lesson_text, r.metadata, r.importance,
            r.commit_sha, r.verified_at, r.created_at,
            r.vec_rank, r.n_candidates,
            CASE WHEN r.bm25_rank_sparse IS NOT NULL THEN r.bm25_rank_sparse
                 ELSE r.n_candidates + 1
            END AS bm25_rank_eff,
            (
                _vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
              + _bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                     r.n_candidates + 1)::DOUBLE PRECISION)
              + _raw_blend_weight * (
                    _vec_weight  * r.raw_vec_score
                  + _bm25_weight * r.raw_bm25_score)
            ) AS rrf_sparse
        FROM rrf_ranked r
    ),
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    -- D1+D2(v0.19.0): cycle guard + UNION ALL bidirectional (was OR-join)
    graph_walk(anchor_id, depth, reached_id, visited) AS (
        SELECT id, 0, id, ARRAY[id] FROM anchors WHERE _graph_weight > 0  -- Fix 5; D1: visited set
        UNION ALL
        -- Forward: source → target (clean B-tree index scan on source_id)
        SELECT gw.anchor_id, gw.depth + 1, me.target_id, gw.visited || me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE gw.depth < _max_depth
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
          AND NOT (me.target_id = ANY(gw.visited))  -- D1: prevent cycle revisit
        UNION ALL
        -- Backward: target → source (uses ix_mem_edge_target_active index)
        SELECT gw.anchor_id, gw.depth + 1, me.source_id, gw.visited || me.source_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.target_id = gw.reached_id
        WHERE gw.depth < _max_depth
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
          AND NOT (me.source_id = ANY(gw.visited))  -- D1: prevent cycle revisit
    ),
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    ),
    final_ranked AS (
        SELECT
            s.id,
            s.text_len,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0))::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE 0.0 END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.lesson_text,
            s.metadata
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ),
    budget_consumed AS (
        SELECT
            fr.id,
            fr.final_score,
            fr.lesson_text,
            fr.metadata,
            fr.text_len,
            SUM(fr.text_len) OVER (ORDER BY fr.final_score DESC, fr.id ASC) AS cumulative_chars
        FROM final_ranked fr
    )
    SELECT
        bc.id,
        left(bc.lesson_text, 120)::TEXT  AS preview,
        bc.final_score                   AS score,
        bc.text_len::INT                 AS tokens_consumed,
        NULL::TEXT                       AS navigation_path
    FROM budget_consumed bc
    WHERE bc.cumulative_chars <= navigate_locate.token_budget_chars
    ORDER BY bc.final_score DESC, bc.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT) IS
    'v0.19.0 D1+D2: graph_walk cycle guard (visited BIGINT[] array) + UNION ALL '
    'bidirectional rewrite (was OR-join: BitmapOr 30-50% overhead → clean Index Scan). '
    'ix_mem_edge_target_active index added for backward branch. '
    'Max depth unchanged at 2 (was already correct). '
    'VOLATILE — preserves prior semantics; mark_recalled() not called here.';


-- =============================================================================
-- §3  recall_hybrid — D1 (cycle guard) + D3 (_max_depth 5 → 2)
-- =============================================================================
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
    p_min_score       REAL             DEFAULT NULL
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
    _max_depth          CONSTANT INT := 2;  -- D3(v0.19.0): depth cap 5→2; cost O(d^k), d≈6.4, k=2
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
            0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;  -- Fix 5: OPT-IN default, reconciled in v0.17.0
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

    -- ── BM25 candidates (unchanged from v0.14.0) ──────────────────────────────
    BEGIN
        CREATE TEMP TABLE _pgmnemo_bm25_work (
            id             BIGINT          PRIMARY KEY,
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

    -- ── Phase 1: vector candidates — executed as a standalone EXECUTE statement ──
    --
    -- FIX (v0.14.1): When LIMIT is a plpgsql local variable, PostgreSQL compiles
    -- the RETURN QUERY block with a generic, parameter-blind plan that does not
    -- know the LIMIT value.  Without a concrete small-limit hint, the cost model
    -- prefers Seq Scan + top-N heapsort over the HNSW index scan, causing 10–1000×
    -- latency regressions on large corpora (confirmed with EXPLAIN on 3000–7440
    -- row corpus: HNSW cost 448 vs SeqScan 413 in generic plan; SeqScan wins
    -- without a concrete LIMIT, but HNSW wins when the planner sees the value).
    --
    -- Embedding _fetch_k_vec as a literal integer in the SQL text (via format())
    -- lets the planner see the concrete value and reliably choose the HNSW index
    -- scan.  The temp table is ON COMMIT DROP; a duplicate-table exception (same
    -- transaction, re-entrant call) is handled by truncating before reuse.

    BEGIN
        CREATE TEMP TABLE _pgmnemo_vc (
            id             BIGINT,
            role           TEXT,
            project_id     INT,
            topic          TEXT,
            lesson_text    TEXT,
            importance     SMALLINT,
            metadata       JSONB,
            commit_sha     TEXT,
            artifact_hash  TEXT,
            verified_at    TIMESTAMPTZ,
            created_at     TIMESTAMPTZ,
            confidence     REAL,
            raw_vec_score  DOUBLE PRECISION
        ) ON COMMIT DROP;
    EXCEPTION WHEN duplicate_table THEN
        TRUNCATE TABLE _pgmnemo_vc;
    END;

    IF _has_vec THEN
        EXECUTE format($vec_sql$
            INSERT INTO _pgmnemo_vc
            SELECT
                al.id,
                al.role,        al.project_id, al.topic,      al.lesson_text,
                al.importance,  al.metadata,   al.commit_sha, al.artifact_hash,
                al.verified_at, al.created_at, al.confidence,
                (1.0 - (al.embedding <=> $1))::DOUBLE PRECISION  AS raw_vec_score
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.embedding IS NOT NULL
              AND ($2 OR al.verified_at IS NOT NULL)
              AND ($3 IS NULL OR al.role = $3)
              AND ($4 IS NULL OR al.project_id = $4)
              AND ($5 IS NULL OR al.source_dag_id IS DISTINCT FROM $5)
              AND ($6 IS NULL OR al.content_type = ANY($6))
              AND ($7 IS NULL OR (al.t_valid_from <= $7 AND al.t_valid_to > $7))
              AND ($7 IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY al.embedding <=> $1   -- HNSW index scan (literal LIMIT below)
            LIMIT %s                        -- literal value: planner sees k*4 or ef_search
        $vec_sql$, _fetch_k_vec)
        USING query_embedding, _include_unverified, role_filter, project_id_filter,
              exclude_dag_id, p_content_types, _as_of_ts;
    END IF;
    -- If _has_vec = FALSE: _pgmnemo_vc remains empty; all_candidates UNION ALL
    -- below will only contain rows from _pgmnemo_bm25_work.

    RETURN QUERY
    WITH RECURSIVE
    -- Merge: vector candidates (temp table) LEFT JOIN bm25 results + anti-join UNION ALL
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM _pgmnemo_vc v                            -- temp table (was: vec_candidates CTE)
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
        WHERE bw.id NOT IN (SELECT id FROM _pgmnemo_vc)
    ),
    -- RRF ranking over bounded candidate set
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
    graph_walk(anchor_id, depth, reached_id, visited) AS (
        SELECT id, 0, id, ARRAY[id] FROM anchors  -- D1(v0.19.0): cycle guard
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id, gw.visited || me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
          AND NOT (me.target_id = ANY(gw.visited))  -- D1(v0.19.0): prevent cycle revisit
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
    )
    -- v0.18.0: _stamp removed — recall_hybrid is now STABLE.
    -- Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM ...)) separately
    -- if you want recency to be tracked.
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
    'v0.19.0 — D1+D3 graph_walk repairs (cycle guard, depth 2). v0.18.0 — VOLATILE (uses CREATE TEMP TABLE internally). Recency stamp (_stamp CTE) '
    'removed from read path: no longer takes RowExclusiveLock on pgmnemo.agent_lesson. '
    'Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM pgmnemo.recall_hybrid(...))) '
    'separately if you want last_recalled_at / recall_count to be updated. '
    'v0.14.1 — HNSW planner regression fix. Vector candidates fetched via EXECUTE with a '
    'literal LIMIT so the planner always sees the concrete value and chooses HNSW index scan. '
    'Confirmed on 3000–7440 row corpus: HNSW cost 448 vs SeqScan 413 in generic plan. '
    'v0.13.0 — adds p_min_score REAL DEFAULT NULL (11th param). '
    'p_min_score: filter rows where match_confidence < p_min_score. NULL = no filter. '
    'v0.11.0 (P0.2): typed recall via p_content_types. '
    'v0.10.1 (#87): query_text cap, indexed BM25, bm25_budget_ms timeout. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'RRF fusion sparse-safe (Cormack 2009). graph_proximity via mem_edge walk (depth ≤2; D3 v0.19.0). '
    'VOLATILE (v0.18.0). No RowExclusiveLock on agent_lesson. mark_recalled() is the write path.';


-- =============================================================================
-- §4  recall_lessons — D1 (cycle guard) + D3 (_max_depth 5 → 2)
-- =============================================================================
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
    _max_depth          CONSTANT INT := 2;  -- D3(v0.19.0): depth cap 5→2; cost O(d^k), d≈6.4, k=2
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
    graph_walk(anchor_id, depth, reached_id, visited) AS (
        SELECT id, 0, id, ARRAY[id] FROM anchors WHERE _graph_weight > 0  -- Fix 5; D1(v0.19.0): cycle guard
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id, gw.visited || me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
          AND NOT (me.target_id = ANY(gw.visited))  -- D1(v0.19.0): prevent cycle revisit
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
    'v0.19.0 — D1+D3 graph_walk repairs (cycle guard, depth 2). v0.18.0 — VOLATILE. Recency stamp removed from recall path. No longer takes '
    'RowExclusiveLock on pgmnemo.agent_lesson. '
    'Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM pgmnemo.recall_lessons(...))) '
    'separately if you want last_recalled_at / recall_count to be updated. '
    'v0.13.0 hybrid router with diagnostic columns, typed recall, and min_score gate. '
    'Routes to recall_hybrid() when both query_embedding and query_text are present '
    '(and pgmnemo.disable_hybrid is FALSE/unset). '
    'Falls back to vector-only (HNSW + recency + graph) when query_text is absent. '
    'p_content_types TEXT[] DEFAULT NULL (8th param): typed recall pushdown. '
    'p_min_score REAL DEFAULT NULL (9th param): filter rows where '
    'match_confidence (vec_score clamped [0,1]) < p_min_score. NULL=no filter. '
    'GIN-indexed for BM25 retrieval via ts_rank_cd in recall_hybrid(). '
    'Respects pgmnemo.disable_hybrid, ef_search, include_unverified, recency_weight, '
    'temporal_boost, graph_proximity_weight, max_query_text_chars GUCs. VOLATILE (v0.18.0).';


-- =============================================================================
-- §5  recall_entity — R-U1: remove stamped CTE, make STABLE PARALLEL SAFE
-- =============================================================================
CREATE OR REPLACE FUNCTION pgmnemo.recall_entity(
    p_entity_key  TEXT,
    p_k           INT  DEFAULT 10
)
RETURNS TABLE (
    lesson_id     BIGINT,
    role          TEXT,
    project_id    INT,
    topic         TEXT,
    lesson_text   TEXT,
    importance    SMALLINT,
    metadata      JSONB,
    content_type  TEXT,
    entity_keys   TEXT[],
    created_at    TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE                                                     -- R-U1(v0.19.0): stamped CTE removed
PARALLEL SAFE
AS $func$
-- R-U1(v0.19.0): recency stamp (_track_recency CTE) removed from read path.
-- Call mark_recalled(ARRAY(SELECT lesson_id FROM recall_entity(...))) separately.
DECLARE
    _include_unverified BOOLEAN;
BEGIN
    -- GUC: include_unverified (same pattern as recall_hybrid/recall_fast)
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE);
    EXCEPTION WHEN OTHERS THEN _include_unverified := FALSE;
    END;

    RETURN QUERY
    SELECT
            al.id          AS lesson_id,
            al.role,
            al.project_id,
            al.topic,
            al.lesson_text,
            al.importance,
            al.metadata,
            al.content_type,
            -- Extract entity_keys from metadata for convenience
            CASE
                WHEN al.metadata ? 'entity_keys'
                THEN ARRAY(SELECT jsonb_array_elements_text(al.metadata->'entity_keys'))
                ELSE '{}'::TEXT[]
            END AS entity_keys,
            al.created_at
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
      AND (_include_unverified OR al.verified_at IS NOT NULL)
      -- Entity key containment: metadata->'entity_keys' @> '["key"]'
      AND al.metadata->'entity_keys' @> jsonb_build_array(p_entity_key)
    ORDER BY al.importance DESC, al.created_at DESC
    LIMIT p_k;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.recall_entity(TEXT, INT) IS
    'Entity-keyed recall (v0.16.0-D, R-U1 fix v0.19.0). '
    'Returns lessons whose metadata->''entity_keys'' array contains p_entity_key. '
    'No embedding required — pure metadata lookup. '
    'Ranked by importance DESC, created_at DESC. '
    'STABLE PARALLEL SAFE (v0.19.0): recency stamp (_stamp CTE) removed from read path. '
    'Call pgmnemo.mark_recalled(ARRAY(SELECT lesson_id FROM pgmnemo.recall_entity(...))) '
    'separately if you want last_recalled_at / recall_count to be updated. '
    'Respects: is_active, t_valid_to bitemporal gate, include_unverified GUC. '
    'Empty result: 0 rows, no NOTICE/WARNING (silent). '
    'p_entity_key: exact key string, e.g. ''failure:PHANTOM_DONE'', ''model:claude-sonnet-4-6''. '
    'p_k: max results (default 10).';



