-- pgmnemo--0.9.7--0.9.8.sql
-- Upgrade: pgmnemo 0.9.7 → 0.9.8
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Tiered-memory per-type dispatch + typed expand + selective-embedding policy
--
-- §2 TIERED_MEMORY_ACCESS_MODEL: LOCATE layer now routes each content_type to its
--    cheapest adequate index (bm25_entity / temporal_btree / graph_relation / unified).
--    DEEP-DIVE layer (navigate_expand) does typed dereference per content_type.
--
-- NEW OBJECTS:
--   1. pgmnemo.navigate_locate_dispatch() — per-type dispatch overload
--      - content_type_dispatch='entity'   → GIN BM25 on lesson_tsv (skip HNSW)
--      - content_type_dispatch='temporal' → btree on t_valid_from (skip HNSW)
--      - content_type_dispatch='relation' → mem_edge graph traversal (skip HNSW)
--      - content_type_dispatch=NULL       → delegate to existing navigate_locate (HNSW+BM25)
--   2. pgmnemo.navigate_expand_typed() — content-type-aware typed expand
--      - 'entity': metadata JSONB (canonical_name, entity_type) + connected lessons
--      - 'lesson': full lesson_text (same as current navigate_expand)
--      - 'relation': mem_edge neighbors only
--      - NULL/other: lesson_text (safe default)
--   3. pgmnemo.apply_selective_embedding_policy(p_dry_run) — selective-embedding backfill
--      - Sets embedding=NULL for non-semantic types (entity, fact, relation, temporal)
--      - p_dry_run=TRUE (default): returns count without modifying
--      - p_dry_run=FALSE: executes update, returns rows affected
--
-- INDEX: partial GIN index for entity-type BM25 dispatch (lesson_tsv WHERE content_type='entity')
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.8';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.8'" to load this file. \quit

-- ============================================================================
-- SUPPORTING INDEX: entity content_type GIN index (BM25 dispatch path)
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_pgmnemo_lesson_tsv_entity
    ON pgmnemo.agent_lesson USING gin (lesson_tsv)
    WHERE content_type = 'entity' AND is_active = TRUE;

CREATE INDEX IF NOT EXISTS ix_pgmnemo_content_type_active
    ON pgmnemo.agent_lesson (content_type)
    WHERE is_active = TRUE AND content_type IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_pgmnemo_temporal_content_type
    ON pgmnemo.agent_lesson (t_valid_from DESC)
    WHERE content_type = 'temporal' AND is_active = TRUE;

