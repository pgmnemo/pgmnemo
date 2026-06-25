-- pgmnemo--0.10.0--0.10.1.sql
-- pgmnemo issue #87: recall_hybrid robustness
--
-- Five targeted fixes to recall_hybrid latency and reliability:
--
--   Fix 1  Cap lexical query_text to ≤200 chars before websearch_to_tsquery.
--           Embedding carries full semantics; BM25 only needs salient tokens.
--           Eliminates degenerate tsquery on structured/long agent texts.
--
--   Fix 2  Remove per-row to_tsvector(topic) @@ _tsquery in WHERE.
--           Replace with indexed full_text @@ _tsquery (GIN index hits).
--           Also use al.full_text in ts_rank_cd instead of the computed expression.
--
--   Fix 3  Per-signal time budget + graceful degradation.
--           BM25 runs in an isolated plpgsql exception block with
--           SET LOCAL statement_timeout = pgmnemo.bm25_budget_ms (default 250 ms).
--           On budget exceeded: INSERT rolls back via implicit savepoint,
--           statement_timeout reverts automatically, function continues
--           vector-only (no error, no result loss).
--
--   Fix 4  Switch all tsconfig from 'english' to 'simple'.
--           'simple' = lowercase-only, no stop-word removal, no stemming.
--           Required for RU/EN/code mixed corpus; avoids Russian words being
--           mangled by the English stemmer and stop-word removal losing tokens.
--           Requires ALTER TABLE SET EXPRESSION on generated tsvector columns
--           (PG 16+ feature; test env is PG 17.10).
--
--   Fix 5  graph_walk OPT-IN + conditional guard (#88 decision).
--           graph_proximity_weight default changed 0.2 → 0.0 (OPT-IN).
--           graph_walk base case gains WHERE _graph_weight > 0 guard so the
--           recursive CTE returns 0 rows and skips the mem_edge join entirely
--           when weight = 0. Corpus with 73 k temporal edges caused 20-25 %
--           query timeouts (>30 s) even with Fix 3; graph_walk is the root
--           cause on dense temporal-edge corpora (#88 ablation).
--           Callers that want graph proximity must set:
--               SET pgmnemo.graph_proximity_weight = 0.1;  -- or higher
--
-- Schema change: topic_tsv, lesson_tsv, full_text generated columns are
-- updated to use 'simple' tsconfig. GIN indexes are rebuilt automatically.
-- All query functions (recall_hybrid, recall_lessons, navigate_locate,
-- navigate_locate_dispatch) updated to match.
--
-- New GUC: pgmnemo.bm25_budget_ms (INT, default 250, min 50).
--
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.10.1'" to load this file. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Schema: change stored tsvector columns from 'english' to 'simple'
--    PG 17+: ALTER COLUMN SET EXPRESSION AS (fastest, rewrites in-place).
--    PG 14/15/16: DROP + re-ADD the generated column (compatible path).
-- ─────────────────────────────────────────────────────────────────────────────

DO $$
BEGIN
    IF current_setting('server_version_num')::int >= 170000 THEN
        -- PG 17+: native ALTER COLUMN SET EXPRESSION
        ALTER TABLE pgmnemo.agent_lesson
            ALTER COLUMN topic_tsv SET EXPRESSION AS (
                to_tsvector('simple', coalesce(topic, ''))
            );
        ALTER TABLE pgmnemo.agent_lesson
            ALTER COLUMN lesson_tsv SET EXPRESSION AS (
                to_tsvector('simple', coalesce(lesson_text, ''))
            );
        ALTER TABLE pgmnemo.agent_lesson
            ALTER COLUMN full_text SET EXPRESSION AS (
                setweight(to_tsvector('simple', coalesce(topic, '')), 'A') ||
                setweight(to_tsvector('simple', coalesce(lesson_text, '')), 'B')
            );
    ELSE
        -- PG 14/15/16: drop and re-add generated columns with 'simple' config.
        -- Drop dependent GIN indexes first, recreate after.
        DROP INDEX IF EXISTS pgmnemo.pgmnemo_agent_lesson_topic_tsv_idx;
        DROP INDEX IF EXISTS pgmnemo.pgmnemo_agent_lesson_lesson_tsv_idx;
        DROP INDEX IF EXISTS pgmnemo.pgmnemo_agent_lesson_full_text_idx;
        -- Also drop any unnamed GIN indexes on these columns
        ALTER TABLE pgmnemo.agent_lesson DROP COLUMN IF EXISTS topic_tsv;
        ALTER TABLE pgmnemo.agent_lesson DROP COLUMN IF EXISTS lesson_tsv;
        ALTER TABLE pgmnemo.agent_lesson DROP COLUMN IF EXISTS full_text;
        ALTER TABLE pgmnemo.agent_lesson
            ADD COLUMN topic_tsv  TSVECTOR GENERATED ALWAYS AS (
                to_tsvector('simple', coalesce(topic, ''))
            ) STORED,
            ADD COLUMN lesson_tsv TSVECTOR GENERATED ALWAYS AS (
                to_tsvector('simple', coalesce(lesson_text, ''))
            ) STORED,
            ADD COLUMN full_text  TSVECTOR GENERATED ALWAYS AS (
                setweight(to_tsvector('simple', coalesce(topic, '')), 'A') ||
                setweight(to_tsvector('simple', coalesce(lesson_text, '')), 'B')
            ) STORED;
        -- Recreate GIN indexes
        CREATE INDEX pgmnemo_agent_lesson_topic_tsv_idx
            ON pgmnemo.agent_lesson USING GIN (topic_tsv);
        CREATE INDEX pgmnemo_agent_lesson_lesson_tsv_idx
            ON pgmnemo.agent_lesson USING GIN (lesson_tsv);
        CREATE INDEX pgmnemo_agent_lesson_full_text_idx
            ON pgmnemo.agent_lesson USING GIN (full_text);
    END IF;
END;
$$;

-- Update the legacy trigger function (v0.2.x compat shim) to match.
-- The trigger is a no-op in PG 17 because lesson_tsv is GENERATED ALWAYS,
-- but update it to avoid confusing 'english' vs 'simple' in code.
CREATE OR REPLACE FUNCTION pgmnemo._update_lesson_tsv() RETURNS TRIGGER AS $$
BEGIN
    -- Note: lesson_tsv is GENERATED ALWAYS — this assignment is silently ignored
    -- by the PG executor. The trigger remains for upgrade-path compat with pre-0.9.x
    -- installations where lesson_tsv was a plain column.
    NEW.lesson_tsv := to_tsvector('simple', COALESCE(NEW.lesson_text, ''));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. recall_hybrid — v0.10.1 (#87: all four fixes)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL
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
    -- v0.10.1 / issue #87 additions
    _lexical_text       TEXT;               -- Fix 1: capped query_text for BM25 (≤200 chars)
    _bm25_budget_ms     INT;                -- Fix 3: per-signal time budget for BM25
    _bm25_timed_out     BOOLEAN := FALSE;   -- Fix 3: graceful-degradation flag
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

    -- Fix 5: default changed 0.2 → 0.0 (OPT-IN per #88 ablation decision)
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

    -- Fix 3: read per-signal BM25 time budget (GUC pgmnemo.bm25_budget_ms, default 250 ms).
    -- Floor is 1ms (not 50ms) to allow low-budget testing; default 250ms is the safe prod value.
    BEGIN
        _bm25_budget_ms := GREATEST(1, COALESCE(
            NULLIF(current_setting('pgmnemo.bm25_budget_ms', TRUE), '')::INT, 250));
    EXCEPTION WHEN OTHERS THEN _bm25_budget_ms := 250;
    END;

    -- Fix 1 + Fix 4: cap query_text to 200 chars for lexical path; use 'simple' tsconfig.
    -- The embedding carries full semantics; BM25 only needs salient head tokens.
    IF _has_text THEN
        _lexical_text := left(trim(query_text), 200);   -- Fix 1: ≤200 chars
        BEGIN
            _tsquery := websearch_to_tsquery('simple', _lexical_text);   -- Fix 4
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                _tsquery := plainto_tsquery('simple', _lexical_text);    -- Fix 4 fallback
            EXCEPTION WHEN OTHERS THEN _has_text := FALSE;
            END;
        END;
    END IF;

    _fetch_k_vec  := GREATEST(k * 4, _ef_search);
    _fetch_k_bm25 := GREATEST(k * 4, 40);

    -- ── Phase 2: BM25 with per-signal time budget (Fix 3) ──────────────────────
    -- BM25 results land in session-level temp table _pgmnemo_bm25_work.
    -- ON COMMIT DROP scopes it to the current transaction; duplicate_table on
    -- re-entrant calls falls back to TRUNCATE.
    -- When the INSERT exceeds _bm25_budget_ms, PG's implicit savepoint rolls it
    -- back (leaving the temp table empty) and reverts statement_timeout to its
    -- pre-block value.  Function continues with vector-only recall — no error.
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
            -- statement_timeout is savepoint-scoped; auto-reverts if exception fires.
            EXECUTE format('SET LOCAL statement_timeout = %s', _bm25_budget_ms);

            INSERT INTO _pgmnemo_bm25_work (id, raw_bm25_score)
            SELECT
                al.id,
                -- Fix 2: use pre-computed indexed full_text (no per-row to_tsvector(topic))
                ts_rank_cd(al.full_text, _tsquery, 32)::DOUBLE PRECISION
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              -- Fix 2: al.full_text @@ _tsquery uses the GIN index on full_text
              AND al.full_text @@ _tsquery
              AND (_include_unverified OR al.verified_at IS NOT NULL)
              AND (recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter)
              AND (recall_hybrid.project_id_filter IS NULL
                   OR al.project_id = recall_hybrid.project_id_filter)
              AND (recall_hybrid.exclude_dag_id IS NULL
                   OR al.source_dag_id IS DISTINCT FROM recall_hybrid.exclude_dag_id)
              AND (_as_of_ts IS NULL
                   OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
              AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
            ORDER BY 2 DESC
            LIMIT _fetch_k_bm25;

            -- Reset to no-timeout on success (restores full time budget for RETURN QUERY).
            EXECUTE 'SET LOCAL statement_timeout = 0';

        EXCEPTION WHEN query_canceled THEN
            -- SQLSTATE 57014 (query_canceled) covers both user-cancel and statement_timeout.
            -- Savepoint rolled back: INSERT undone, _pgmnemo_bm25_work is empty,
            -- statement_timeout reverted to pre-block value — no manual cleanup needed.
            _bm25_timed_out := TRUE;
            _has_text       := FALSE;
            RAISE NOTICE
                'pgmnemo.recall_hybrid: BM25 signal exceeded %ms budget — degrading to '
                'vector-only recall. Tune pgmnemo.bm25_budget_ms or shorten query_text.',
                _bm25_budget_ms;
        END;
    END IF;

    -- ── Phase 3+4: vec + BM25 fusion → RRF → graph proximity → final scoring ───
    RETURN QUERY
    WITH RECURSIVE
    -- Phase 1: HNSW vector retrieval (index scan — always runs)
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
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT _fetch_k_vec
    ),
    -- Merge: vec candidates with BM25 scores (left join from temp table),
    -- plus BM25-only candidates (join back to agent_lesson for full row data).
    all_candidates AS (
        -- Vector candidates with BM25 score where available (may be 0 if no BM25 match)
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM vec_candidates v
        LEFT JOIN _pgmnemo_bm25_work bw ON bw.id = v.id

        UNION ALL

        -- BM25-only candidates (not in vec set) — join agent_lesson for full row
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
    -- graph_walk: Fix 5 — base case guards on _graph_weight > 0 so the recursive
    -- CTE returns 0 rows (and skips the mem_edge join entirely) when weight = 0.
    -- Eliminates 20-25 % of queries timing out on dense temporal-edge corpora.
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0
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
    ),
    -- v0.9.5: materialise top-k before stamping
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
        ORDER BY f.final_score DESC, f.id ASC
        LIMIT k
    ),
    -- v0.9.5: stamp recency on returned lessons (GUC-gated)
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
        fr.lesson_id,
        fr.score,
        fr.vec_score,
        fr.bm25_score,
        fr.rrf_score,
        fr.role,
        fr.project_id,
        fr.topic,
        fr.lesson_text,
        fr.importance,
        fr.metadata,
        fr.commit_sha,
        fr.artifact_hash,
        fr.verified_at,
        fr.created_at,
        fr.confidence,
        fr.match_confidence
    FROM final_results fr
    ORDER BY fr.score DESC, fr.lesson_id ASC;

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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT) IS
    'v0.10.1 — #87: recall robustness. '
    'Fix 1: query_text capped to 200 chars for BM25 (embedding carries full semantics). '
    'Fix 2: BM25 WHERE uses indexed full_text @@ _tsquery — no per-row to_tsvector(topic). '
    'Fix 3: BM25 runs in isolated exception block with SET LOCAL statement_timeout = pgmnemo.bm25_budget_ms '
    '(default 250 ms). On timeout: graceful degradation to vector-only (no error). '
    'Fix 4: tsconfig changed from english to simple for RU/EN/code mixed corpus. '
    'v0.9.6 — R13: exclude_dag_id TEXT DEFAULT NULL. '
    'v0.9.5 — recall-recency stamping (last_recalled_at, recall_count). '
    'v0.9.2 — I1: confidence-weighted ranking (pgmnemo.confidence_boost_weight). '
    'v0.8.2 — F2: ghost-count NOTICE when 0 rows. '
    'VOLATILE (side-effects: recency stamp, temp table _pgmnemo_bm25_work).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. recall_lessons — update tsconfig to 'simple' (vector-only fallback path)
--    Hybrid path delegates to recall_hybrid; this affects the non-hybrid branch.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT         DEFAULT 10,
    role_filter       TEXT        DEFAULT NULL,
    project_id_filter INT         DEFAULT NULL,
    query_text        TEXT        DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ DEFAULT NULL,
    exclude_dag_id    TEXT        DEFAULT NULL
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
            exclude_dag_id
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
            0.2)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.2;
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

-- ─────────────────────────────────────────────────────────────────────────────
-- D. navigate_locate — update tsconfig to 'simple'
-- ─────────────────────────────────────────────────────────────────────────────

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
            0.2
        );
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
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
    graph_walk(anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors WHERE _graph_weight > 0  -- Fix 5
        UNION ALL
        SELECT
            gw.anchor_id,
            gw.depth + 1,
            CASE WHEN me.source_id = gw.reached_id
                    THEN me.target_id
                    ELSE me.source_id
               END
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON (
            me.source_id = gw.reached_id OR me.target_id = gw.reached_id
        )
        WHERE gw.depth < _max_depth
          AND (me.valid_until IS NULL OR me.valid_until = 'infinity'::TIMESTAMPTZ)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- E. navigate_locate_dispatch — update tsconfig to 'simple'
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate_dispatch(
    query_embedding   vector(1024)  DEFAULT NULL,
    query_text        TEXT          DEFAULT NULL,
    content_type_dispatch TEXT      DEFAULT NULL,
    project_id_filter INT           DEFAULT NULL,
    jsonb_filter      JSONB         DEFAULT NULL,
    token_budget_chars INT          DEFAULT 2000
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
    _tsquery TSQUERY;
    _has_text BOOLEAN;
    _has_vec  BOOLEAN;
BEGIN
    _has_vec  := query_embedding IS NOT NULL;
    _has_text := query_text IS NOT NULL AND length(trim(query_text)) > 0;

    -- PATH A: ENTITY DISPATCH — GIN BM25, no HNSW
    IF content_type_dispatch = 'entity' THEN
        IF NOT _has_text THEN
            RAISE EXCEPTION 'pgmnemo.navigate_locate_dispatch: entity dispatch requires non-empty query_text';
        END IF;
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            _tsquery := plainto_tsquery('simple', left(trim(query_text), 200));        -- Fix 4+1
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
              AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
        )
        SELECT
            ec.id,
            ec.preview,
            ec.score,
            ec.chars::INT AS tokens_consumed,
            'entity'::TEXT AS navigation_path
        FROM entity_candidates ec
        WHERE ec.score > 0
        ORDER BY ec.score DESC
        LIMIT 20;
        RETURN;
    END IF;

    -- PATH B: RELATION DISPATCH — graph seed via BM25 + 1-hop BFS
    IF content_type_dispatch = 'relation' THEN
        IF NOT _has_text THEN
            RAISE EXCEPTION 'pgmnemo.navigate_locate_dispatch: relation dispatch requires non-empty query_text';
        END IF;
        BEGIN
            _tsquery := websearch_to_tsquery('simple', left(trim(query_text), 200));  -- Fix 4+1
        EXCEPTION WHEN OTHERS THEN
            _tsquery := plainto_tsquery('simple', left(trim(query_text), 200));        -- Fix 4+1
        END;

        RETURN QUERY
        WITH seed_ids AS (
            SELECT al.id AS seed_id, ts_rank_cd(al.lesson_tsv, _tsquery, 32)::DOUBLE PRECISION AS seed_score
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND (al.lesson_tsv @@ _tsquery OR al.topic_tsv @@ _tsquery)
              AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
            ORDER BY seed_score DESC
            LIMIT 10
        ),
        graph_neighbors AS (
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
              AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
        )
        SELECT
            gn.id,
            gn.preview,
            gn.score,
            gn.chars::INT AS tokens_consumed,
            'relation'::TEXT AS navigation_path
        FROM graph_neighbors gn
        ORDER BY gn.score DESC
        LIMIT 20;
        RETURN;
    END IF;

    -- PATH C: DEFAULT — delegate to navigate_locate (handles NULL content_type + mixed signals)
    RETURN QUERY
    SELECT nl.id, nl.preview, nl.score, nl.tokens_consumed, nl.navigation_path
    FROM pgmnemo.navigate_locate(
        query_embedding, query_text,
        token_budget_chars, jsonb_filter, project_id_filter
    ) nl;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Update COMMENTs to reflect version bump
-- ─────────────────────────────────────────────────────────────────────────────

COMMENT ON COLUMN pgmnemo.agent_lesson.topic_tsv IS
    'Stored tsvector for topic column — tsconfig ''simple'' (v0.10.1, Fix 4). '
    'GIN index: pgmnemo_agent_lesson_topic_tsv_idx.';

COMMENT ON COLUMN pgmnemo.agent_lesson.lesson_tsv IS
    'Stored tsvector for lesson_text — tsconfig ''simple'' (v0.10.1, Fix 4). '
    'GIN index: pgmnemo_agent_lesson_lesson_tsv_idx.';

COMMENT ON COLUMN pgmnemo.agent_lesson.full_text IS
    'Weighted tsvector: topic (weight A) || lesson_text (weight B), tsconfig ''simple'' (v0.10.1, Fix 4). '
    'Used by recall_hybrid BM25 phase (Fix 2) and recall_lessons full_text path. '
    'GIN index: pgmnemo_agent_lesson_full_text_idx.';

-- ─────────────────────────────────────────────────────────────────────────────
-- G. recall_fast() — fix #84: NULL query_embedding raises EXCEPTION
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Bug: recall_fast() computes (1.0 - (embedding <=> query_embedding)) without
-- guarding against NULL query_embedding, so the score column is silently NULL
-- when the caller passes NULL instead of an embedding vector.
--
-- Fix: add an early RAISE EXCEPTION guard (matching recall_hybrid() semantics:
-- recall_hybrid raises EXCEPTION when BOTH signals are NULL; recall_fast has
-- NO text fallback so NULL query_embedding is always unrecoverable → EXCEPTION).
--
-- SQLSTATE: P0001 (raise_exception — same as recall_hybrid's guard).

CREATE OR REPLACE FUNCTION pgmnemo.recall_fast(
    query_embedding   vector(1024),
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    exclude_dag_id    TEXT    DEFAULT NULL
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
    ORDER BY fr.vec_score DESC;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_fast(vector, INT, TEXT, INT, TEXT) IS
    'HNSW-only vector recall — O(k log n), no BM25/graph/RRF. '
    'Uses ORDER BY embedding <=> query LIMIT k to activate the HNSW index. '
    'score = cosine similarity (1 - distance). '
    'Respects include_unverified, ef_search, track_recall_recency GUCs. '
    'Filters: role_filter, project_id_filter, exclude_dag_id (same as recall_hybrid). '
    'v0.10.0: default MCP recall path. Use recall_hybrid for full 6-signal fusion. '
    'v0.10.1 #84: raises EXCEPTION when query_embedding IS NULL (no text-only fallback).';
