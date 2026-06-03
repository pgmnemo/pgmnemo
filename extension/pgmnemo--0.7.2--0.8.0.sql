-- pgmnemo--0.7.2--0.8.0.sql
-- Incremental upgrade: pgmnemo 0.7.2 → 0.8.0
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Token-economy navigation API + production maintenance primitives.
--
-- New functions (additive — no existing signatures changed):
--   navigate_locate()    Budget-bounded LOCATE: hybrid rank + JSONB pushdown + budget cap.
--   navigate_expand()    On-demand content + graph expansion for caller-chosen IDs.
--   reembed()            Single-row embedding refresh (UPDATE-only, bitemporal-safe).
--   reembed_batch()      Batch embedding refresh with FOR UPDATE SKIP LOCKED.
--   recompute_content()  In-place lesson_text/content_hash/tsv update (no close+create).
--
-- New columns:
--   agent_lesson.source_type   TEXT CHECK(...) DEFAULT 'auto_captured'
--   agent_lesson.embedding_at  TIMESTAMPTZ (tracks last embedding refresh)
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.8.0';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.8.0'" to load this file. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- S1: Schema additions — source_type + embedding_at
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS source_type TEXT
        DEFAULT 'auto_captured'
        CONSTRAINT ck_agent_lesson_source_type
            CHECK (source_type IN ('agent_authored', 'auto_captured', 'imported', 'system'));

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS embedding_at TIMESTAMPTZ;

-- Backfill embedding_at for rows that already have embeddings.
-- Use updated_at as a reasonable proxy for when the embedding was last set.
UPDATE pgmnemo.agent_lesson
SET embedding_at = updated_at
WHERE embedding IS NOT NULL
  AND embedding_at IS NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.source_type IS
    'Origin classification for this lesson. '
    'agent_authored: explicitly written by an agent. '
    'auto_captured: automatically generated from agent output (default). '
    'imported: loaded from an external system. '
    'system: created by pgmnemo internal processes.';

COMMENT ON COLUMN pgmnemo.agent_lesson.embedding_at IS
    'Timestamp of the most recent embedding update via reembed() or reembed_batch(). '
    'NULL for rows embedded before 0.8.0 (backfilled to updated_at on upgrade). '
    'Updated by reembed() and reembed_batch(); NOT updated by ingest() (use embedding_at '
    'IS NULL AND embedding IS NOT NULL to identify rows needing a refresh timestamp).';