-- ============================================================================
-- 1. navigate_locate_dispatch — per-type access-path router
-- ============================================================================
--
-- Routes each query to the cheapest adequate index per content_type:
--   'entity'   → GIN BM25 on lesson_tsv/topic_tsv  (navigation_path='bm25_entity')
--   'temporal' → btree on t_valid_from DESC          (navigation_path='temporal_btree')
--   'relation' → mem_edge BFS from BM25 seed         (navigation_path='graph_relation')
--   NULL       → delegate to existing navigate_locate (navigation_path varies: vector/bm25/hybrid)
--
-- Return schema: identical to navigate_locate (id, preview, score, tokens_consumed, navigation_path)
-- Safe: does not replace navigate_locate; coexists as separate function.
-- ============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate_dispatch(
    query_embedding         vector(1024),
    query_text              text,
    token_budget_chars      integer      DEFAULT 2000,
    jsonb_filter            jsonb        DEFAULT NULL,
    project_id_filter       integer      DEFAULT NULL,
    content_type_dispatch   text         DEFAULT NULL   -- NULL = unified HNSW+BM25 path
)
RETURNS TABLE (
    id               bigint,
    preview          text,
    score            double precision,
    tokens_consumed  integer,
    navigation_path  text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
DECLARE
    _tsquery        TSQUERY;
    _has_text       BOOLEAN;
    _running_tokens INT := 0;
BEGIN
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    -- ─────────────────────────────────────────────────────────────────────
    -- PATH A: ENTITY DISPATCH — GIN BM25, no HNSW
    -- Handles content_type='entity' rows (canonical names, technologies, orgs)
    -- BM25 is the cheapest adequate path: exact/fuzzy name match via GIN tsvector
    -- ─────────────────────────────────────────────────────────────────────
    IF content_type_dispatch = 'entity' THEN
        IF NOT _has_text THEN
            RAISE EXCEPTION 'pgmnemo.navigate_locate_dispatch: entity dispatch requires non-empty query_text';
        END IF;
        BEGIN
            _tsquery := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            _tsquery := plainto_tsquery('english', query_text);
        END;

        RETURN QUERY
        WITH entity_candidates AS (
            SELECT
                al.id,
                left(al.lesson_text, 120)::TEXT                                  AS preview,
                ts_rank_cd(
                    setweight(al.topic_tsv, 'A') || al.lesson_tsv,
                    _tsquery, 32
                )::DOUBLE PRECISION                                               AS score,
                length(al.lesson_text)                                           AS chars
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.content_type = 'entity'
              AND (al.lesson_tsv @@ _tsquery OR al.topic_tsv @@ _tsquery)
              AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
              AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
            ORDER BY score DESC
            LIMIT 50
        ),
        budget_cumsum AS (
            SELECT
                ec.id,
                ec.preview,
                ec.score,
                ec.chars,
                SUM(ec.chars) OVER (ORDER BY ec.score DESC ROWS UNBOUNDED PRECEDING) AS cumsum
            FROM entity_candidates ec
        )
        SELECT
            bc.id,
            bc.preview,
            bc.score,
            LEAST(bc.cumsum, token_budget_chars)::INT                            AS tokens_consumed,
            'bm25_entity'::TEXT                                                   AS navigation_path
        FROM budget_cumsum bc
        WHERE bc.cumsum - bc.chars < token_budget_chars;
        RETURN;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────
    -- PATH B: TEMPORAL DISPATCH — btree on t_valid_from, no HNSW
    -- Handles "what happened recently / in window X" queries
    -- Recency ordering = cheapest adequate path for temporal content
    -- ─────────────────────────────────────────────────────────────────────
    IF content_type_dispatch = 'temporal' THEN
        RETURN QUERY
        WITH temporal_candidates AS (
            SELECT
                al.id,
                left(al.lesson_text, 120)::TEXT                                  AS preview,
                -- Score = recency: normalized epoch (recent = higher score)
                GREATEST(
                    1.0 - (EXTRACT(EPOCH FROM (NOW() - COALESCE(al.t_valid_from, al.created_at)))
                           / 86400.0 / 365.0),
                    0.0
                )::DOUBLE PRECISION                                               AS score,
                length(al.lesson_text)                                           AS chars
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.content_type = 'temporal'
              AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
              AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
            ORDER BY al.t_valid_from DESC NULLS LAST
            LIMIT 50
        ),
        budget_cumsum AS (
            SELECT
                tc.id, tc.preview, tc.score, tc.chars,
                SUM(tc.chars) OVER (ORDER BY tc.score DESC ROWS UNBOUNDED PRECEDING) AS cumsum
            FROM temporal_candidates tc
        )
        SELECT
            bc.id,
            bc.preview,
            bc.score,
            LEAST(bc.cumsum, token_budget_chars)::INT,
            'temporal_btree'::TEXT
        FROM budget_cumsum bc
        WHERE bc.cumsum - bc.chars < token_budget_chars;
        RETURN;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────
    -- PATH C: RELATION DISPATCH — graph traversal from BM25 seed
    -- Handles "what caused / is related to X" queries
    -- Seeds via BM25, then follows mem_edge to connected items
    -- ─────────────────────────────────────────────────────────────────────
    IF content_type_dispatch = 'relation' THEN
        IF NOT _has_text THEN
            RAISE EXCEPTION 'pgmnemo.navigate_locate_dispatch: relation dispatch requires non-empty query_text';
        END IF;
        BEGIN
            _tsquery := websearch_to_tsquery('english', query_text);
        EXCEPTION WHEN OTHERS THEN
            _tsquery := plainto_tsquery('english', query_text);
        END;

        RETURN QUERY
        WITH seed_ids AS (
            -- BM25 seed: find anchor lessons matching the query
            SELECT al.id AS seed_id, ts_rank_cd(al.lesson_tsv, _tsquery, 32)::DOUBLE PRECISION AS seed_score
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND (al.lesson_tsv @@ _tsquery OR al.topic_tsv @@ _tsquery)
              AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
            ORDER BY seed_score DESC
            LIMIT 10
        ),
        graph_neighbors AS (
            -- BFS 1-hop from seeds via mem_edge
            SELECT DISTINCT
                al.id,
                left(al.lesson_text, 120)::TEXT                                  AS preview,
                (me.weight * 0.7 + s.seed_score * 0.3)::DOUBLE PRECISION        AS score,
                length(al.lesson_text)                                           AS chars
            FROM seed_ids s
            JOIN pgmnemo.mem_edge me ON (me.source_id = s.seed_id OR me.target_id = s.seed_id)
            JOIN pgmnemo.agent_lesson al ON al.id = CASE
                WHEN me.source_id = s.seed_id THEN me.target_id
                ELSE me.source_id END
            WHERE al.is_active
              AND al.id <> s.seed_id
              AND (me.valid_until IS NULL OR me.valid_until >= NOW())
              AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
        ),
        budget_cumsum AS (
            SELECT
                gn.id, gn.preview, gn.score, gn.chars,
                SUM(gn.chars) OVER (ORDER BY gn.score DESC ROWS UNBOUNDED PRECEDING) AS cumsum
            FROM graph_neighbors gn
        )
        SELECT
            bc.id,
            bc.preview,
            bc.score,
            LEAST(bc.cumsum, token_budget_chars)::INT,
            'graph_relation'::TEXT
        FROM budget_cumsum bc
        WHERE bc.cumsum - bc.chars < token_budget_chars;
        RETURN;
    END IF;

    -- ─────────────────────────────────────────────────────────────────────
    -- PATH D: DEFAULT — delegate to existing navigate_locate (HNSW + BM25)
    -- Used for 'lesson', 'doc', NULL content types (semantic neighborhood is real)
    -- ─────────────────────────────────────────────────────────────────────
    RETURN QUERY
    SELECT nl.id, nl.preview, nl.score, nl.tokens_consumed, nl.navigation_path
    FROM pgmnemo.navigate_locate(
        query_embedding, query_text, token_budget_chars, jsonb_filter, project_id_filter
    ) nl;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_locate_dispatch IS
'Per-type access-path router (§2 TIERED_MEMORY_ACCESS_MODEL): routes each query to
the cheapest adequate index for the target content_type.
  entity   → GIN BM25 on lesson_tsv (skip HNSW; navigation_path=''bm25_entity'')
  temporal → btree on t_valid_from   (skip HNSW; navigation_path=''temporal_btree'')
  relation → mem_edge BFS + BM25 seed (skip HNSW; navigation_path=''graph_relation'')
  NULL     → existing navigate_locate HNSW+BM25 unified path (fallback)
Return schema identical to navigate_locate(). Does not replace it.';

-- ============================================================================
-- 2. navigate_expand_typed — content-type-aware typed dereference (deep-dive)
-- ============================================================================
--
-- Extends navigate_expand with typed materialization per content_type:
--   'entity'  → metadata JSONB (canonical_name, entity_type, aliases) + linked lessons
--   'lesson'  → full lesson_text (same as current navigate_expand behavior)
--   'relation'→ mem_edge graph neighbors only (the relation IS the edge)
--   NULL/other→ full lesson_text (safe default matching current behavior)
--
-- Returns: id, content_type, content, typed_detail JSONB, graph_neighbor_ids, tokens_consumed, navigation_path
-- ============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand_typed(
    ids                     bigint[],
    graph_expand_depth      integer          DEFAULT 0,
    graph_expand_threshold  double precision DEFAULT 0.5,
    relation_types          text[]           DEFAULT NULL
)
RETURNS TABLE (
    id                      bigint,
    content_type            text,
    content                 text,
    typed_detail            jsonb,
    graph_neighbor_ids      bigint[],
    graph_neighbor_previews text[],
    tokens_consumed         integer,
    navigation_path         text
)
LANGUAGE plpgsql
STABLE PARALLEL SAFE
AS $$
BEGIN
    IF ids IS NULL OR array_length(ids, 1) IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH seed_rows AS (
        SELECT
            al.id,
            al.content_type,
            al.lesson_text,
            al.metadata
        FROM pgmnemo.agent_lesson al
        WHERE al.id = ANY(ids)
          AND al.is_active
    ),
    -- typed_detail: content-type-specific structured projection
    typed_projection AS (
        SELECT
            sr.id,
            sr.content_type,
            -- content: what gets placed in agent context
            CASE sr.content_type
                WHEN 'entity' THEN
                    -- Entity: structured name + type, not just lesson_text
                    COALESCE(sr.metadata->>'canonical_name', sr.lesson_text)
                WHEN 'relation' THEN
                    -- Relation: brief description, graph expansion below
                    left(sr.lesson_text, 200)
                ELSE
                    -- lesson / doc / fact / NULL: full lesson_text
                    sr.lesson_text
            END::TEXT AS content,
            -- typed_detail: JSONB sidecar for structured modalities
            CASE sr.content_type
                WHEN 'entity' THEN
                    -- Entity detail: canonical metadata from JSONB
                    jsonb_build_object(
                        'canonical_name', sr.metadata->>'canonical_name',
                        'entity_type',    sr.metadata->>'entity_type',
                        'aliases',        sr.metadata->'aliases',
                        'source_ref',     sr.metadata->>'source_ref'
                    )
                WHEN 'fact' THEN
                    -- Fact detail: key-value pair from metadata
                    jsonb_build_object(
                        'key',   sr.metadata->>'key',
                        'value', sr.metadata->>'value',
                        'scope', sr.metadata->>'scope'
                    )
                ELSE NULL::JSONB
            END AS typed_detail,
            length(sr.lesson_text)                                                AS content_chars
        FROM seed_rows sr
    ),
    -- graph expansion (only when depth > 0)
    graph_neighbors AS (
        SELECT
            tp.id AS anchor_id,
            array_agg(neighbor.id)                                                AS neighbor_ids,
            array_agg(left(neighbor.lesson_text, 80))                             AS neighbor_previews
        FROM typed_projection tp
        CROSS JOIN LATERAL (
            SELECT al2.id, al2.lesson_text
            FROM pgmnemo.mem_edge me
            JOIN pgmnemo.agent_lesson al2 ON al2.id = CASE
                WHEN me.source_id = tp.id THEN me.target_id
                ELSE me.source_id END
            WHERE (me.source_id = tp.id OR me.target_id = tp.id)
              AND al2.is_active
              AND al2.id <> tp.id
              AND me.weight >= graph_expand_threshold::REAL
              AND (me.valid_until IS NULL OR me.valid_until >= NOW())
              AND (relation_types IS NULL OR me.relation_type = ANY(relation_types))
            LIMIT 20
        ) AS neighbor
        WHERE graph_expand_depth > 0
          AND (
              -- expand graph for relation content_type always (it IS the graph)
              tp.content_type = 'relation'
              -- expand entity context nodes too
              OR tp.content_type = 'entity'
              -- and honor the depth param for lessons
              OR graph_expand_depth >= 1
          )
        GROUP BY tp.id
    )
    SELECT
        tp.id,
        tp.content_type,
        tp.content,
        tp.typed_detail,
        COALESCE(gn.neighbor_ids, ARRAY[]::BIGINT[])                              AS graph_neighbor_ids,
        COALESCE(gn.neighbor_previews, ARRAY[]::TEXT[])                           AS graph_neighbor_previews,
        tp.content_chars                                                           AS tokens_consumed,
        -- navigation_path indicates which dereference was used
        CASE tp.content_type
            WHEN 'entity'   THEN 'typed_entity'
            WHEN 'fact'     THEN 'typed_fact'
            WHEN 'relation' THEN 'typed_relation'
            ELSE                 'content'
        END::TEXT                                                                  AS navigation_path
    FROM typed_projection tp
    LEFT JOIN graph_neighbors gn ON gn.anchor_id = tp.id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_expand_typed IS
'Typed dereference for the deep-dive tier (§3 TIERED_MEMORY_ACCESS_MODEL).
Each content_type gets its own materialization path:
  entity  → metadata JSONB (canonical_name, entity_type, aliases) + graph neighbors
  fact    → key/value pair from metadata JSONB + lesson_text
  relation→ lesson_text (brief) + mem_edge graph neighbors (relation IS the edge)
  lesson/NULL/other → full lesson_text (same as navigate_expand current behavior)
typed_detail JSONB sidecar carries structured data; content carries what goes in context.';

-- ============================================================================
-- 3. apply_selective_embedding_policy — selective-embedding backfill
-- ============================================================================
--
-- Sets embedding=NULL for items whose content_type does NOT require semantic embedding.
-- Non-semantic types per §5 TIERED_MEMORY_ACCESS_MODEL:
--   'entity'   → indexed by GIN/BM25 (exact name lookup); HNSW adds noise
--   'fact'     → indexed by btree/JSONB key; HNSW meaningless
--   'relation' → the edge IS the index; embedding adds nothing
--   'temporal' → indexed by btree on t_valid_from; HNSW meaningless
--
-- p_dry_run=TRUE (default): returns count without modifying data
-- p_dry_run=FALSE: executes UPDATE, returns count of rows affected
--
-- Idempotent: second run with same policy changes 0 rows (already NULL).
-- ============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.apply_selective_embedding_policy(
    p_dry_run  boolean DEFAULT TRUE
)
RETURNS TABLE (
    affected_count  bigint,
    by_content_type jsonb,
    dry_run         boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    _non_semantic_types TEXT[] := ARRAY['entity', 'fact', 'relation', 'temporal'];
    _counts JSONB;
    _total  BIGINT;
BEGIN
    -- Count by type first (always)
    SELECT
        jsonb_object_agg(
            COALESCE(sub.content_type, 'NULL'),
            cnt
        ),
        SUM(cnt)
    INTO _counts, _total
    FROM (
        SELECT content_type, COUNT(*) AS cnt
        FROM pgmnemo.agent_lesson
        WHERE is_active = TRUE
          AND content_type = ANY(_non_semantic_types)
          AND embedding IS NOT NULL   -- only those currently embedded
        GROUP BY content_type
    ) sub;

    IF NOT p_dry_run THEN
        -- Apply: set embedding=NULL for non-semantic types
        UPDATE pgmnemo.agent_lesson
        SET
            embedding    = NULL,
            updated_at   = NOW()
        WHERE is_active = TRUE
          AND content_type = ANY(_non_semantic_types)
          AND embedding IS NOT NULL;
        -- _total is exact because we checked IS NOT NULL above
    END IF;

    RETURN QUERY SELECT
        COALESCE(_total, 0)   AS affected_count,
        COALESCE(_counts, '{}'::JSONB) AS by_content_type,
        p_dry_run             AS dry_run;
END;
$$;

COMMENT ON FUNCTION pgmnemo.apply_selective_embedding_policy IS
'Selective-embedding backfill per §5 TIERED_MEMORY_ACCESS_MODEL.
Sets embedding=NULL for non-semantic content types (entity, fact, relation, temporal)
so they are indexed via GIN/btree/graph rather than HNSW. Reduces embedding index size
and removes noise from HNSW neighborhood for semantic (lesson/doc) queries.
p_dry_run=TRUE (default): preview only. p_dry_run=FALSE: executes update.
Run AFTER navigate_locate_dispatch is deployed so non-semantic types are still findable.';

-- Update extension version
-- (version number managed by pgmnemo.control; this script is the canonical change record)
