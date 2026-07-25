-- pgmnemo--0.14.0--0.14.1.sql
-- Upgrade: 0.14.0 → 0.14.1 — fix recall_hybrid() HNSW planner regression
-- SPDX-License-Identifier: Apache-2.0
--
-- Root cause: recall_hybrid() embedded the vector-candidate fetch inside a
-- WITH RECURSIVE CTE whose LIMIT clause was a plpgsql local variable
-- (_fetch_k_vec = GREATEST(k*4, ef_search)).  PostgreSQL generates a
-- parameter-blind generic plan for plpgsql RETURN QUERY statements; without
-- a concrete LIMIT value at planning time, the cost model does not recognise
-- the small top-k pattern and falls back to Seq Scan + top-N heapsort instead
-- of the HNSW index scan.  On a 7440-lesson corpus this causes p50 ≈ 114 ms
-- (vs 11 ms for the hand-rolled 2-phase path) and p95 outliers of 22–30 s.
--
-- Fix (split the vector fetch so it is planned independently):
--   • The vector-candidate SELECT is issued via EXECUTE format(…, _fetch_k_vec)
--     so that LIMIT appears as a literal integer in the SQL text; the planner
--     then sees the concrete value and reliably picks the HNSW index scan.
--   • Results are written into a per-transaction temp table _pgmnemo_vc
--     (ON COMMIT DROP) instead of a CTE; all downstream CTEs are unchanged.
--   • WITH RECURSIVE is retained: graph_walk remains self-referential.
--   • BM25 path (temp table _pgmnemo_bm25_work) and all GUC handling are
--     identical to 0.14.0 — this is a pure planner fix, not a scoring change.

-- ─────────────────────────────────────────────────────────────────────────────
-- Drop old 11-param signature before replacing.
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS pgmnemo.recall_hybrid(
    vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[], REAL
);

-- ─────────────────────────────────────────────────────────────────────────────
-- recall_hybrid() v0.14.1 — HNSW planner regression fix
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
            0.2)));
    EXCEPTION WHEN OTHERS THEN _graph_weight := 0.2;
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
            LIMIT %s                        -- ← literal value: planner sees k*4 or ef_search
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
        FROM _pgmnemo_vc v                            -- ← temp table (was: vec_candidates CTE)
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
        WHERE bw.id NOT IN (SELECT id FROM _pgmnemo_vc)  -- ← temp table
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
    ),
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
    'v0.14.1 — HNSW planner regression fix. Vector candidates now fetched via '
    'EXECUTE with a literal LIMIT so the planner always sees the concrete value '
    'and chooses the HNSW index scan instead of Seq Scan + top-N heapsort. '
    'Confirmed on 3000–7440 row corpus: HNSW cost 448 vs SeqScan 413 in generic plan; '
    'literal LIMIT restores HNSW selection. Scoring, RRF, and recency stamp unchanged. '
    'v0.13.0 — Outcome Loop v2: adds p_min_score REAL DEFAULT NULL (11th param). '
    'p_min_score: filter rows where match_confidence (= vec_score clamped to [0,1]) < p_min_score. '
    'NULL = no filter (backward-compatible). Ghost-lesson NOTICE fires only when p_min_score IS NULL. '
    'Inherits v0.11.0 (RFC-001 §D2 / P0.2: typed recall) and v0.10.1 (#87) fixes: '
    'query_text cap, indexed full_text BM25, bm25_budget_ms timeout, simple tsconfig. '
    'match_confidence: vec_score (cosine similarity, [0,1]). '
    'RRF fusion is sparse-safe per Cormack 2009: unmatched candidates rank n_candidates+1. '
    'graph_proximity via mem_edge causal/temporal walk (depth ≤5). '
    'VOLATILE (side-effects: recency stamp, temp tables _pgmnemo_bm25_work, _pgmnemo_vc).';

