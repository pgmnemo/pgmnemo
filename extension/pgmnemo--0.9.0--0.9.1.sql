-- pgmnemo--0.9.0--0.9.1.sql
-- Incremental upgrade: pgmnemo 0.9.0 → 0.9.1
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Fix navigate_expand + navigate_locate graph traversal (P0)
--
-- ROOT CAUSE: Both navigate_* functions filter by edge_kind IN ('causal','temporal'),
--   but production edges written via backfill_mem_edge.py all have edge_kind='semantic'
--   due to unmapped relation_type 'CO_TEMPORAL' (the 'triple-dead' mismatch).
--   relation_type is the REAL discriminator and must be the filter predicate.
--
-- ITEMS:
--   #1  navigate_expand(): filter by relation_type (not edge_kind); add relation_types
--       parameter; bidirectional BFS; handle valid_until='infinity'; threshold 0.7→0.5
--   #2  navigate_locate(): graph_walk filters by relation_type (not edge_kind);
--       bidirectional BFS; handle valid_until='infinity'
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.1';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.1'" to load this file. \quit

-- ══════════════════════════════════════════════════════════════════════════════
-- #1: navigate_expand — fix graph traversal (P0)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Bugs fixed (all verified in pgmnemo--0.9.0.sql lines 4396-4405):
--
--   B1: edge_kind IN ('causal','temporal') filtered out ALL production edges because
--       backfill_mem_edge.py wrote edges with relation_type='CO_TEMPORAL' (unmapped in
--       add_edge's CASE → defaults to edge_kind='semantic'). Fix: filter by relation_type
--       which is the actual typed discriminator. New param: relation_types TEXT[] DEFAULT
--       NULL (NULL = traverse all active edges regardless of type).
--
--   B2: valid_until IS NULL excluded edges that might carry valid_until='infinity'
--       (following agent_lesson's t_valid_to convention instead of mem_edge's NULL
--       convention). Fix: (valid_until IS NULL OR valid_until = 'infinity'::TIMESTAMPTZ).
--
--   B3: Forward-only BFS (me.source_id = ge.node_id → me.target_id) means the agent
--       cannot discover backward relations. If the agent is at lesson B and there exists
--       "A CAUSED_BY B" (source=A, target=B), forward-only BFS from B finds nothing.
--       Fix: bidirectional — join on (source_id = node OR target_id = node), traverse to
--       the opposite endpoint.
--
--   B4: Default threshold 0.7 → 0.5. For navigation (not scoring), the agent should
--       see more connections and decide which to follow. 0.7 was unnecessarily aggressive
--       for sparse graphs.
--
-- Signature change: adds 5th param (TEXT[]) — DROP old 4-arg overload required.
-- ──────────────────────────────────────────────────────────────────────────────

-- Drop old 4-arg signature to prevent ambiguous overload resolution
DROP FUNCTION IF EXISTS pgmnemo.navigate_expand(BIGINT[], TEXT[], INT, FLOAT);

CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand(
    ids                    BIGINT[],
    expand_fields          TEXT[]           DEFAULT '{}',
    graph_expand_depth     INT              DEFAULT 1,
    graph_expand_threshold FLOAT            DEFAULT 0.5,
    relation_types         TEXT[]           DEFAULT NULL
)
RETURNS TABLE (
    id                      BIGINT,
    content                 TEXT,
    expand_detail           JSONB,
    graph_neighbor_ids      BIGINT[],
    graph_neighbor_previews TEXT[],
    tokens_consumed         INT,
    navigation_path         TEXT
)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
BEGIN
    IF ids IS NULL OR array_length(ids, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    -- Step 1: seed rows — the requested IDs
    seed_rows AS (
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, al.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE al.metadata ? f
                )
                ELSE NULL::JSONB
            END                                                            AS expand_detail,
            'content'::TEXT                                                AS navigation_path,
            0                                                              AS depth,
            ARRAY[al.id]                                                   AS path
        FROM pgmnemo.agent_lesson al
        WHERE al.id = ANY(ids)
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
    ),
    -- Step 2: BFS graph expansion — BIDIRECTIONAL, relation_type-gated, weight-gated
    graph_expand (node_id, lesson_text, metadata, depth, path) AS (
        -- Seed: input IDs
        SELECT
            sr.id,
            sr.lesson_text,
            sr.metadata,
            0,
            sr.path
        FROM seed_rows sr

        UNION ALL

        -- Recursive: traverse edges in BOTH directions, gated by relation_type + weight
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            ge.depth + 1,
            ge.path || al.id
        FROM graph_expand ge
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = ge.node_id OR me.target_id = ge.node_id
        )
        JOIN pgmnemo.agent_lesson al ON al.id = CASE
            WHEN me.source_id = ge.node_id THEN me.target_id
            ELSE me.source_id
        END
        WHERE graph_expand_depth >= 1
          AND ge.depth < graph_expand_depth
          -- B1 fix: filter by relation_type (the real discriminator)
          -- NULL relation_types = traverse ALL active edges (no type filter)
          AND (relation_types IS NULL OR me.relation_type = ANY(relation_types))
          -- Weight gate: configurable threshold (default 0.5)
          AND me.weight >= graph_expand_threshold::REAL
          -- B2 fix: handle both active-edge sentinel conventions
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
          -- Target lesson must be active
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          -- Cycle guard: prevent revisiting nodes already in path
          AND NOT (al.id = ANY(ge.path))
    ),
    -- Step 3: collect expanded rows (exclude IDs already in seed)
    expanded_rows AS (
        SELECT DISTINCT ON (ge.node_id)
            ge.node_id                                                         AS id,
            ge.lesson_text,
            ge.metadata,
            CASE
                WHEN expand_fields IS NOT NULL AND array_length(expand_fields, 1) > 0
                THEN (
                    SELECT jsonb_object_agg(f, ge.metadata->f)
                    FROM unnest(expand_fields) AS f
                    WHERE ge.metadata ? f
                )
                ELSE NULL::JSONB
            END                                                                AS expand_detail,
            'graph_expand'::TEXT                                               AS navigation_path
        FROM graph_expand ge
        WHERE ge.depth > 0                         -- only expansion rows, not seeds
          AND NOT (ge.node_id = ANY(ids))          -- exclude original input IDs
        ORDER BY ge.node_id, ge.depth ASC          -- prefer shallower depth
    ),
    -- Step 4b: deduplicated BFS neighbors per seed (all depths)
    distinct_neighbors AS (
        SELECT DISTINCT ON (ge.path[1], ge.node_id)
            ge.path[1]                                     AS seed_id,
            ge.node_id,
            ge.depth,
            left(ge.lesson_text, 50)                       AS neighbor_preview
        FROM graph_expand ge
        WHERE ge.depth > 0
          AND NOT (ge.node_id = ANY(ids))
        ORDER BY ge.path[1], ge.node_id, ge.depth ASC
    ),
    -- Step 4c: aggregate neighbors per seed — positional correspondence guaranteed
    neighbor_summary AS (
        SELECT
            dn.seed_id,
            array_agg(dn.node_id ORDER BY dn.depth, dn.node_id)          AS neighbor_ids,
            array_agg(dn.neighbor_preview ORDER BY dn.depth, dn.node_id) AS neighbor_previews
        FROM distinct_neighbors dn
        GROUP BY dn.seed_id
    ),
    -- Step 5: union seed + expanded, seed takes priority on id collision
    combined AS (
        SELECT sr.id,
               sr.lesson_text                                  AS content,
               sr.expand_detail,
               ns.neighbor_ids                                 AS graph_neighbor_ids,
               ns.neighbor_previews                            AS graph_neighbor_previews,
               sr.navigation_path
        FROM seed_rows sr
        LEFT JOIN neighbor_summary ns ON ns.seed_id = sr.id

        UNION ALL

        SELECT er.id,
               er.lesson_text                                  AS content,
               er.expand_detail,
               NULL::BIGINT[]                                  AS graph_neighbor_ids,
               NULL::TEXT[]                                     AS graph_neighbor_previews,
               er.navigation_path
        FROM expanded_rows er
    )
    -- Step 6: attach cumulative tokens_consumed (chars as proxy)
    SELECT
        c.id,
        c.content,
        c.expand_detail,
        c.graph_neighbor_ids,
        c.graph_neighbor_previews,
        SUM(length(c.content)) OVER (
            ORDER BY c.id ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )::INT                                                 AS tokens_consumed,
        c.navigation_path
    FROM combined c
    ORDER BY c.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_expand(BIGINT[], TEXT[], INT, FLOAT, TEXT[]) IS
    'Token-economy navigation EXPAND (v0.9.1). '
    'Returns full lesson_text + JSONB expansion for caller-chosen IDs. '
    'v0.9.1 fixes: '
    '(B1) relation_type filter replaces broken edge_kind filter — production edges had '
    'edge_kind=semantic for ALL types due to unmapped relation_types in backfill; '
    '(B2) valid_until handles both NULL and infinity sentinel conventions; '
    '(B3) bidirectional BFS — agent can discover backward relations (e.g. find cause '
    'from an effect by traversing CAUSED_BY edges in reverse); '
    '(B4) relation_types TEXT[] param — NULL traverses all, or pass specific types. '
    'Threshold default lowered: 0.5 (was 0.7) — navigation should be permissive; '
    'agent decides which connections to follow. '
    'Combine with navigate_locate() for the locate→connections→expand loop.';


