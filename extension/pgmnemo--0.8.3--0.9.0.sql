-- pgmnemo--0.8.3--0.9.0.sql
-- Incremental upgrade: pgmnemo 0.8.3 → 0.9.0
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Token-economy fixes + recall_hybrid O(n) elimination.
--
-- ITEMS:
--   #1  Fix navigate_locate budget counter: text_len = LEAST(length, 50)
--   #1b Add project_id_filter INT to navigate_locate (parity with recall_hybrid)
--   #2  ingest(): NULL-embedding lessons are NOT ghosts (auto-verified)
--   #3  content_type + blob_ref + doc_ref nullable columns on agent_lesson
--   #4  recall_hybrid O(n) → O(k log n): two bounded CTEs (vec HNSW + BM25 GIN)
--       with C2 fix: vec LIMIT GREATEST(k*4, _ef_search), bm25 LIMIT GREATEST(k*4, 40)
--       NOTE: #4 inclusion gated on host benchmark (C1); may revert to 0.9.1.
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.0';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.0'" to load this file. \quit

-- ══════════════════════════════════════════════════════════════════════════════
-- #3: Additive columns — content_type, blob_ref, doc_ref
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS content_type TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS blob_ref     TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS doc_ref      TEXT DEFAULT NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.content_type IS
    'Content type tag (e.g. code, prose, config, log). '
    'Gates per-type dispatch (#5) and typed expand (#6) when G1 bench passes.';
COMMENT ON COLUMN pgmnemo.agent_lesson.blob_ref IS
    'Optional external blob reference (URI/path). NULL = inline lesson_text only.';
COMMENT ON COLUMN pgmnemo.agent_lesson.doc_ref IS
    'Optional document reference (URI/path). NULL = standalone lesson.';

-- ══════════════════════════════════════════════════════════════════════════════
-- #2: ingest() — NULL-embedding lessons are NOT ghosts
-- ══════════════════════════════════════════════════════════════════════════════
-- When p_embedding IS NULL (text-only ingest), auto-set verified_at so the lesson
-- participates in default recall (BM25 path) without requiring include_unverified.
-- Rationale: NULL embedding = text-only ingest, not unverified content.

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
LANGUAGE plpgsql AS $func$
DECLARE
    new_id             BIGINT;
    _content_hash      TEXT;
    _prior_count       INT;
    _dedup_id          BIGINT;
    _dedup_sim         DOUBLE PRECISION;
    _tokens            TEXT[];
    _token             TEXT;
    _token_counts      JSONB;
    _max_freq          INT;
    _total_tokens      INT;
    _trimmed_text      TEXT;