-- ─────────────────────────────────────────────────────────────────────────────
-- S2: navigate_locate() — Budget-bounded LOCATE
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Algorithm:
--   1. raw_candidates: union of vector+BM25 candidates with JSONB predicate pushdown
--   2. rrf_ranked:     sparse-safe RRF ranks (Cormack 2009 — same as recall_hybrid)
--   3. scored:         rrf_sparse + aux(importance, recency, provenance) + graph_proximity
--   4. anchors/graph_walk/graph_proximity: BFS on causal+temporal edges (top-5 anchors)
--   5. budget_window:  SUM(length(lesson_text)) window; stop when cumulative > budget
--   6. Output:         id, score, tokens_consumed (cumulative chars up to this row),
--                      navigation_path ('vector'|'bm25'|'jsonb_gate')
--
-- navigation_path:
--   'jsonb_gate' when jsonb_filter is non-null (JSONB predicate gated the candidate set)
--   'vector'     when vec_rank <= effective_bm25_rank (vector was dominant signal)
--   'bm25'       otherwise (BM25 was dominant signal)
--
-- Budget semantics: the first row is always returned even if its length exceeds budget.
-- tokens_consumed is the cumulative char count INCLUDING the current row.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT              DEFAULT 2000,
    jsonb_filter      JSONB             DEFAULT NULL
)
RETURNS TABLE (
    id              BIGINT,
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
    _max_depth          CONSTANT INT := 5;
    _rrf_k_f            DOUBLE PRECISION;
    _aux_scale          CONSTANT DOUBLE PRECISION := (0.8 / 61.0) / 0.76;
    _as_of_ts           TIMESTAMPTZ;
    _vec_weight         CONSTANT DOUBLE PRECISION := 0.4;
    _bm25_weight        CONSTANT DOUBLE PRECISION := 0.4;
BEGIN
    -- Validate: need at least one retrieval signal
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;
    IF NOT _has_vec AND NOT _has_text THEN
        RAISE EXCEPTION 'pgmnemo.navigate_locate: both query_embedding and query_text are NULL/empty';
    END IF;

    _rrf_k_f := 60.0;

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
            length(al.lesson_text)                                                   AS text_len,
            -- vector score
            CASE
                WHEN _has_vec AND al.embedding IS NOT NULL
                THEN (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_vec_score,
            -- BM25 score (ts_rank_cd norm=32 → bounded [0,1])
            CASE
                WHEN _has_text AND al.lesson_tsv @@ _tsquery
                THEN ts_rank_cd(al.lesson_tsv, _tsquery, 32)::DOUBLE PRECISION
                ELSE 0.0::DOUBLE PRECISION
            END AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          -- JSONB predicate pushdown — uses GIN index on metadata when non-null
          AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
          -- bitemporal: active rows only (unless as_of_ts set)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
          -- union: matched by vector OR BM25
          AND (
              (_has_vec  AND al.embedding  IS NOT NULL)
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
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
            -- rrf_sparse primary score
            (_vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + _bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                   r.n_candidates + 1)::DOUBLE PRECISION))
                AS rrf_sparse
        FROM rrf_ranked r
    ),
    -- Step 4: top-5 anchors for graph BFS
    anchors AS (
        SELECT id FROM scored ORDER BY rrf_sparse DESC LIMIT 5
    ),
    -- Step 5: BFS on causal + temporal edges from top-5 anchors
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND gw.depth < _max_depth
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
    -- Step 7: final score = rrf_sparse + aux + graph; safety cap at 200 rows
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
              + _graph_weight * COALESCE(gp.proximity, 0.0)
            ) AS final_score
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
              + _graph_weight * COALESCE(gp.proximity, 0.0)
            ) DESC
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
        bw.final_score::FLOAT8                                                        AS score,
        bw.cum_chars::INT                                                             AS tokens_consumed,
        -- navigation_path: jsonb_gate if filter was applied, else dominant retrieval signal
        CASE
            WHEN jsonb_filter IS NOT NULL THEN 'jsonb_gate'
            WHEN bw.vec_rank <= bw.bm25_rank_eff THEN 'vector'
            ELSE 'bm25'
        END                                                                           AS navigation_path
    FROM budget_window bw
    WHERE bw.rn = 1                                    -- always return first row
       OR (bw.cum_chars - bw.text_len) < token_budget_chars   -- include while under budget
    ORDER BY bw.final_score DESC, bw.id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB) IS
    'Token-economy navigation LOCATE (v0.8.0). '
    'Ranks lessons using the same hybrid RRF+aux+graph formula as recall_hybrid v0.6.2. '
    'Returns ONLY id/score/tokens_consumed/navigation_path — no content. '
    'token_budget_chars: cumulative char limit; first row always returned. '
    'jsonb_filter: WHERE metadata @> jsonb_filter pushed into candidate scan (uses GIN index). '
    'navigation_path: ''jsonb_gate'' when filter applied; ''vector'' when vec dominant; ''bm25'' otherwise. '
    'Combine with navigate_expand() to retrieve content for chosen IDs.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S3: navigate_expand() — On-demand content + graph expansion
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Returns full lesson_text for caller-chosen IDs.
-- If expand_fields non-empty: projects those keys from metadata JSONB into expand_detail.
-- If graph_expand_depth >= 1: recursively follows causal+temporal edges from input IDs,
--   only traversing edges with weight >= graph_expand_threshold.
--   Neighbour rows get navigation_path='graph_expand'; direct rows get 'content'.
--   Deduplication: input IDs always take priority (navigation_path='content').
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand(
    ids                    BIGINT[],
    expand_fields          TEXT[]           DEFAULT '{}',
    graph_expand_depth     INT              DEFAULT 1,
    graph_expand_threshold FLOAT            DEFAULT 0.7
)
RETURNS TABLE (
    id              BIGINT,
    content         TEXT,
    expand_detail   JSONB,
    navigation_path TEXT
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
    -- Step 2: BFS graph expansion (only when graph_expand_depth >= 1)
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

        -- Recursive: traverse causal + temporal edges, weight-gated
        SELECT
            al.id,
            al.lesson_text,
            al.metadata,
            ge.depth + 1,
            ge.path || al.id
        FROM graph_expand ge
        JOIN pgmnemo.mem_edge me ON me.source_id = ge.node_id
        JOIN pgmnemo.agent_lesson al ON al.id = me.target_id
        WHERE graph_expand_depth >= 1
          AND ge.depth < graph_expand_depth
          AND me.edge_kind IN ('causal', 'temporal')
          AND me.weight >= graph_expand_threshold::REAL
          AND me.valid_until IS NULL
          AND al.is_active
          AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
          AND NOT (al.id = ANY(ge.path))         -- cycle guard
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
    )
    -- Step 4: union seed + expanded, seed takes priority on id collision
    SELECT sr.id, sr.lesson_text AS content, sr.expand_detail, sr.navigation_path
    FROM seed_rows sr

    UNION ALL

    SELECT er.id, er.lesson_text AS content, er.expand_detail, er.navigation_path
    FROM expanded_rows er

    ORDER BY id ASC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.navigate_expand(BIGINT[], TEXT[], INT, FLOAT) IS
    'Token-economy navigation EXPAND (v0.8.0). '
    'Returns full lesson_text + optional JSONB field projection for caller-chosen IDs. '
    'ids: IDs returned by navigate_locate (or any source). '
    'expand_fields: keys to project from metadata JSONB into expand_detail (empty = NULL). '
    'graph_expand_depth: BFS depth for causal+temporal edge traversal (0 = no expansion). '
    'graph_expand_threshold: minimum edge weight [0,1] to traverse (default 0.7). '
    'navigation_path: ''content'' for requested IDs; ''graph_expand'' for BFS neighbours. '
    'Typically called after navigate_locate(); use navigate_locate() to discover IDs '
    'within a token budget, then navigate_expand() to retrieve content for chosen subset.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S4: reembed() — Single-row embedding refresh