-- =============================================================================
-- P1-2  classify_content_type() — remove bare \mbugfix\M incident trigger
-- =============================================================================
-- Root cause: the pattern OR p_text ~* '\mbugfix\M' fires on ordinary process
-- text like "When submitting a bugfix PR, always …" which should be 'procedure'.
-- Fix: drop the bare \mbugfix\M arm.  Genuine bugfix incidents are still caught
-- by the remaining arms (root.?cause, postmortem, outage, incident, regression,
-- rollback, hotfix, stacktrace, failure+causation pattern).
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.classify_content_type(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $func$
    SELECT CASE

        -- ── INCIDENT (highest priority) ────────────────────────────────────
        WHEN p_text ~* '\m(root.?cause|postmortem|outage|incident|hotfix|regression|rollback|revert)\M'
          OR p_text ~* '\m(stacktrace|traceback|segfault|oom.?kill)\M'
          OR (p_text ~* '\m(crashed?|broken|corrupted?|panicked?|failed)\M'
              AND p_text ~* '\m(caused|because of|due to|led to|resulted?|triggered?)\M')
          OR p_text ~* '\mthe (bug|error|issue|failure) (was|is)\M'
          -- NOTE: \mbugfix\M removed in v0.14.1 — caused false-positives on process
          -- text like "When submitting a bugfix PR, always …" (should be 'procedure').
          -- Genuine bugfix incidents still fire via root.?cause / postmortem / outage /
          -- regression / hotfix or the failure+causation compound above.
        THEN 'incident'

        -- ── DECISION ────────────────────────────────────────────────────────
        WHEN p_text ~* '\mADR[-\s]?\d'
          OR p_text ~* '\m(decided|decision|verdict|approved|rejected|chosen)\M'
          OR p_text ~* 'we (chose|selected|adopted|agreed|preferred?|decided)\M'
          OR (p_text ~* '\m(chose|selected|adopted)\M'
              AND p_text ~* '\m(instead|over|rather than|in favor of)\M')
        THEN 'decision'

        -- ── ENTITY ──────────────────────────────────────────────────────────
        WHEN p_text ~* '\mis (?:a|the)(?:\s+\w+){0,2}\s+(?:service|tool|library|module|package|repo|repository|component|system|project)\M'
          OR p_text ~* '\mis (?:the)(?:\s+\w+){0,1}\s+(?:lead|owner|author|contact|maintainer|engineer|manager|architect|operator|po)\M'
          OR p_text ~* '\m(owns?|maintains?|is responsible for)\M'
        THEN 'entity'

        -- ── FACT ────────────────────────────────────────────────────────────
        WHEN (   p_text ~* '\m(defaults? to|default (value |port |behavior )?is)\M'
              OR p_text ~* '\malways returns?\M'
              OR p_text ~* '\m(is always|is set to|is stored in|is fixed at|is never)\M'
              OR p_text ~* '\mversion (is|was)\M'
              OR p_text ~* '\m(schema|table|column|port|endpoint) (is|has|was|uses?|contains?)\M'
             )
          AND p_text !~* '\mwhen\M'
          AND p_text !~* '\m(run|install|deploy|configure|restart|use)\M'
        THEN 'fact'

        -- ── PROCEDURE (catch-all) ────────────────────────────────────────────
        WHEN p_text ~* '\mwhen\M'
          OR p_text ~* '\m(must|should|always|never|avoid|prefer|recommend)\M'
          OR p_text ~* '\m(run|execute|install|deploy|configure|restart|use)\M'
          OR p_text ~* '\m(command|script|workflow|pattern|approach|method)\M'
          OR p_text ~* '\mhow to\M'
        THEN 'procedure'

        ELSE NULL
    END
$func$;

COMMENT ON FUNCTION pgmnemo.classify_content_type(text) IS
    'Deterministic keyword/regex content-type classifier (v0.14.1). No LLM. '
    'Returns: procedure | incident | decision | fact | entity | NULL. '
    'Priority: incident > decision > entity > fact > procedure > NULL. '
    'IMMUTABLE + STRICT: NULL input → NULL output; result is purely a function of the text. '
    'v0.14.1: removed bare \mbugfix\M arm — caused false-positives on process text. '
    'Used by ingest() auto-fill and reclassify_corpus().';

-- =============================================================================
-- P1-4  consolidate() — deterministic canonical election (id ASC tiebreaker)
-- =============================================================================
-- Root cause: array_agg(... ORDER BY recall_count DESC, confidence DESC,
--   importance DESC, created_at ASC) is non-deterministic when candidates share
--   identical values for all four columns (common with bulk-ingested lessons).
-- Fix: append c.id ASC as the final ORDER BY key — lower id always wins on a tie.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.consolidate(
    p_similarity REAL    DEFAULT 0.92,
    p_dry_run    BOOLEAN DEFAULT TRUE,
    p_role       TEXT    DEFAULT NULL,
    p_limit      INT     DEFAULT 100
)
RETURNS TABLE (
    canonical_id    BIGINT,
    member_ids      BIGINT[],
    size            INT,
    mean_similarity REAL
)
LANGUAGE plpgsql
AS $$
DECLARE
    _pair     RECORD;
    _cluster  RECORD;
    _root_a   BIGINT;
    _root_b   BIGINT;
    _new_root BIGINT;
    _old_root BIGINT;
    _mbr      BIGINT;
BEGIN
    DROP TABLE IF EXISTS _con_candidates;
    DROP TABLE IF EXISTS _con_pairs;
    DROP TABLE IF EXISTS _con_uf;
    DROP TABLE IF EXISTS _con_clusters;

    -- ── 1. Candidate pool ─────────────────────────────────────────────────
    CREATE TEMP TABLE _con_candidates ON COMMIT DROP AS
    SELECT id, role, recall_count, confidence, importance, created_at, embedding
    FROM pgmnemo.agent_lesson
    WHERE is_active
      AND state NOT IN ('superseded', 'archived', 'rejected')
      AND embedding IS NOT NULL
      AND (p_role IS NULL OR role = p_role)
    ORDER BY recall_count DESC, confidence DESC, importance DESC, created_at ASC
    LIMIT p_limit * 20;

    -- ── 2. All-pairs cosine similarity above threshold ────────────────────
    CREATE TEMP TABLE _con_pairs ON COMMIT DROP AS
    SELECT
        a.id                                         AS id_a,
        b.id                                         AS id_b,
        (1.0 - (a.embedding <=> b.embedding))::REAL  AS sim
    FROM _con_candidates a
    JOIN _con_candidates b ON b.id > a.id
                          AND a.role = b.role
    WHERE (1.0 - (a.embedding <=> b.embedding)) >= p_similarity;

    -- ── 3. Union-Find: initialise each paired node as its own root ────────
    CREATE TEMP TABLE _con_uf (id BIGINT PRIMARY KEY, root BIGINT NOT NULL)
    ON COMMIT DROP;

    INSERT INTO _con_uf (id, root)
    SELECT DISTINCT id_a, id_a FROM _con_pairs
    UNION
    SELECT DISTINCT id_b, id_b FROM _con_pairs;

    -- ── 4. Union-Find: unite connected components ─────────────────────────
    FOR _pair IN SELECT id_a, id_b FROM _con_pairs LOOP
        SELECT root INTO _root_a FROM _con_uf WHERE id = _pair.id_a;
        SELECT root INTO _root_b FROM _con_uf WHERE id = _pair.id_b;
        IF _root_a IS DISTINCT FROM _root_b THEN
            _new_root := LEAST(_root_a, _root_b);
            _old_root := GREATEST(_root_a, _root_b);
            UPDATE _con_uf SET root = _new_root WHERE root = _old_root;
        END IF;
    END LOOP;

    -- ── 5. Path compression ───────────────────────────────────────────────
    LOOP
        UPDATE _con_uf u
        SET root = p.root
        FROM _con_uf p
        WHERE p.id = u.root AND p.root <> u.root;
        EXIT WHEN NOT FOUND;
    END LOOP;

    -- ── 6. Materialise cluster results ────────────────────────────────────
    -- Canonical = members[1].  ORDER BY: recall_count DESC, confidence DESC,
    -- importance DESC, created_at ASC, id ASC (stable tiebreaker — P1-4 fix).
    CREATE TEMP TABLE _con_clusters ON COMMIT DROP AS
    WITH cluster_agg AS (
        SELECT
            u.root,
            array_agg(u.id ORDER BY
                c.recall_count DESC,
                c.confidence   DESC,
                c.importance   DESC,
                c.created_at   ASC,
                c.id           ASC   -- stable tiebreaker: lowest id wins on tie
            )            AS members,
            count(*)::INT AS sz
        FROM _con_uf u
        JOIN _con_candidates c ON c.id = u.id
        GROUP BY u.root
        HAVING count(*) > 1
    ),
    cluster_sim AS (
        SELECT
            ca.root,
            ca.members,
            ca.sz,
            (SELECT avg(p.sim)::REAL
             FROM _con_pairs p
             WHERE p.id_a = ANY(ca.members)
               AND p.id_b = ANY(ca.members)
            ) AS mean_sim
        FROM cluster_agg ca
    )
    SELECT
        members[1]                       AS canonical_id,
        members                          AS all_members,
        sz,
        coalesce(mean_sim, p_similarity) AS mean_sim
    FROM cluster_sim
    ORDER BY sz DESC, members[1]
    LIMIT p_limit;

    -- ── 7. Apply (p_dry_run=FALSE only) ──────────────────────────────────
    IF NOT p_dry_run THEN
        FOR _cluster IN SELECT * FROM _con_clusters LOOP

            UPDATE pgmnemo.agent_lesson
            SET evidence_count = _cluster.sz
            WHERE id = _cluster.canonical_id;

            FOREACH _mbr IN ARRAY _cluster.all_members LOOP
                CONTINUE WHEN _mbr = _cluster.canonical_id;

                UPDATE pgmnemo.agent_lesson
                SET state            = 'superseded',
                    is_active        = FALSE,
                    state_changed_at = NOW()
                WHERE id = _mbr;

                PERFORM pgmnemo.add_edge(
                    _mbr,
                    _cluster.canonical_id,
                    'SUPERSEDED_BY',
                    _cluster.mean_sim::FLOAT8,
                    jsonb_build_object(
                        'consolidation', TRUE,
                        'cluster_size',  _cluster.sz
                    ),
                    'max'
                );
            END LOOP;
        END LOOP;
    END IF;

    -- ── 8. Return cluster summary ─────────────────────────────────────────
    RETURN QUERY
    SELECT c.canonical_id, c.all_members, c.sz, c.mean_sim
    FROM _con_clusters c
    ORDER BY c.sz DESC, c.canonical_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.consolidate(REAL, BOOLEAN, TEXT, INT) IS
    'Cluster near-duplicate ACTIVE lessons by cosine similarity and collapse them. '
    'p_similarity REAL DEFAULT 0.92: cosine similarity threshold for grouping. '
    'p_dry_run BOOLEAN DEFAULT TRUE: when TRUE, return proposed clusters without any writes. '
    'p_role TEXT DEFAULT NULL: restrict to a single role (NULL = all roles). '
    'p_limit INT DEFAULT 100: max clusters to return / process per call. '
    'Returns: (canonical_id BIGINT, member_ids BIGINT[], size INT, mean_similarity REAL). '
    'Algorithm: union-find over all-pairs cosine similarity within each role. '
    'Canonical election: recall_count DESC, confidence DESC, importance DESC, '
    'created_at ASC, id ASC (stable tiebreaker — P1-4 v0.14.1 fix). '
    'Apply (p_dry_run=FALSE): canonical.evidence_count=cluster_size; '
    'non-canonical members: state=superseded, is_active=FALSE, state_changed_at=NOW(); '
    'SUPERSEDED_BY edge (semantic) via add_edge() from each member to canonical. '
    'All writes in the caller''s transaction — roll back on error. '
    'Guards: never self-supersedes; never collapses across different roles. '
    'Added in v0.14.0; tiebreaker fix in v0.14.1.';