BEGIN
    -- F1: minimum length guard (fires BEFORE provenance gate trigger)
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) < 20 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: lesson_text too short (min 20 chars)';
    END IF;

    -- F2: token-frequency repetition guard
    _trimmed_text := trim(p_lesson_text);
    _tokens := regexp_split_to_array(
        regexp_replace(_trimmed_text, '\s+', ' ', 'g'), ' ');
    _total_tokens := array_length(_tokens, 1);

    IF _total_tokens > 0 THEN
        _token_counts := '{}'::JSONB;
        FOREACH _token IN ARRAY _tokens LOOP
            _token_counts := jsonb_set(
                _token_counts,
                ARRAY[_token],
                to_jsonb(COALESCE((_token_counts->>_token)::INT, 0) + 1)
            );
        END LOOP;

        SELECT MAX(value::INT)
        INTO _max_freq
        FROM jsonb_each_text(_token_counts);

        IF _max_freq::DOUBLE PRECISION / _total_tokens::DOUBLE PRECISION > 0.8 THEN
            RAISE EXCEPTION 'pgmnemo.ingest: lesson_text appears to be repetitive content';
        END IF;
    END IF;

    -- Embedding dimension guard
    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch -- expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- F3: near-duplicate embedding guard (cosine > 0.98, same project_id)
    IF p_embedding IS NOT NULL THEN
        SELECT id, (1.0 - (embedding <=> p_embedding))
        INTO _dedup_id, _dedup_sim
        FROM pgmnemo.agent_lesson
        WHERE is_active
          AND t_valid_to = 'infinity'::TIMESTAMPTZ
          AND embedding IS NOT NULL
          AND project_id = p_project_id
          AND (1.0 - (embedding <=> p_embedding)) > 0.98
        ORDER BY embedding <=> p_embedding
        LIMIT 1;

        IF FOUND THEN
            RAISE WARNING
                'pgmnemo.ingest: near-duplicate detected -- cosine similarity % > 0.98 '
                'to existing lesson_id=% (project_id=%). Returning existing lesson_id.',
                ROUND(_dedup_sim::NUMERIC, 4), _dedup_id, p_project_id;
            RETURN _dedup_id;
        END IF;
    END IF;

    -- Bitemporal dedup observability
    _content_hash := MD5(
        COALESCE(p_role, '')  || '|' ||
        COALESCE(p_topic, '') || '|' ||
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
        -- v0.9.0 #2: verified_at = NOW() for ALL lessons passing quality gates.
        -- ingest() IS the verification gate (F1/F2/F3 passed). NULL-embedding
        -- lessons are text-only (BM25 path); must not be ghost-excluded.
        -- Provenance tier still contributes to aux score in ranking.
        NOW()
    ) RETURNING id INTO new_id;

    IF _prior_count > 0 THEN
        RAISE NOTICE
            'pgmnemo.ingest: bitemporal close+create fired -- closed % prior version(s) '
            '(content_hash=%). New lesson_id=%.',
            _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$func$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API v0.9.0 with ingestion guards. '
    'F1 (min-length): RAISE EXCEPTION when lesson_text < 20 chars (fires before provenance trigger). '
    'F2 (repetition): RAISE EXCEPTION when most-frequent token > 80% of all tokens. '
    'F3 (dedup-warn): RAISE WARNING + RETURN existing lesson_id when cosine_sim > 0.98 '
    'to active lesson with same project_id (no new insert). '
    '#2 (v0.9.0): NULL-embedding (text-only) ingests auto-verify — not ghost-excluded from recall. '
    'Signature unchanged (9 params). '
    'Provenance gate trigger fires on INSERT (after F1/F2 guards pass, F3 short-circuits before INSERT).';

-- ══════════════════════════════════════════════════════════════════════════════
-- #1 + #1b: navigate_locate — budget counter fix + project_id_filter
-- ══════════════════════════════════════════════════════════════════════════════
-- Drop old 4-arg signature so CREATE OR REPLACE can add the 5th parameter.
DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB);

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
    _max_depth          CONSTANT INT := 2;  -- proximity scoring: 2-hop sufficient; deeper = navigate_expand
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
            -- #1 fix: budget counts delivered preview chars (<=50), not full lesson length
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
          -- #1b: project_id scoping — uses B-tree index pgmnemo_agent_lesson_project_idx
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
            -- v0.8.1 F2: ordinal RRF + cardinal raw score blend (absolute match strength survives)
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
    'Token-economy navigation LOCATE (v0.9.0). '
    'Ranks lessons using hybrid RRF+aux+graph formula. '
    'Returns id/preview/score/tokens_consumed/navigation_path — preview is first ~50 chars. '
    'token_budget_chars: cumulative Unicode character (code point) limit on delivered previews; '
    'first row always returned regardless of budget. '
    '#1 (v0.9.0): budget now counts preview characters actually delivered (<=50 chars/row). '
    'Callers will receive ~5x more IDs per equivalent budget after upgrade from 0.8.x. '
    'Reduce budget proportionally to preserve prior result counts. '
    'jsonb_filter: WHERE metadata @> jsonb_filter pushed into candidate scan (uses GIN index). '
    'project_id_filter: scopes candidates to a single project (uses B-tree index). '
    'navigation_path: ''jsonb_gate'' when filter applied; ''vector'' when vec dominant; ''bm25'' otherwise. '
    'Combine with navigate_expand() to retrieve content for chosen IDs.';

