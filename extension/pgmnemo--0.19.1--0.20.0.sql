-- pgmnemo 0.19.1 -> 0.20.0
-- «Граф, который достаёт» — Graph-as-Pool-Expander
--
-- Changes (R2_ARCH_VARIANTS §1,3,7-8; R2_DB_FEASIBILITY §3,8):
--
-- §1  recall_hybrid (11-param): add graph_expand CTE (Variant A) + entity_expanded CTE
--     (Variant C) + retrieval_source TEXT output column. Drop old signature (return
--     type change requires DROP + CREATE).
--
-- §2  stats(): add 7 GUC columns for graph expansion settings. Drop old signature
--     (return type change requires DROP + CREATE).
--
-- GUC Catalog (R-U4 risk mitigation) — each GUC appears in:
--   a) Function body (current_setting reads below)
--   b) stats() return columns (§2)
--   c) COMMENT ON FUNCTION docstring (§3)
--   d) This migration header comment
--
-- GUC summary (ALL default 0.0 / disabled by default):
--   pgmnemo.graph_expand_weight         REAL  [0.0, 0.5]  def 0.0  — master on/off Variant A
--   pgmnemo.graph_expand_depth          INT   [1, 2]      def 1    — BFS depth (max 2; depth=2 conditional)
--   pgmnemo.graph_expand_ann_k          INT   [10, 50]    def 15   — ANN anchor oversampling
--   pgmnemo.graph_expand_per_node       INT   [3, 50]     def 10   — hub-cap per source node
--   pgmnemo.graph_entity_expand_weight  REAL  [0.0, 0.3]  def 0.0  — master on/off Variant C
--   pgmnemo.graph_entity_min_overlap    INT   >= 1        def 1    — min matching entity keys
--   pgmnemo.graph_entity_max_expansion  INT   >= 1        def 50   — max GIN candidates per key
--
-- Safety constraints (all defaults safe for production):
--   IRON: all graph weights default 0.0 — no retrieval change without explicit opt-in
--   IRON: no perf claims in CHANGELOG until PREREG_020_EXPAND (SHA 4eb3a2b8) ablation complete
--   GIN bug fix (R2_DB §7): metadata @> jsonb_build_object('entity_keys', jsonb_build_array(key))
--                            NOT jsonb_build_array(key) — correct nested containment pattern
--   Hub-cap (R2_DB §5): LATERAL LIMIT per source node mandatory for BFS safety
--   Causal-only (R2_DB §8.2): Variant A uses edge_kind='causal' only; temporal adds noise
--
-- G-UPGRADE-PARITY: pgmnemo--0.20.0.sql = pgmnemo--0.19.1.sql || this file
-- pg_regress: see tests/sql/test_v0200_graph_expand.sql