-- ══════════════════════════════════════════════════════════════════════════════
-- #2: navigate_locate — fix graph_walk traversal
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Same root cause as #1: graph_walk at line 4207 in 0.9.0 uses
--   me.edge_kind IN ('causal', 'temporal')
-- but should traverse by relation_type like recall_hybrid (line 1249).
--
-- Additional fixes:
--   - Bidirectional BFS for symmetric proximity scoring
--   - valid_until sentinel handling
--   - No edge_kind filter: for proximity scoring, ALL connected lessons contribute
--
-- No signature change — CREATE OR REPLACE is safe.
-- ──────────────────────────────────────────────────────────────────────────────

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
STABLE
PARALLEL SAFE
AS $$
#variable_conflict use_column
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _tsquery            TSQUERY;
    _has_text           BOOLEAN;
    _has_vec            BOOLEAN;
    _graph_weight       DOUBLE PRECISION;
    _max_depth          CONSTANT INT := 2;  -- proximity scoring: 2-hop sufficient
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _vec_weight         CONSTANT DOUBLE PRECISION := 0.4;
    _bm25_weight        CONSTANT DOUBLE PRECISION := 0.4;
    _raw_blend_weight   DOUBLE PRECISION;  -- v0.8.1 F2: cardinal raw score blend
BEGIN
    -- Validate: need at least one retrieval signal
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.navigate_locate: both query_embedding and query_text are NULL/empty';
    END IF;

    _rrf_k_f := 60.0;
    _raw_blend_weight := 1.0 / (_rrf_k_f + 1.0);  -- same order as max RRF per signal

    -- ef_search GUC
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT, 100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- include_unverified GUC
    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN, FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    -- as_of_ts GUC (bitemporal point-in-time filter)
    BEGIN
        _as_of_ts := NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), '')::TIMESTAMPTZ;
    EXCEPTION WHEN OTHERS THEN
        _as_of_ts := NULL;
    END;

    -- graph_proximity_weight GUC
    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;
    _graph_weight := GREATEST(0.0, LEAST(0.5, _graph_weight));

    -- Parse query_text → tsquery
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
    WITH RECURSIVE
    -- Step 1: union candidates; JSONB predicate pushdown when jsonb_filter non-null
    raw_candidates AS (
        SELECT
            al.id,
            al.importance,
            al.created_at,
            al.commit_sha,
            al.verified_at,
            LEAST(length(al.lesson_text), 50)                                        AS text_len,
            -- vector score
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            -- v0.8.1 F3: topic in BM25 — setweight(topic, 'A') || lesson_tsv
            CASE
                WHEN _has_text AND (al.lesson_tsv @@ _tsquery
                     OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery)
                THEN ts_rank_cd(
                    setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv,
                    _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          -- JSONB predicate pushdown — uses GIN index on metadata when non-null
          AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
          -- project_id_filter — uses B-tree index pgmnemo_agent_lesson_project_idx
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          -- bitemporal: active rows only (unless as_of_ts set)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
          -- union: matched by vector OR BM25 (including topic match)
          AND (
              (_has_vec  AND al.embedding  IS NOT NULL)
           OR (_has_text AND (al.lesson_tsv @@ _tsquery
               OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery))
          )
    ),
    -- Step 2: sparse-safe RRF ranks (Cormack 2009)
    rrf_ranked AS (
        SELECT *,
            COUNT(*) OVER ()                                                          AS n_candidates,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score DESC NULLS LAST)               AS vec_rank,
            CASE WHEN raw_bm25_score > 0
                 THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                                   ORDER BY raw_bm25_score DESC NULLS LAST)
                 ELSE NULL
            END                                                                       AS bm25_rank_sparse
        FROM raw_candidates
    ),
    -- Step 3: RRF score + aux tie-breaker (identical formula to recall_hybrid v0.6.2)
    scored AS (
        SELECT
            r.id,
            r.importance,
            r.created_at,
            r.commit_sha,
            r.verified_at,
            r.text_len,
            r.vec_rank,
            COALESCE(r.bm25_rank_sparse, r.n_candidates + 1) AS bm25_rank_eff,
            r.raw_vec_score,
            r.raw_bm25_score,
            -- v0.8.1 F2: ordinal RRF + cardinal raw score blend
            (_vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + _bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                   r.n_candidates + 1)::DOUBLE PRECISION)
           + _raw_blend_weight * (
                 _vec_weight  * r.raw_vec_score
               + _bm25_weight * r.raw_bm25_score))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    -- Step 4: top-5 anchors for graph BFS
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    -- Step 5: BFS on active edges from top-5 anchors — BIDIRECTIONAL
    -- v0.9.1 fix: traverses ALL relation_types (was edge_kind IN causal/temporal)
    -- Bidirectional: discovers both forward and backward graph neighbors
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1,
               CASE WHEN me.source_id = gw.reached_id
                    THEN me.target_id
                    ELSE me.source_id
               END
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = gw.reached_id OR me.target_id = gw.reached_id
        )
        WHERE gw.depth < _max_depth
          -- v0.9.1 fix: handle both active-edge sentinels
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
    ),
    -- Step 6: proximity score from BFS depth
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    ),
    -- Step 7: final score = (rrf_sparse + aux) * (1 + graph); safety cap at 200 rows
    -- v0.8.1 F1: graph is multiplicative re-rank (tie-breaker, not driver)
    final_ranked AS (
        SELECT
            s.id,
            s.text_len,
            s.vec_rank,
            s.bm25_rank_eff,
            (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0
                               )
                           )::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE                                                             0.0
                            END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
              AS final_score
        FROM scored s
        LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
        ORDER BY (
                s.rrf_sparse
              + _aux_scale * (
                    0.05 * (s.importance::DOUBLE PRECISION / 5.0)
                  + 0.05 * GREATEST(0.0,
                               1.0 - LEAST(
                                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                                   1.0
                               )
                           )::DOUBLE PRECISION
                  + 0.05 * (CASE
                              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                              ELSE                                                             0.0
                            END)::DOUBLE PRECISION
                )
            ) * (1.0 + _graph_weight * COALESCE(gp.proximity, 0.0))
            DESC
        LIMIT 200  -- safety cap: prevents unbounded result sets for large corpora
    ),
    -- Step 8: budget window — cumulative char sum over score-descending order
    budget_window AS (
        SELECT
            fr.id,
            fr.final_score,
            fr.text_len,
            fr.vec_rank,
            fr.bm25_rank_eff,
            SUM(fr.text_len) OVER (
                ORDER BY fr.final_score DESC, fr.id ASC
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cum_chars,
            ROW_NUMBER() OVER (ORDER BY fr.final_score DESC, fr.id ASC) AS rn
        FROM final_ranked fr
    )
    SELECT
        bw.id                                                                         AS id,
        left(al.lesson_text, 50)                                                      AS preview,
        bw.final_score::FLOAT8                                                        AS score,
        bw.cum_chars::INT                                                             AS tokens_consumed,
        -- navigation_path: jsonb_gate if filter was applied, else dominant retrieval signal
        CASE
            WHEN jsonb_filter IS NOT NULL THEN 'jsonb_gate'
            WHEN bw.vec_rank <= bw.bm25_rank_eff THEN 'vector'
            ELSE 'bm25'
        END                                                                           AS navigation_path
    FROM budget_window bw
    JOIN pgmnemo.agent_lesson al ON al.id = bw.id
    WHERE bw.rn = 1                                    -- always return first row
       OR (bw.cum_chars - bw.text_len) < token_budget_chars   -- include while under budget
    ORDER BY bw.final_score DESC, bw.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT) IS
    'Token-economy navigation LOCATE (v0.9.1). '
    'Ranks lessons using the same hybrid RRF+aux+graph formula as recall_hybrid. '
    'v0.9.1 fixes: graph_walk now traverses ALL relation_types bidirectionally '
    '(was edge_kind IN causal/temporal — missed production edges with edge_kind=semantic). '
    'Returns id/preview/score/tokens_consumed/navigation_path — preview is first ~50 chars. '
    'token_budget_chars: cumulative Unicode character (code-point) limit on delivered previews; '
    'first row always returned regardless of budget. '
    'jsonb_filter: WHERE metadata @> jsonb_filter pushed into candidate scan (uses GIN index). '
    'project_id_filter: scopes candidates to a single project (uses B-tree index). '
    'navigation_path: ''jsonb_gate'' when filter applied; ''vector'' when vec dominant; ''bm25'' otherwise. '
    'Combine with navigate_expand() to retrieve content for chosen IDs.';