-- ══════════════════════════════════════════════════════════════════════════════
-- #4: recall_hybrid — O(n) → O(k log n) via two bounded CTEs
-- ══════════════════════════════════════════════════════════════════════════════
-- Root cause: single raw_candidates CTE computes distance in CASE expression
-- (HNSW index cannot activate) + OR predicate merges vec/bm25 sets (no pushdown)
-- + unbounded window functions over all N rows.
--
-- Fix: split into vec_candidates (ORDER BY <=> LIMIT → HNSW index scan) and
-- bm25_candidates (GIN tsquery scan + LIMIT), merge via LEFT JOIN + anti-join
-- UNION ALL, then run RRF window functions over bounded candidate set.
--
-- C2 fix (REVIEW_0.9): vec LIMIT = GREATEST(k*4, _ef_search),
--                       bm25 LIMIT = GREATEST(k*4, 40).
-- C7 fix (REVIEW_0.9): secondary sort key f.id ASC on final ORDER BY.
--
-- NOTE: #4 inclusion in 0.9.0 gated on host benchmark (REVIEW_0.9 C1).
--       May revert to 0.9.1 by founder decision.

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
    _vec_fetch_k        INT;   -- #4: bounded vec arm
    _bm25_fetch_k       INT;   -- #4: bounded bm25 arm
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

    -- #4: compute bounded fetch sizes (C2 fix from REVIEW_0.9)
    _vec_fetch_k  := GREATEST(k * 4, _ef_search);   -- align with HNSW internal probe count
    _bm25_fetch_k := GREATEST(k * 4, 40);            -- floor at 40 (no ef_search for GIN)

    RETURN QUERY
    WITH RECURSIVE
    -- ── Phase 1: HNSW vector retrieval (index scan) ──────────────────────────
    -- ORDER BY <=> LIMIT forces planner to use HNSW index scan: O(log n)
    vec_candidates AS (
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
            (1.0 - (al.embedding <=> query_embedding))::DOUBLE PRECISION AS raw_vec_score,
            0.0::DOUBLE PRECISION AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND _has_vec
          AND al.embedding IS NOT NULL
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
        ORDER BY al.embedding <=> query_embedding
        LIMIT _vec_fetch_k
    ),
    -- ── Phase 2: GIN BM25 retrieval (index scan) ────────────────────────────
    bm25_candidates AS (
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
            0.0::DOUBLE PRECISION AS raw_vec_score,
            ts_rank_cd(
                setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv,
                _tsquery, 32
            )::DOUBLE PRECISION AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.is_active
          AND _has_text
          AND (al.lesson_tsv @@ _tsquery
               OR to_tsvector('english', COALESCE(al.topic, '')) @@ _tsquery)
          AND (_include_unverified OR al.verified_at IS NOT NULL)
          AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
          AND (recall_hybrid.project_id_filter IS NULL
               OR al.project_id = recall_hybrid.project_id_filter)
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
        ORDER BY raw_bm25_score DESC
        LIMIT _bm25_fetch_k
    ),
    -- ── Merge: LEFT JOIN + anti-join UNION ALL ───────────────────────────────
    -- Each id appears exactly once; rows in both sets carry both non-zero scores.
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(b.raw_bm25_score, 0.0) AS raw_bm25_score
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
    -- ── RRF ranking: window functions over bounded candidate set, not N ──────
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
            -- v0.8.1 F1: graph is multiplicative re-rank (tie-breaker, not driver)
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
    ORDER BY f.final_score DESC, f.id ASC   -- C7: deterministic tie-breaker
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
    'Hybrid recall v0.9.0 — #4: O(n) → O(k log n) via two bounded CTEs. '
    'vec arm: ORDER BY <=> LIMIT GREATEST(k*4, ef_search) forces HNSW index scan. '
    'bm25 arm: GIN tsquery scan LIMIT GREATEST(k*4, 40). '
    'Merge: LEFT JOIN + anti-join UNION ALL (each id exactly once, both scores preserved). '
    'RRF window functions now over bounded candidate set (<=2*fetch_k rows), not full table. '
    'F2 (v0.8.2): NOTICE when 0 rows and ghost lessons exist in scope. '
    'v0.7.1 -- match_confidence formula corrected (BUG-1), graph_proximity note added. '
    'RRF (Reciprocal Rank Fusion, Cormack 2009): combines vector + BM25 ranks. '
    'Scoring: rrf_sparse + _aux_scale*(0.025*imp/5 + 0.025*conf + 0.05*recency + 0.05*prov) + delta*graph. '
    'confidence: per-lesson outcome-track-record [0,1] from reinforce(). '
    'match_confidence: vec_score (cosine similarity, [0,1]). On text-only path (NULL embedding) = 0.0. '
    'graph_proximity contributes only when mem_edge is populated; with no edges the graph term is 0 (correct). '
    'D-footgun: RAISE NOTICE when query_embedding IS NULL. '
    '17 output columns (15 existing + confidence REAL, match_confidence REAL).';