-- ─────────────────────────────────────────────────────────────────────────────
--
-- UPDATE-only: bitemporal trigger (_close_prior_version) fires on INSERT only.
-- lesson_tsv trigger fires on UPDATE OF lesson_text only — not triggered here.
-- _set_updated_at trigger fires on UPDATE — updates updated_at correctly.
-- Does NOT create a new row, does NOT change lesson_text/content_hash/id.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reembed(
    p_lesson_id  BIGINT,
    p_new_vector vector(1024)
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_new_vector IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.reembed: p_new_vector must not be NULL';
    END IF;

    IF vector_dims(p_new_vector) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.reembed: expected 1024 dims, got %',
            vector_dims(p_new_vector);
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET embedding    = p_new_vector,
        embedding_at = now()
    WHERE id         = p_lesson_id
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgmnemo.reembed: lesson % not found or not active', p_lesson_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.reembed(BIGINT, vector) IS
    'Refresh the embedding for a single active lesson (v0.8.0). '
    'Updates embedding + embedding_at without creating a new bitemporal row. '
    'Safe to call concurrently with ingest(): UPDATE does not fire the INSERT-only '
    '_close_prior_version trigger. Raises if lesson not found or not active. '
    'For batch refresh see reembed_batch().';

-- ─────────────────────────────────────────────────────────────────────────────
-- S5: reembed_batch() — Batch embedding refresh
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Processes IDs in the order given. Caller SHOULD pass IDs in ascending order
-- to prevent deadlocks with other batch jobs.
-- FOR UPDATE SKIP LOCKED: skips rows locked by concurrent ingest()/reinforce().
-- Returns count of successfully updated rows (< input length if rows were skipped).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.reembed_batch(
    p_lesson_ids  BIGINT[],
    p_new_vectors vector[]
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    _count  INT := 0;
    _i      INT;
    _locked BIGINT;
BEGIN
    IF p_lesson_ids IS NULL OR array_length(p_lesson_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    IF array_length(p_lesson_ids, 1) <> array_length(p_new_vectors, 1) THEN
        RAISE EXCEPTION
            'pgmnemo.reembed_batch: ids length (%) differs from vectors length (%)',
            array_length(p_lesson_ids, 1),
            array_length(p_new_vectors, 1);
    END IF;

    FOR _i IN 1..array_length(p_lesson_ids, 1) LOOP
        -- Acquire row lock; skip rows held by concurrent writers
        SELECT id INTO _locked
        FROM pgmnemo.agent_lesson
        WHERE id         = p_lesson_ids[_i]
          AND is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
        FOR UPDATE SKIP LOCKED;

        IF FOUND THEN
            UPDATE pgmnemo.agent_lesson
            SET embedding    = p_new_vectors[_i],
                embedding_at = now()
            WHERE id = p_lesson_ids[_i];
            _count := _count + 1;
        END IF;
    END LOOP;

    RETURN _count;
END;
$$;

COMMENT ON FUNCTION pgmnemo.reembed_batch(BIGINT[], vector[]) IS
    'Batch embedding refresh for multiple lessons (v0.8.0). '
    'ids and vectors arrays must have the same length. '
    'Uses FOR UPDATE SKIP LOCKED: skips rows held by concurrent ingest()/reinforce(). '
    'Returns count of rows actually updated (may be < input length if rows were skipped). '
    'Lock ordering: pass IDs in ascending order to prevent deadlocks across concurrent batches. '
    'Each row processed independently — partial success is normal and expected under load.';

-- ─────────────────────────────────────────────────────────────────────────────
-- S6: recompute_content() — In-place lesson_text update
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Automatic cascade on UPDATE OF lesson_text:
--   content_hash: GENERATED ALWAYS AS (MD5(...||lesson_text)) — PG recomputes automatically.
--   lesson_tsv:   pgmnemo_agent_lesson_tsv_trg fires on UPDATE OF lesson_text → refreshed.
--   updated_at:   _set_updated_at trigger fires on any UPDATE → refreshed.
-- Does NOT fire _close_prior_version (INSERT-only trigger).
-- Preserves: id, embedding, edges, provenance, confidence, source_type.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recompute_content(
    p_lesson_id BIGINT,
    p_new_text  TEXT
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_new_text IS NULL OR length(trim(p_new_text)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.recompute_content: p_new_text must be non-empty';
    END IF;

    UPDATE pgmnemo.agent_lesson
    SET lesson_text = p_new_text
    WHERE id        = p_lesson_id
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'pgmnemo.recompute_content: lesson % not found or not active',
            p_lesson_id;
    END IF;
    -- content_hash recomputed automatically (GENERATED ALWAYS AS).
    -- lesson_tsv refreshed automatically (UPDATE OF lesson_text trigger).
    -- updated_at refreshed automatically (_set_updated_at trigger).
    -- No new row created (_close_prior_version is INSERT-only).
END;
$$;

COMMENT ON FUNCTION pgmnemo.recompute_content(BIGINT, TEXT) IS
    'In-place lesson_text update without bitemporal close+create churn (v0.8.0). '
    'Cascade: content_hash recomputed (GENERATED ALWAYS AS), lesson_tsv refreshed '
    '(pgmnemo_agent_lesson_tsv_trg), updated_at refreshed (_set_updated_at). '
    'Preserves: id, embedding, mem_edges, provenance, confidence, source_type. '
    'Raises if lesson not found or not active (t_valid_to = infinity). '
    'Note: embedding remains stale after this call; follow up with reembed() if needed.';
