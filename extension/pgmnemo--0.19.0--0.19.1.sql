-- pgmnemo 0.19.0 -> 0.19.1
-- The 0.18.x -> 0.19.0 upgrade scripts carry a navigate_locate whose recursive
-- CTE has two references to its own worktable — invalid SQL that survives
-- CREATE only because PL/pgSQL defers parsing to first execution. A fresh
-- 0.19.0 install got the fixed body from the flat; an UPGRADED install got the
-- broken one and fails on the first navigate_locate call. This script converges
-- upgraded installs to the fixed body (verbatim from a fresh install).

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(query_embedding vector, query_text text, token_budget_chars integer DEFAULT 2000, jsonb_filter jsonb DEFAULT NULL::jsonb, project_id_filter integer DEFAULT NULL::integer)
 RETURNS TABLE(id bigint, preview text, score double precision, tokens_consumed integer, navigation_path text)
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
        -- D2(v0.19.0): bidirectional via pre-unioned edge arms — a recursive CTE
        -- permits exactly ONE recursive reference, so two UNION ALL branches each
        -- reading graph_walk are illegal (PL/pgSQL defers parsing to first
        -- execution, which is how the broken form survived CREATE). Each arm of
        -- the inner UNION ALL keeps its own index: source_id btree forward,
        -- ix_mem_edge_target_active backward.
        SELECT gw.anchor_id, gw.depth + 1, e.next_id, gw.visited || e.next_id
        FROM graph_walk gw
        JOIN (
            SELECT me.source_id AS from_id, me.target_id AS next_id, me.valid_until
            FROM pgmnemo.mem_edge me
            UNION ALL
            SELECT me.target_id AS from_id, me.source_id AS next_id, me.valid_until
            FROM pgmnemo.mem_edge me
        ) e ON e.from_id = gw.reached_id
        WHERE gw.depth < _max_depth
          AND (e.valid_until IS NULL OR e.valid_until = 'infinity'::TIMESTAMPTZ)
          AND NOT (e.next_id = ANY(gw.visited))  -- D1: prevent cycle revisit
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
$function$
;