-- ─────────────────────────────────────────────────────────────────────────────
-- §1: recall_hybrid (11-param) — new return type requires DROP + CREATE
--     Adds: entity_expanded CTE (Variant C), graph_expand CTE (Variant A),
--           retrieval_source TEXT output column
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_hybrid(
    vector, text, integer, text, integer,
    double precision, double precision, integer, text, text[], real
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
    match_confidence REAL,
    retrieval_source TEXT             -- v0.20.0: ann|graph|entity
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
    _graph_weight       DOUBLE PRECISION;   -- old proximity multiplier (backward compat)
    _max_depth          CONSTANT INT := 2;  -- D3(v0.19.0): depth cap 5→2
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _raw_blend_weight   DOUBLE PRECISION;
    _ghost_count        INT;
    _fetch_k_vec        INT;
    _fetch_k_bm25       INT;
    _conf_boost_w       DOUBLE PRECISION;
    _lexical_text       TEXT;
    _bm25_budget_ms     INT;
    _bm25_timed_out     BOOLEAN := FALSE;
    -- v0.20.0 Variant A — BFS pool expansion (GUC: pgmnemo.graph_expand_weight)
    _graph_expand_weight    REAL;    -- [0.0, 0.5] default 0.0
    _graph_expand_depth     INT;     -- [1, 2]     default 1
    _graph_expand_ann_k     INT;     -- [10, 50]   default 15
    _graph_expand_per_node  INT;     -- [3, 50]    default 10
    -- v0.20.0 Variant C — Entity GIN expansion (GUC: pgmnemo.graph_entity_expand_weight)
    _graph_entity_weight        REAL;    -- [0.0, 0.3] default 0.0
    _graph_entity_min_overlap   INT;     -- >= 1      default 1
    _graph_entity_max_expansion INT;     -- >= 1      default 50
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
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.0;
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

    -- v0.20.0: read Variant A GUCs (pgmnemo.graph_expand_weight)
    BEGIN
        _graph_expand_weight := GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_weight', TRUE), '')::REAL, 0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_expand_weight := 0.0;
    END;

    BEGIN
        _graph_expand_depth := GREATEST(1, LEAST(2, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_depth', TRUE), '')::INT, 1)));
    EXCEPTION WHEN OTHERS THEN _graph_expand_depth := 1;
    END;

    BEGIN
        _graph_expand_ann_k := GREATEST(10, LEAST(50, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_ann_k', TRUE), '')::INT, 15)));
    EXCEPTION WHEN OTHERS THEN _graph_expand_ann_k := 15;
    END;

    BEGIN
        _graph_expand_per_node := GREATEST(3, LEAST(50, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_per_node', TRUE), '')::INT, 10)));
    EXCEPTION WHEN OTHERS THEN _graph_expand_per_node := 10;
    END;

    -- v0.20.0: read Variant C GUCs (pgmnemo.graph_entity_expand_weight)
    BEGIN
        _graph_entity_weight := GREATEST(0.0, LEAST(0.3, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_entity_expand_weight', TRUE), '')::REAL, 0.0)));
    EXCEPTION WHEN OTHERS THEN _graph_entity_weight := 0.0;
    END;

    BEGIN
        _graph_entity_min_overlap := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_entity_min_overlap', TRUE), '')::INT, 1));
    EXCEPTION WHEN OTHERS THEN _graph_entity_min_overlap := 1;
    END;

    BEGIN
        _graph_entity_max_expansion := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_entity_max_expansion', TRUE), '')::INT, 50));
    EXCEPTION WHEN OTHERS THEN _graph_entity_max_expansion := 50;
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

    -- ── BM25 candidates ──────────────────────────────────────────────────────
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

    -- ── ANN vector candidates (EXECUTE with literal LIMIT for planner) ───────
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
            ORDER BY al.embedding <=> $1
            LIMIT %s
        $vec_sql$, _fetch_k_vec)
        USING query_embedding, _include_unverified, role_filter, project_id_filter,
              exclude_dag_id, p_content_types, _as_of_ts;
    END IF;

    RETURN QUERY
    WITH RECURSIVE

    -- ── Phase C: Entity key extraction from query text ────────────────────────
    -- Calls pgmnemo.extract_entity_keys(query_text) — same function used at write-time
    -- Guard: enabled only when graph_entity_expand_weight > 0 and query_text available
    query_entity_keys AS (
        SELECT DISTINCT ek
        FROM unnest(
            CASE WHEN _graph_entity_weight > 0.0
                      AND _has_text
                 THEN pgmnemo.extract_entity_keys(query_text)
                 ELSE ARRAY[]::TEXT[]
            END
        ) AS t(ek)
        WHERE ek IS NOT NULL AND ek <> ''
    ),

    -- ── Phase C: GIN-index entity expansion (LATERAL per-key — prevents SeqScan) ──
    -- CRITICAL FIX (R2_DB §7): jsonb_build_object, NOT jsonb_build_array
    -- Wrong:   metadata @> jsonb_build_array(key)           → returns 0 rows always
    -- Correct: metadata @> jsonb_build_object('entity_keys', jsonb_build_array(key))
    entity_candidates AS (
        SELECT inner_al.id AS entity_id, COUNT(DISTINCT qek.ek) AS key_overlap
        FROM query_entity_keys qek,
             LATERAL (
                 SELECT al2.id
                 FROM pgmnemo.agent_lesson al2
                 WHERE al2.is_active
                   AND al2.metadata @> jsonb_build_object(
                           'entity_keys', jsonb_build_array(qek.ek))
                 LIMIT _graph_entity_max_expansion
             ) inner_al
        GROUP BY inner_al.id
        HAVING COUNT(DISTINCT qek.ek) >= _graph_entity_min_overlap
    ),

    -- ── Phase A: BFS anchor selection (top-K from ANN pool by cosine score) ──
    -- Guard: only populated when graph_expand_weight > 0
    bfs_anchors AS (
        SELECT id
        FROM _pgmnemo_vc
        WHERE _graph_expand_weight > 0.0
        ORDER BY raw_vec_score DESC
        LIMIT _graph_expand_ann_k
    ),

    -- ── Phase A: BFS pool expansion (causal edges only, depth=1, hub-cap) ────
    -- R2_DB §8.2: causal-only — temporal edges produce 0pp lift at cos < 0.6
    -- Hub-cap via LATERAL LIMIT per source node (mandatory: p99 out-degree = 222)
    -- Cycle guard via visited BIGINT[] (D1 from v0.19.0, carried forward)
    graph_expand(reached_id, depth, path_weight, visited) AS (
        -- Seed: ANN anchors at depth 0
        SELECT ba.id, 0, 1.0::REAL, ARRAY[ba.id]
        FROM bfs_anchors ba

        UNION ALL

        -- Recursive: follow causal edges with hub-cap (LATERAL LIMIT per source node)
        SELECT nb.target_id,
               ge.depth + 1,
               (ge.path_weight * COALESCE(nb.weight, 1.0))::REAL,
               ge.visited || nb.target_id
        FROM graph_expand ge,
             LATERAL (
                 -- Hub-cap: LIMIT _graph_expand_per_node per source node (prevents hub explosion)
                 SELECT me.target_id, me.weight
                 FROM pgmnemo.mem_edge me
                 WHERE me.source_id = ge.reached_id
                   AND me.edge_kind = 'causal'        -- causal edges ONLY (Variant A spec)
                   AND me.valid_until IS NULL
                   AND NOT (me.target_id = ANY(ge.visited))  -- cycle guard
                 ORDER BY me.weight DESC NULLS LAST
                 LIMIT _graph_expand_per_node           -- hub-cap: GUC pgmnemo.graph_expand_per_node
             ) nb
        WHERE ge.depth < _graph_expand_depth           -- GUC pgmnemo.graph_expand_depth
    ),

    -- ── Phase A: Aggregate BFS results — best path per node, exclude original pool ──
    graph_scores AS (
        SELECT reached_id                AS id,
               MAX(path_weight)          AS graph_score
        FROM graph_expand
        WHERE depth > 0                              -- exclude seeds (depth=0)
          AND reached_id NOT IN (SELECT id FROM _pgmnemo_vc)
          AND reached_id NOT IN (SELECT id FROM _pgmnemo_bm25_work)
        GROUP BY reached_id
    ),

    -- ── Phase C: Entity candidates — exclude original pool and graph pool ─────
    entity_scores AS (
        SELECT ec.entity_id                          AS id,
               ec.key_overlap::INT
        FROM entity_candidates ec
        WHERE ec.entity_id NOT IN (SELECT id FROM _pgmnemo_vc)
          AND ec.entity_id NOT IN (SELECT id FROM _pgmnemo_bm25_work)
          AND ec.entity_id NOT IN (SELECT id FROM graph_scores)
    ),

    -- ── Merge all candidate pools with source attribution ─────────────────────
    all_candidates AS (
        -- [1] ANN candidates (may overlap with BM25)
        SELECT v.id, v.role, v.project_id, v.topic, v.lesson_text,
               v.importance, v.metadata, v.commit_sha, v.artifact_hash,
               v.verified_at, v.created_at, v.confidence,
               v.raw_vec_score,
               COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score,
               NULL::REAL                   AS graph_score,
               NULL::INT                    AS key_overlap,
               'ann'::TEXT                  AS retrieval_source
        FROM _pgmnemo_vc v
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        -- [2] BM25-only candidates (not in ANN pool)
        SELECT al.id, al.role, al.project_id, al.topic, al.lesson_text,
               al.importance, al.metadata, al.commit_sha, al.artifact_hash,
               al.verified_at, al.created_at, al.confidence,
               0.0::DOUBLE PRECISION        AS raw_vec_score,
               bw.raw_bm25_score,
               NULL::REAL                   AS graph_score,
               NULL::INT                    AS key_overlap,
               'ann'::TEXT                  AS retrieval_source
        FROM _pgmnemo_bm25_work bw
        JOIN pgmnemo.agent_lesson al ON al.id = bw.id
        WHERE bw.id NOT IN (SELECT id FROM _pgmnemo_vc)

        UNION ALL

        -- [3] Graph-expanded candidates (BFS pool, new lessons outside ANN+BM25)
        SELECT al.id, al.role, al.project_id, al.topic, al.lesson_text,
               al.importance, al.metadata, al.commit_sha, al.artifact_hash,
               al.verified_at, al.created_at, al.confidence,
               CASE WHEN _has_vec
                    THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                    ELSE 0.0::DOUBLE PRECISION
               END                          AS raw_vec_score,
               0.0::DOUBLE PRECISION        AS raw_bm25_score,
               gs.graph_score,
               NULL::INT                    AS key_overlap,
               'graph'::TEXT                AS retrieval_source
        FROM graph_scores gs
        JOIN pgmnemo.agent_lesson al ON al.id = gs.id
        WHERE al.is_active
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

        UNION ALL

        -- [4] Entity-expanded candidates (GIN pool, outside ANN+BM25+graph)
        SELECT al.id, al.role, al.project_id, al.topic, al.lesson_text,
               al.importance, al.metadata, al.commit_sha, al.artifact_hash,
               al.verified_at, al.created_at, al.confidence,
               CASE WHEN _has_vec
                    THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                    ELSE 0.0::DOUBLE PRECISION
               END                          AS raw_vec_score,
               0.0::DOUBLE PRECISION        AS raw_bm25_score,
               NULL::REAL                   AS graph_score,
               es.key_overlap,
               'entity'::TEXT               AS retrieval_source
        FROM entity_scores es
        JOIN pgmnemo.agent_lesson al ON al.id = es.id
        WHERE al.is_active
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
    ),

    -- ── RRF ranking over full candidate set ───────────────────────────────────
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                                    AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST, id ASC) AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                                 AS bm25_rank_sparse
        FROM all_candidates
    ),
    scored AS (
        SELECT
            r.id, r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at, r.confidence,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            r.graph_score,
            r.key_overlap,
            r.retrieval_source,
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 vec_weight  * r.raw_vec_score
               + bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),

    -- ── Backward-compat: old graph_proximity multiplier (graph_proximity_weight GUC) ──
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    graph_walk(anchor_id, depth, reached_id, visited) AS (
        SELECT id, 0, id, ARRAY[id] FROM anchors WHERE _graph_weight > 0
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id, gw.visited || me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
          AND NOT (me.target_id = ANY(gw.visited))
    ),
    graph_proximity AS (
        SELECT gw.reached_id AS lesson_id,
               MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw WHERE gw.depth > 0 GROUP BY gw.reached_id
    ),

    -- ── Final scoring: RRF + aux signal + graph expansion bonus ──────────────
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
              -- v0.20.0 (A): BFS expansion additive contribution
              + _graph_expand_weight * COALESCE(s.graph_score::DOUBLE PRECISION, 0.0)
              -- v0.20.0 (C): entity expansion additive contribution (per matched key)
              + _graph_entity_weight * COALESCE(s.key_overlap, 0)::DOUBLE PRECISION
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score,
            s.role, s.project_id, s.topic, s.lesson_text, s.importance,
            s.metadata, s.commit_sha, s.artifact_hash, s.verified_at, s.created_at,
            s.confidence, s.v_score, s.b_score, s.rrf_sparse,
            COALESCE(gp.proximity, 0.0) AS prox,
            s.retrieval_source
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
            LEAST(1.0, GREATEST(0.0, f.v_score))::REAL AS match_confidence,
            f.retrieval_source
        FROM final f
        WHERE (p_min_score IS NULL
               OR LEAST(1.0, GREATEST(0.0, f.v_score))::REAL >= p_min_score)
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    )
    SELECT
        fr.lesson_id, fr.score, fr.vec_score, fr.bm25_score, fr.rrf_score,
        fr.role, fr.project_id, fr.topic, fr.lesson_text, fr.importance,
        fr.metadata, fr.commit_sha, fr.artifact_hash, fr.verified_at, fr.created_at,
        fr.confidence, fr.match_confidence, fr.retrieval_source
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

-- ─────────────────────────────────────────────────────────────────────────────
-- §3: COMMENT ON FUNCTION — GUC catalog (R-U4) — all 7 new GUCs documented
-- ─────────────────────────────────────────────────────────────────────────────
COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[], REAL) IS
    'v0.20.0 — «Граф, который достаёт». Two orthogonal graph expansion mechanisms '
    'added to pool expander architecture (R2_ARCH_VARIANTS §1,3; R2_DB §3): '
    ''
    'Variant A (BFS pool expansion): '
    '  GUC pgmnemo.graph_expand_weight REAL [0.0, 0.5] default 0.0 — master on/off. '
    '  GUC pgmnemo.graph_expand_depth INT [1, 2] default 1 — BFS depth (depth=2 conditional, R2_DB §3.1.2). '
    '  GUC pgmnemo.graph_expand_ann_k INT [10, 50] default 15 — ANN anchor oversampling count. '
    '  GUC pgmnemo.graph_expand_per_node INT [3, 50] default 10 — hub-cap per source node (MANDATORY). '
    '  Expansion: pgmnemo.mem_edge causal edges only (not temporal); cycle guard via visited[]; p95=4.0ms at depth=1. '
    ''
    'Variant C (Entity GIN expansion): '
    '  GUC pgmnemo.graph_entity_expand_weight REAL [0.0, 0.3] default 0.0 — master on/off. '
    '  GUC pgmnemo.graph_entity_min_overlap INT >= 1 default 1 — min entity keys matching. '
    '  GUC pgmnemo.graph_entity_max_expansion INT >= 1 default 50 — max GIN candidates per key. '
    '  GIN pattern: metadata @> jsonb_build_object(''entity_keys'', jsonb_build_array(key)). '
    '  LATERAL per-key (not CROSS JOIN) ensures GIN index pushdown; p95=3.53ms. '
    ''
    'retrieval_source TEXT column: ann (original ANN+BM25 pool), graph (BFS-expanded), entity (GIN-expanded). '
    'Output columns preserved: vec_score (cosine similarity), bm25_score, rrf_score, match_confidence. '
    'All expansion weights default 0.0 — output is byte-identical to 0.19.x when weights unset. '
    'IRON: no perf claims until PREREG_020_EXPAND (SHA 4eb3a2b8) ablation complete. '
    'v0.18.0 — VOLATILE (uses CREATE TEMP TABLE). Call mark_recalled() separately for recency tracking. '
    'v0.14.1 — HNSW planner regression fix (EXECUTE with literal LIMIT). '
    'v0.9.2 — confidence_boost_weight additive scoring. '
    'v0.8.2 — F2: NOTICE when 0 rows and ghost lessons exist.';

-- ─────────────────────────────────────────────────────────────────────────────
-- §2: stats() — add 7 GUC columns for graph expansion (return type change → DROP + CREATE)
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                          TEXT,
    lesson_count                     BIGINT,
    embedded_count                   BIGINT,
    embedding_coverage_pct           DOUBLE PRECISION,
    tsv_coverage_pct                 DOUBLE PRECISION,
    mem_edge_count                   BIGINT,
    recency_weight                   DOUBLE PRECISION,
    ef_search                        INT,
    importance_weight                DOUBLE PRECISION,
    hybrid_enabled                   BOOLEAN,
    recall_hybrid_available          BOOLEAN,
    oldest_lesson_age_days           INT,
    orphan_count                     BIGINT,
    ghost_count                      BIGINT,
    confidence_mean                  REAL,
    confidence_p10                   REAL,
    confidence_p50                   REAL,
    confidence_p90                   REAL,
    confidence_below_threshold_count INT,
    -- v0.20.0 graph expansion GUC columns (R-U4: GUC catalog — GUC must appear in stats())
    graph_expand_weight              REAL,       -- GUC pgmnemo.graph_expand_weight [0.0,0.5] def 0.0
    graph_expand_depth               INT,        -- GUC pgmnemo.graph_expand_depth [1,2] def 1
    graph_expand_ann_k               INT,        -- GUC pgmnemo.graph_expand_ann_k [10,50] def 15
    graph_expand_per_node            INT,        -- GUC pgmnemo.graph_expand_per_node [3,50] def 10
    graph_entity_expand_weight       REAL,       -- GUC pgmnemo.graph_entity_expand_weight [0.0,0.3] def 0.0
    graph_entity_min_overlap         INT,        -- GUC pgmnemo.graph_entity_min_overlap >= 1 def 1
    graph_entity_max_expansion       INT         -- GUC pgmnemo.graph_entity_max_expansion >= 1 def 50
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $func$
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
        (SELECT COUNT(*)::BIGINT
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         LEFT JOIN pg_depend d
             ON d.objid = p.oid AND d.deptype = 'e'
            AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
         WHERE n.nspname = 'pgmnemo'
           AND p.proname NOT LIKE '\_%' ESCAPE '\'
           AND d.objid IS NULL)                                                    AS orphan_count,
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count,
        (SELECT COALESCE(AVG(confidence), 0.5)::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_mean,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p10,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p50,
        (SELECT COALESCE(
                    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY confidence), 0.5
                )::REAL
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS confidence_p90,
        (SELECT COUNT(*)::INT
         FROM pgmnemo.agent_lesson
         WHERE t_valid_to = 'infinity'::TIMESTAMPTZ
           AND confidence < 0.3)                                                   AS confidence_below_threshold_count,
        -- v0.20.0: graph expansion GUC values (R-U4: must appear in stats())
        GREATEST(0.0, LEAST(0.5, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_weight', TRUE), '')::REAL,
            0.0)))                                                                 AS graph_expand_weight,
        GREATEST(1, LEAST(2, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_depth', TRUE), '')::INT,
            1)))                                                                   AS graph_expand_depth,
        GREATEST(10, LEAST(50, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_ann_k', TRUE), '')::INT,
            15)))                                                                  AS graph_expand_ann_k,
        GREATEST(3, LEAST(50, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_expand_per_node', TRUE), '')::INT,
            10)))                                                                  AS graph_expand_per_node,
        GREATEST(0.0, LEAST(0.3, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_entity_expand_weight', TRUE), '')::REAL,
            0.0)))                                                                 AS graph_entity_expand_weight,
        GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_entity_min_overlap', TRUE), '')::INT,
            1))                                                                    AS graph_entity_min_overlap,
        GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.graph_entity_max_expansion', TRUE), '')::INT,
            50))                                                                   AS graph_entity_max_expansion;
$func$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.20.0 — adds 7 graph expansion GUC columns (graph_expand_weight, graph_expand_depth, '
    'graph_expand_ann_k, graph_expand_per_node, graph_entity_expand_weight, '
    'graph_entity_min_overlap, graph_entity_max_expansion). '
    'All graph expansion GUCs default 0.0/disabled. '
    'v0.7.0 diagnostic health-check (26 columns total, was 19). '
    'Single-row; <100ms on N=10k corpus.';
