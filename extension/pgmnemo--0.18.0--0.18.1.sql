
-- =============================================================================
-- v0.18.1 — recall_hybrid could hang for tens of seconds on ordinary queries.
--
-- The graph-proximity walk was seeded unconditionally in recall_hybrid, so it
-- ran on every call even though its contribution is multiplied by
-- pgmnemo.graph_proximity_weight, which defaults to 0.0 — the entire traversal
-- was computed and then discarded. With no cycle guard and a depth cap of 5,
-- an anchor that happens to be a hub in mem_edge expands combinatorially.
-- Measured on a 9,326-lesson / 74,778-edge corpus: 5 of 12 ordinary one-word
-- queries exceeded an 8-second statement timeout on 0.17.0 and 0.18.0 alike;
-- 0 of 12 after this patch. recall_lessons already had the weight guard and is
-- patched here only for the cycle guard.
--
-- At the default weight this changes no result: the proximity term is
-- multiplied by zero either way (verified — identical rows and scores on every
-- query the unpatched version could answer at all).
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(query_embedding vector, query_text text, k integer DEFAULT 10, role_filter text DEFAULT NULL::text, project_id_filter integer DEFAULT NULL::integer, vec_weight double precision DEFAULT 0.4, bm25_weight double precision DEFAULT 0.4, rrf_k integer DEFAULT 60, exclude_dag_id text DEFAULT NULL::text, p_content_types text[] DEFAULT NULL::text[], p_min_score real DEFAULT NULL::real)
 RETURNS TABLE(lesson_id bigint, score double precision, vec_score double precision, bm25_score double precision, rrf_score double precision, role text, project_id integer, topic text, lesson_text text, importance smallint, metadata jsonb, commit_sha text, artifact_hash text, verified_at timestamp with time zone, created_at timestamp with time zone, confidence real, match_confidence real)
 LANGUAGE plpgsql
AS $function$
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
        SELECT id, 0, id, ARRAY[id] FROM anchors WHERE _graph_weight > 0  -- 0.18.1: обход только при включённом весе
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id, gw.visited || me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
          AND NOT (me.target_id = ANY(gw.visited))  -- 0.18.1: без этого обход зацикливается
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
$function$
;

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(query_embedding vector, k integer DEFAULT 10, role_filter text DEFAULT NULL::text, project_id_filter integer DEFAULT NULL::integer, query_text text DEFAULT NULL::text, as_of_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, exclude_dag_id text DEFAULT NULL::text, p_content_types text[] DEFAULT NULL::text[], p_min_score real DEFAULT NULL::real)
 RETURNS TABLE(lesson_id bigint, score double precision, role text, project_id integer, topic text, lesson_text text, importance smallint, metadata jsonb, commit_sha text, artifact_hash text, verified_at timestamp with time zone, created_at timestamp with time zone, vec_score double precision, bm25_score double precision, rrf_score double precision, confidence real, match_confidence real)
 LANGUAGE plpgsql
AS $function$
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
    graph_walk(anchor_id, depth, reached_id, visited) AS (
        SELECT id, 0, id, ARRAY[id] FROM anchors WHERE _graph_weight > 0  -- Fix 5
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id, gw.visited || me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
          AND NOT (me.target_id = ANY(gw.visited))  -- 0.18.1: без этого обход зацикливается
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
$function$
;
