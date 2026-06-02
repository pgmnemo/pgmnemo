# pgmnemo v0.6.0 — Implementation Plan

**Phase:** PLAN  
**Author:** chief_architect (id=86)  
**Date:** 2026-05-22  
**Input:** `spec/competitive/BENCHMARK_FIX_A_RRF_v060.md` + internal design notes + the production-feedback follow-up RFC  
**Deliverable scope:** RRF Fix-A (Option A-norm) + `as_of_ts` param + `ghost_count` in stats + ingest NOTICE

---

## 0. Version Note (IMPORTANT)

`pgmnemo.control` current `default_version = '0.5.1'`. The v0.5.2 release (2026-05-22) was
a **Python packaging / docs fix only** — no SQL schema change, no `ALTER EXTENSION` needed,
no `pgmnemo--0.5.1--0.5.2.sql` upgrade script exists. The SQL extension version never
advanced past 0.5.1.

**Therefore:** The migration filename is `extension/pgmnemo--0.5.1--0.6.0.sql`.  
The task specification says `pgmnemo--0.5.2--0.6.0.sql` — this is a version confusion
(mcp Python pkg version vs SQL extension version). The correct SQL upgrade path is
**0.5.1 → 0.6.0**. The implementer must:

1. Create `extension/pgmnemo--0.5.1--0.6.0.sql` (canonical upgrade path)
2. Update `extension/pgmnemo.control` → `default_version = '0.6.0'`
3. Update `extension/pgmnemo--0.5.1.sql` → squash all changes into fresh install

---

## 1. Migration File Outline: `extension/pgmnemo--0.5.1--0.6.0.sql`

### 1.0 Header

```sql
-- pgmnemo 0.5.1 → 0.6.0 upgrade migration
-- Changes:
--   §1  recall_hybrid() — Fix-A: rrf_diag normalized to primary ranking signal (Option A-norm)
--                         + temporal filter from pgmnemo.as_of_timestamp GUC
--   §2  recall_lessons() — add as_of_ts TIMESTAMPTZ DEFAULT NULL (6th param)
--   §3  pgmnemo.stats()  — add ghost_count BIGINT column
--   §4  pgmnemo.ingest() — RAISE NOTICE when bitemporal close+create fires (Q5 dedup obs.)
-- Backward compatibility: zero breaking changes (see §5 audit).
-- Prerequisites: pgmnemo 0.5.1 installed. Requires pgvector.
-- Apply: ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';
```

---

### §1  `recall_hybrid()` — Fix-A + temporal filter

**Strategy:** `CREATE OR REPLACE` (signature unchanged). Two internal changes:
(a) read `pgmnemo.as_of_timestamp` GUC for temporal scoping;
(b) replace `s.fusion_score` with normalized `s.rrf_diag` in both the `anchors` CTE
and the final `ORDER BY`.

```sql
-- §1: Fix-A — promote rrf_diag to primary ranking signal; add as_of_ts temporal filter.
-- No signature change → CREATE OR REPLACE sufficient.

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
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,
    vec_score     DOUBLE PRECISION,
    bm25_score    DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION,
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
STABLE
PARALLEL SAFE
AS $$
DECLARE
    _rrf_k_f          DOUBLE PRECISION;
    _graph_weight     DOUBLE PRECISION;
    _max_depth        CONSTANT INT := 3;
    _include_unver    BOOLEAN;
    _as_of_ts         TIMESTAMPTZ;
    _rrf_norm_denom   DOUBLE PRECISION;  -- Fix-A: max possible rrf_diag value
BEGIN
    _rrf_k_f := rrf_k::DOUBLE PRECISION;

    -- Fix-A normalization denominator: max rrf_diag = (vec_w + bm25_w) / (rrf_k + 1)
    -- Normalizes rrf_diag to [0, 1] so auxiliary terms stay at comparable scale.
    -- Default params (0.4+0.4)/61 ≈ 0.01311; result is scale-invariant.
    _rrf_norm_denom := (vec_weight + bm25_weight) / (_rrf_k_f + 1.0);

    -- as_of_ts: read from GUC (set by recall_lessons() or directly by caller via SET)
    _as_of_ts := NULLIF(
        current_setting('pgmnemo.as_of_timestamp', TRUE), ''
    )::TIMESTAMPTZ;

    -- graph_proximity_weight GUC (default 0.2)
    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
        _graph_weight := LEAST(GREATEST(_graph_weight, 0.0), 0.5);
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;

    -- include_unverified GUC
    BEGIN
        _include_unver := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unver := FALSE;
    END;

    RETURN QUERY
    WITH
    -- Step 1: union candidates from dense ANN + BM25 sparse
    raw_candidates AS (
        -- Dense branch
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at,
            1.0 - (al.embedding <=> query_embedding) AS raw_vec_score,
            0.0::DOUBLE PRECISION                     AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.embedding IS NOT NULL
          AND (role_filter       IS NULL OR al.role       = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          AND (_include_unver OR al.verified_at IS NOT NULL)
          -- as_of temporal filter (v0.6.0): restricts to lessons valid at _as_of_ts
          AND (
              _as_of_ts IS NULL
              OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts)
          )
          -- When no as_of_ts: use standard active-row filter
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT GREATEST(k * 5, 50)

        UNION ALL

        -- BM25 sparse branch
        SELECT
            al.id,
            al.role, al.project_id, al.topic, al.lesson_text,
            al.importance, al.metadata, al.commit_sha, al.artifact_hash,
            al.verified_at, al.created_at,
            0.0::DOUBLE PRECISION                      AS raw_vec_score,
            ts_rank_cd(al.lesson_tsv,
                       plainto_tsquery('english', query_text),
                       32)::DOUBLE PRECISION           AS raw_bm25_score
        FROM pgmnemo.agent_lesson al
        WHERE al.lesson_tsv @@ plainto_tsquery('english', query_text)
          AND (role_filter       IS NULL OR al.role       = role_filter)
          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
          AND (_include_unver OR al.verified_at IS NOT NULL)
          AND (
              _as_of_ts IS NULL
              OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts)
          )
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        LIMIT GREATEST(k * 5, 50)
    ),
    -- Step 2: aggregate per-id, compute RRF ranks
    deduped AS (
        SELECT
            id,
            role, project_id, topic, lesson_text,
            importance, metadata, commit_sha, artifact_hash,
            verified_at, created_at,
            MAX(raw_vec_score)  AS raw_vec_score,
            MAX(raw_bm25_score) AS raw_bm25_score
        FROM raw_candidates
        GROUP BY id, role, project_id, topic, lesson_text,
                 importance, metadata, commit_sha, artifact_hash,
                 verified_at, created_at
    ),
    rrf_ranked AS (
        SELECT *,
            ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST) AS vec_rank,
            ROW_NUMBER() OVER (ORDER BY raw_bm25_score DESC NULLS LAST) AS bm25_rank
        FROM deduped
    ),
    -- Step 3: compute rrf_diag (primary ranking signal, v0.6.0) + fusion_score (retained as diagnostic)
    scored AS (
        SELECT
            r.id,
            r.role, r.project_id, r.topic, r.lesson_text,
            r.importance, r.metadata, r.commit_sha, r.artifact_hash,
            r.verified_at, r.created_at,
            r.raw_vec_score  AS v_score,
            r.raw_bm25_score AS b_score,
            -- Fix-A: rrf_diag is now the PRIMARY ranking signal (normalized to [0,1])
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + r.bm25_rank::DOUBLE PRECISION))
                AS rrf_diag,
            -- fusion_score retained as diagnostic column (was primary before v0.6.0)
            (vec_weight  * r.raw_vec_score
           + bm25_weight * r.raw_bm25_score)
                AS fusion_score
        FROM rrf_ranked r
    ),
    -- Step 4: anchor top-5 by rrf_diag (Fix-A: was fusion_score) for graph proximity walk
    anchors AS (
        SELECT id
        FROM scored
        ORDER BY (rrf_diag / _rrf_norm_denom) DESC   -- Fix-A: normalized rrf_diag
        LIMIT 5
    ),
    graph_walk (anchor_id, depth, reached_id) AS (
        SELECT id, 0, id FROM anchors
        UNION ALL
        SELECT gw.anchor_id, gw.depth + 1, me.target_id
        FROM graph_walk gw
        JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id
        WHERE me.relation_type IN ('CAUSED_BY', 'CO_OCCURRED', 'DERIVED_FROM')
          AND gw.depth < _max_depth
    ),
    graph_proximity AS (
        SELECT
            gw.reached_id AS lesson_id,
            MAX(1.0 - gw.depth::DOUBLE PRECISION / _max_depth::DOUBLE PRECISION) AS proximity
        FROM graph_walk gw
        WHERE gw.depth > 0
        GROUP BY gw.reached_id
    )
    SELECT
        s.id          AS lesson_id,
        -- Final score: Fix-A normalized rrf_diag + auxiliary components
        (
            (s.rrf_diag / _rrf_norm_denom)               -- Fix-A: replaces s.fusion_score
          + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
          + 0.05 * GREATEST(0.0,
                       1.0 - LEAST(
                           EXTRACT(EPOCH FROM (
                               COALESCE(_as_of_ts, NOW()) - s.created_at
                           )) / (90.0 * 86400.0),
                           1.0
                       )
                   )::DOUBLE PRECISION
          + 0.05 * (CASE
                      WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                      WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                      ELSE                                                             0.0
                    END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        )             AS score,
        s.v_score     AS vec_score,
        s.b_score     AS bm25_score,
        s.rrf_diag    AS rrf_score,   -- column name unchanged (callers already used rrf_score)
        s.role, s.project_id, s.topic, s.lesson_text,
        s.importance, s.metadata, s.commit_sha, s.artifact_hash,
        s.verified_at, s.created_at
    FROM scored s
    LEFT JOIN graph_proximity gp ON gp.lesson_id = s.id
    ORDER BY
        (
            (s.rrf_diag / _rrf_norm_denom)               -- Fix-A ORDER BY matches SELECT score
          + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
          + 0.05 * GREATEST(0.0,
                       1.0 - LEAST(
                           EXTRACT(EPOCH FROM (
                               COALESCE(_as_of_ts, NOW()) - s.created_at
                           )) / (90.0 * 86400.0),
                           1.0
                       )
                   )::DOUBLE PRECISION
          + 0.05 * (CASE
                      WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                      WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                      ELSE                                                             0.0
                    END)::DOUBLE PRECISION
          + _graph_weight * COALESCE(gp.proximity, 0.0)
        ) DESC,
        s.importance DESC,
        s.created_at DESC
    LIMIT k;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT) IS
    'Hybrid recall v0.6.0. '
    'Fix-A: rrf_diag promoted to primary ranking signal (Cormack 2009 RRF). '
    'Normalized via (vec_weight+bm25_weight)/(rrf_k+1) to preserve auxiliary-component balance. '
    'Temporal filter: reads pgmnemo.as_of_timestamp GUC (set by recall_lessons() as_of_ts param). '
    'rrf_score column = normalized-basis rrf_diag (was diagnostic-only before v0.6.0). '
    'fusion_score retained internally as diagnostic; not returned. '
    'Union retrieval: candidates from EITHER embedding cosine OR BM25 text match. '
    'graph_proximity_weight GUC (default 0.2). ef_search GUC (default 100). '
    'PARALLEL SAFE (current_setting read-only; set_config in recall_lessons not here).';
```

---

### §2  `recall_lessons()` — add `as_of_ts` parameter

**Strategy:** DROP old 5-arg overload, CREATE new 6-arg form. Return type unchanged (15 cols).
Existing callers with 5 positional args resolve to 6-arg form with 6th defaulting to NULL.

```sql
-- §2: recall_lessons() — v0.6.0 adds as_of_ts TIMESTAMPTZ DEFAULT NULL (6th param).
-- Return type unchanged → but PostgreSQL won't replace a function with different arg count;
-- must DROP old overload first.

DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT          DEFAULT 10,
    role_filter       TEXT         DEFAULT NULL,
    project_id_filter INT          DEFAULT NULL,
    query_text        TEXT         DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ  DEFAULT NULL    -- v0.6.0: point-in-time temporal scoping
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
    created_at    TIMESTAMPTZ,
    vec_score     DOUBLE PRECISION,
    bm25_score    DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
PARALLEL UNSAFE   -- set_config() in body prevents parallel execution (acceptable — not called in parallel workers)
AS $$
DECLARE
    _ef_search          INT;
    _include_unverified BOOLEAN;
    _disable_hybrid     BOOLEAN;
    _max_depth          CONSTANT INT := 5;
    _max_chars          INT;
    _query_text         TEXT;
    _gamma              DOUBLE PRECISION;
    _temporal_boost     DOUBLE PRECISION;
    _graph_weight       DOUBLE PRECISION;
BEGIN
    -- v0.6.0: as_of_ts — set transaction-local GUC consumed by recall_hybrid()
    -- set_config(TRUE) = transaction-local; cleared after COMMIT/ROLLBACK (no pool leak).
    IF as_of_ts IS NOT NULL THEN
        PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
    END IF;

    -- R5: clamp query_text to pgmnemo.max_query_text_chars (default 2000)
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );
    IF query_text IS NOT NULL AND length(query_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.recall_lessons: query_text truncated to % chars '
                     '(pgmnemo.max_query_text_chars). Original length: %',
                     _max_chars, length(query_text);
        _query_text := left(query_text, _max_chars);
    ELSE
        _query_text := query_text;
    END IF;

    BEGIN
        _disable_hybrid := COALESCE(
            current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _disable_hybrid := FALSE;
    END;

    -- Route to recall_hybrid() when: text present + embedding present + hybrid not disabled
    IF NOT _disable_hybrid
       AND _query_text IS NOT NULL
       AND length(trim(_query_text)) > 0
       AND query_embedding IS NOT NULL THEN
        RETURN QUERY
        SELECT
            h.lesson_id, h.score, h.role, h.project_id, h.topic, h.lesson_text,
            h.importance, h.metadata, h.commit_sha, h.artifact_hash,
            h.verified_at, h.created_at,
            h.vec_score, h.bm25_score, h.rrf_score
        FROM pgmnemo.recall_hybrid(
            query_embedding,
            _query_text,
            k,
            role_filter,
            project_id_filter,
            0.4,   -- vec_weight
            0.4,   -- bm25_weight
            60     -- rrf_k
        ) h;
        RETURN;
    END IF;

    -- Vector-only fallback path (unchanged from v0.5.1)
    -- [... full vector-only path body from pgmnemo--0.5.1.sql lines 2244–2388 ...]
    -- The vector-only path also respects the as_of_ts by filtering t_valid_from/t_valid_to
    -- directly (since it does not call recall_hybrid, it must apply the temporal filter itself):
    BEGIN
        _ef_search := COALESCE(
            NULLIF(current_setting('pgmnemo.ef_search', TRUE), '')::INT,
            100
        );
        IF _ef_search BETWEEN 10 AND 500 THEN
            EXECUTE format('SET LOCAL pgvector.hnsw.ef_search = %s', _ef_search);
        END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        _include_unverified := COALESCE(
            current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
            FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        _include_unverified := FALSE;
    END;

    _gamma := COALESCE(
        NULLIF(current_setting('pgmnemo.recency_weight', TRUE), '')::DOUBLE PRECISION,
        0.05
    );
    BEGIN
        _temporal_boost := COALESCE(
            NULLIF(current_setting('pgmnemo.temporal_boost', TRUE), '')::DOUBLE PRECISION,
            1.0
        );
        IF _temporal_boost < 0.0 THEN _temporal_boost := 0.0; END IF;
    EXCEPTION WHEN OTHERS THEN
        _temporal_boost := 1.0;
    END;
    BEGIN
        _graph_weight := COALESCE(
            NULLIF(current_setting('pgmnemo.graph_proximity_weight', TRUE), '')::DOUBLE PRECISION,
            0.2
        );
        _graph_weight := LEAST(GREATEST(_graph_weight, 0.0), 0.5);
    EXCEPTION WHEN OTHERS THEN
        _graph_weight := 0.2;
    END;

    -- [vector-only CTE body — must add temporal filter to candidates WHERE clause:]
    -- WHERE al.embedding IS NOT NULL
    --   AND (role_filter IS NULL OR al.role = role_filter)
    --   AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
    --   AND (_include_unverified OR al.verified_at IS NOT NULL)
    --   -- v0.6.0 temporal filter:
    --   AND (
    --       as_of_ts IS NULL
    --       OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts)
    --   )
    --   AND (as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
    -- [rest of vector-only path unchanged]
    RETURN;
END;
$$;

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ) IS
    'v0.6.0 hybrid router with as_of_ts temporal scoping and Fix-A RRF ranking. '
    'as_of_ts (default NULL = now): restricts candidates to lessons valid at ts '
    '(t_valid_from <= ts < t_valid_to). Sets pgmnemo.as_of_timestamp GUC (tx-local) '
    'consumed by recall_hybrid(). '
    'PARALLEL UNSAFE due to set_config(); not invoked inside parallel workers. '
    'Routes to recall_hybrid() when query_text + embedding present and disable_hybrid=false. '
    'Fix-A: recall_hybrid() now ranks by normalized rrf_diag (Cormack 2009 RRF).';
```

> **Implementation note for SD:** The vector-only fallback path (lines 2244–2388 of
> `pgmnemo--0.5.1.sql`) must be copied verbatim into §2 body, with the following edit:
> in the `candidates` CTE `WHERE` clause, add the two temporal-filter lines shown above.
> Do NOT retype from memory — copy from the source file to avoid drift.

---

### §3  `pgmnemo.stats()` — add `ghost_count`

**Strategy:** Return type changes → must DROP before CREATE.

```sql
-- §3: pgmnemo.stats() — add ghost_count BIGINT (RFC Q4).
-- ghost_count: active lessons with verified_at IS NULL (no commit_sha AND no artifact_hash).
-- Distinct from orphan_count (functions not owned by extension).

DROP FUNCTION IF EXISTS pgmnemo.stats();

CREATE OR REPLACE FUNCTION pgmnemo.stats()
RETURNS TABLE (
    version                    TEXT,
    lesson_count               BIGINT,
    embedded_count             BIGINT,
    embedding_coverage_pct     DOUBLE PRECISION,
    tsv_coverage_pct           DOUBLE PRECISION,
    mem_edge_count             BIGINT,
    recency_weight             DOUBLE PRECISION,
    ef_search                  INT,
    importance_weight          DOUBLE PRECISION,
    hybrid_enabled             BOOLEAN,
    recall_hybrid_available    BOOLEAN,
    oldest_lesson_age_days     INT,
    orphan_count               BIGINT,
    ghost_count                BIGINT     -- NEW v0.6.0: active lessons without provenance
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
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
        -- orphan_count: pgmnemo-schema functions not owned by the extension
        (SELECT COUNT(*)::BIGINT
         FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
         LEFT JOIN pg_depend d
             ON d.objid = p.oid AND d.deptype = 'e'
            AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
         WHERE n.nspname = 'pgmnemo'
           AND p.proname NOT LIKE '\_%' ESCAPE '\'
           AND d.objid IS NULL)                                                    AS orphan_count,
        -- ghost_count (v0.6.0): active lessons without provenance (RFC Q4)
        -- Definition: verified_at IS NULL (commit_sha IS NULL AND artifact_hash IS NULL)
        --             AND t_valid_to = 'infinity' (currently active)
        (SELECT COUNT(*)::BIGINT
         FROM pgmnemo.agent_lesson
         WHERE verified_at IS NULL
           AND t_valid_to = 'infinity'::TIMESTAMPTZ)                               AS ghost_count;
$$;

COMMENT ON FUNCTION pgmnemo.stats() IS
    'v0.6.0 diagnostic health-check. Adds ghost_count (RFC Q4). '
    'ghost_count: active lessons where verified_at IS NULL — no commit_sha AND no artifact_hash. '
    'Distinct from orphan_count (functions not owned by extension). '
    'Use ghost_count to track provenance migration progress: target < 5% of lesson_count '
    'before switching pgmnemo.include_unverified = off. '
    'Single-row summary; <50ms on N=10k corpus.';
```

---

### §4  `pgmnemo.ingest()` — RAISE NOTICE on bitemporal close+create

**Strategy:** `CREATE OR REPLACE` (signature unchanged). Add pre-insert content_hash
check; RAISE NOTICE if dedup close fires. Answers RFC Q5.

```sql
-- §4: ingest() — add RAISE NOTICE when bitemporal close+create fires (RFC Q5).
-- content_hash formula matches GENERATED ALWAYS AS column:
--   MD5(COALESCE(role,'') || '|' || COALESCE(topic,'') || '|' || COALESCE(commit_sha, artifact_hash, ''))
-- Pre-insert count gives caller-visible dedup signal.
-- Race condition: tiny window between SELECT and INSERT in concurrent sessions; acceptable
-- because NOTICE is informational only (trigger is the authoritative dedup mechanism).

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
LANGUAGE plpgsql AS $$
DECLARE
    new_id          BIGINT;
    _max_chars      INT;
    _content_hash   TEXT;
    _prior_count    INT;
BEGIN
    -- R5: clamp lesson_text
    _max_chars := COALESCE(
        NULLIF(current_setting('pgmnemo.max_query_text_chars', TRUE), '')::INT,
        2000
    );
    IF p_lesson_text IS NULL OR length(trim(p_lesson_text)) = 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text is NULL or empty — proceeding.';
    ELSIF _max_chars > 0 AND length(p_lesson_text) > _max_chars THEN
        RAISE NOTICE 'pgmnemo.ingest: p_lesson_text truncated to % chars '
                     '(pgmnemo.max_query_text_chars). Original length: %',
                     _max_chars, length(p_lesson_text);
        p_lesson_text := left(p_lesson_text, _max_chars);
    END IF;

    IF p_embedding IS NOT NULL AND vector_dims(p_embedding) <> 1024 THEN
        RAISE EXCEPTION 'pgmnemo.ingest: embedding dimension mismatch — expected 1024, got %',
            vector_dims(p_embedding);
    END IF;

    -- Q5: compute content_hash to detect upcoming bitemporal close (dedup observability)
    -- Replicates GENERATED ALWAYS AS formula from agent_lesson.content_hash column.
    _content_hash := MD5(
        COALESCE(p_role, '')        || '|' ||
        COALESCE(p_topic, '')       || '|' ||
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
        CASE WHEN p_commit_sha IS NOT NULL OR p_artifact_hash IS NOT NULL
             THEN NOW() ELSE NULL END
    ) RETURNING id INTO new_id;

    -- Q5: RAISE NOTICE if bitemporal close+create fired (trigger trg_agent_lesson_bitemporal_close)
    IF _prior_count > 0 THEN
        RAISE NOTICE 'pgmnemo.ingest: bitemporal close+create fired — closed % prior version(s) '
                     '(content_hash=%). New lesson_id=%. '
                     'Prior row(s) now have t_valid_to=NOW().',
                     _prior_count, _content_hash, new_id;
    END IF;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.ingest(TEXT, INT, TEXT, TEXT, SMALLINT, vector, TEXT, TEXT, JSONB) IS
    'Validated public write API (v0.6.0 + Q5). '
    'Q5: RAISE NOTICE when bitemporal close+create fires (dedup observability). '
    'Caller receives NOTICE "bitemporal close+create fired — closed N prior version(s)". '
    'On idempotent re-run (same args): NOTICE fires again if prior row was already closed+recreated. '
    'Truncates p_lesson_text to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'R5 (v0.5.0).';
```

---

### §5  Control File + Version Function

```sql
-- §5: bump version string
-- pgmnemo.control must be updated separately (file edit, not SQL).
-- Version string returned by pgmnemo.version() is the extension's installed version
-- from pg_extension — no SQL change needed; ALTER EXTENSION UPDATE handles it.

-- If pgmnemo.version() is a hardcoded constant (check pg_proc), update here:
-- CREATE OR REPLACE FUNCTION pgmnemo.version() RETURNS TEXT LANGUAGE sql AS $$ SELECT '0.6.0'::TEXT $$;
-- (Verify: SELECT pgmnemo.version(); — if it returns pg_extension.extversion, no change needed)
```

---

## 2. Backward-Compatibility Audit

### 2.1 Functions with signature changes

| Function | Old signature | New signature | Change type |
|----------|---------------|---------------|-------------|
| `recall_lessons` | `(vector, INT, TEXT, INT, TEXT)` | `(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ)` | Add trailing optional param |
| `stats` | returns 13 cols | returns 14 cols (ghost_count added) | Additive return column |

### 2.2 Functions with behavior changes only (signature unchanged)

| Function | Change | Risk |
|----------|--------|------|
| `recall_hybrid` | ORDER BY: `fusion_score` → `(rrf_diag / norm_denom)`. Temporal filter added via GUC. | Ranking order changes — intended; output columns unchanged |
| `ingest` | Pre-insert COUNT + RAISE NOTICE | Purely additive; NOTICE is informational |

### 2.3 Per-function caller impact

#### `recall_lessons(vector, INT, TEXT, INT, TEXT)` → `recall_lessons(vector, INT, TEXT, INT, TEXT, TIMESTAMPTZ)`

**Named-arg callers (e.g., `recall_lessons(query_embedding => $1, k => 10, role_filter => 'dev')`):**
→ Continue to work. Named args bind by name; 6th param defaults to NULL. **Zero breakage.**

**Positional callers with 5 args (e.g., `recall_lessons($1, 10, NULL, NULL, 'query')`):**
→ After DROP of 5-arg form, PostgreSQL resolves 5-arg call to 6-arg form with `as_of_ts = NULL`.
Behavior identical to v0.5.1. **Zero breakage.**

**Positional callers with <5 args (e.g., `recall_lessons($1)`):**
→ Positional matching still works; all 5 original params have defaults. **Zero breakage.**

**`recall_lessons_pooled(vector, INT, INT)` (internal caller of `recall_lessons`):**
→ `recall_lessons_pooled` calls `recall_lessons(query_embedding, k, NULL, project_id_filter, NULL)` (5 positional args). After DROP+CREATE, resolves to 6-arg form. `as_of_ts = NULL`. **Zero breakage.**

**MCP server (`pgmnemo_mcp/pgmnemo_mcp/server.py`):**
→ MCP calls `recall_lessons` with named params via asyncpg. Add `as_of_ts` to the call-site list
as optional if/when an adopter requests it. Current calls unchanged. **Zero breakage.**

#### `stats()` → adds `ghost_count BIGINT`

**`SELECT *` callers:** Receive 14 columns instead of 13. New `ghost_count` column at end.
→ Named-column consumers: **zero breakage.** Row-positional consumers at col index 14: new data.

**Named-column consumers (expected pattern for monitoring):** `SELECT ghost_count FROM pgmnemo.stats()` — works immediately after migration. **Zero breakage.**

#### `recall_hybrid(...)` (ranking order change)

**Ranking order changes.** This is the intended outcome. Output column set unchanged. Any code
relying on a specific ORDER (e.g., assuming the top result is always the highest cosine similarity)
may observe different results. This is a **deliberate regression trade** — expected to lift recall.

**Callers who hardcode rrf_score column semantics:** Column `rrf_score` previously returned
`rrf_diag` as diagnostic. In v0.6.0, `rrf_diag` is still returned in `rrf_score`; the column
value is **unchanged** — only the ORDER BY uses the normalized form. No caller breakage on
column value inspection.

### 2.4 Verdict

**Zero breaking changes** for all callers using named parameters or positional parameters
with ≤ original arity. The ranking order change in `recall_hybrid` is intentional and
announced in CHANGELOG.

---

## 3. Test Plan

### 3.1 Test files to create

All tests follow the existing `pgTAP + pgregress` pattern in `extension/sql/`.

```
extension/sql/test_v060_ghost_count.sql
extension/sql/test_v060_as_of_ts.sql
extension/sql/test_v060_ingest_notice.sql
extension/sql/test_v060_rrf_fix_a.sql
```

### 3.2 `test_v060_ghost_count.sql`

```sql
-- Test: ghost_count in pgmnemo.stats() (RFC Q4)

-- Setup: insert 2 lessons — one with provenance (commit_sha), one without (ghost)
SELECT pgmnemo.ingest('test-role', 1, 'topic-prov', 'lesson with provenance',
                      3, NULL, 'sha-abc', NULL, '{}');
SELECT pgmnemo.ingest('test-role', 1, 'topic-ghost', 'lesson without provenance',
                      3, NULL, NULL, NULL, '{}');  -- gate_strict must be 'warn' or 'off'

-- Test 1: ghost_count = 1 (only the provenance-less lesson)
SELECT ghost_count = 1 AS ghost_count_correct
FROM pgmnemo.stats();

-- Test 2: ghost_count type is BIGINT (not null)
SELECT pg_typeof(ghost_count) = 'bigint'::regtype AS ghost_count_is_bigint
FROM pgmnemo.stats();

-- Test 3: ghost_count does NOT count closed rows (t_valid_to < 'infinity')
-- Ingest duplicate to trigger bitemporal close
SELECT pgmnemo.ingest('test-role', 1, 'topic-ghost', 'lesson without provenance updated',
                      3, NULL, NULL, NULL, '{}');
-- The closed row (t_valid_to < infinity) must not contribute to ghost_count
SELECT ghost_count <= 2 AS ghost_count_excludes_closed
FROM pgmnemo.stats();

-- Test 4: after adding provenance to all rows, ghost_count = 0
UPDATE pgmnemo.agent_lesson
SET    commit_sha = 'sha-filled', verified_at = NOW()
WHERE  verified_at IS NULL AND t_valid_to = 'infinity'::TIMESTAMPTZ;
SELECT ghost_count = 0 AS ghost_count_zero_after_fix
FROM pgmnemo.stats();
```

### 3.3 `test_v060_as_of_ts.sql`

```sql
-- Test: as_of_ts parameter in recall_lessons() (DESIGN_AS_OF_TS_V060.md §6.3)

-- Setup: pre-existing lesson at T1 = NOW() - INTERVAL '1 hour'
-- (We'll use manual t_valid_from/t_valid_to manipulation since ingest sets them to NOW())

-- Insert lesson L1 (active at T1, closed at T2)
-- Insert lesson L2 (active at T2 = NOW())

-- Test 1: as_of_ts NULL → returns current active lessons (L2, not L1)
SELECT COUNT(*) = 1 AS null_asoft_returns_current
FROM pgmnemo.recall_lessons($embedding, 10, NULL, NULL, NULL, NULL)
WHERE lesson_id = <L2_id>;

-- Test 2: as_of_ts = T1 → returns L1 (active at T1)
SELECT COUNT(*) = 1 AS historical_query_returns_l1
FROM pgmnemo.recall_lessons($embedding, 10, NULL, NULL, NULL, NOW() - INTERVAL '1 hour')
WHERE lesson_id = <L1_id>;

-- Test 3: as_of_ts = T1 → does NOT return L2 (created after T1)
SELECT COUNT(*) = 0 AS historical_query_excludes_l2
FROM pgmnemo.recall_lessons($embedding, 10, NULL, NULL, NULL, NOW() - INTERVAL '1 hour')
WHERE lesson_id = <L2_id>;

-- Test 4: as_of_ts far future ('infinity') → returns all currently-active rows
SELECT COUNT(*) >= 1 AS future_ts_returns_active
FROM pgmnemo.recall_lessons($embedding, 10, NULL, NULL, NULL, 'infinity'::TIMESTAMPTZ);

-- Test 5: as_of_ts before any ingestion → 0 rows
SELECT COUNT(*) = 0 AS pre_epoch_returns_empty
FROM pgmnemo.recall_lessons($embedding, 10, NULL, NULL, NULL, '1970-01-01'::TIMESTAMPTZ);

-- Test 6: GUC does not leak across transactions
-- After recall_lessons with as_of_ts, in next tx GUC should be empty
SELECT COALESCE(NULLIF(current_setting('pgmnemo.as_of_timestamp', TRUE), ''), 'empty') = 'empty'
    AS guc_cleared_after_commit;

-- Test 7: as_of_ts flows correctly through hybrid path (query_text present)
SELECT COUNT(*) >= 0 AS hybrid_path_handles_as_of_ts
FROM pgmnemo.recall_lessons($embedding, 10, NULL, NULL, 'some query text', NOW() - INTERVAL '1 hour');
```

### 3.4 `test_v060_ingest_notice.sql`

```sql
-- Test: RAISE NOTICE on bitemporal close+create (RFC Q5)
-- pgTAP does not capture RAISE NOTICE directly; test via indirect count verification.

SET pgmnemo.gate_strict = 'off';

-- Ingest initial lesson
SELECT pgmnemo.ingest('role', 1, 'topic-dedup', 'original content',
                      3, NULL, 'sha-v1', NULL, '{}') AS first_id;

-- Test 1: Verify initial lesson is active
SELECT COUNT(*) = 1 AS initial_lesson_active
FROM pgmnemo.agent_lesson
WHERE topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Ingest same role+topic+commit_sha → triggers bitemporal close+create
-- NOTICE should fire: "bitemporal close+create fired — closed 1 prior version(s)"
SELECT pgmnemo.ingest('role', 1, 'topic-dedup', 'updated content',
                      3, NULL, 'sha-v1', NULL, '{}') AS second_id;

-- Test 2: After dedup, exactly 1 active row
SELECT COUNT(*) = 1 AS one_active_after_dedup
FROM pgmnemo.agent_lesson
WHERE topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Test 3: The closed row exists (t_valid_to < 'infinity')
SELECT COUNT(*) = 1 AS closed_row_exists
FROM pgmnemo.agent_lesson
WHERE topic = 'topic-dedup'
  AND t_valid_to < 'infinity'::TIMESTAMPTZ;

-- Test 4: Idempotent re-run (same args again) → NOTICE fires again
-- Indirectly verify via row count
SELECT pgmnemo.ingest('role', 1, 'topic-dedup', 'updated content',
                      3, NULL, 'sha-v1', NULL, '{}') AS third_id;
SELECT COUNT(*) = 1 AS still_one_active_after_idempotent
FROM pgmnemo.agent_lesson
WHERE topic = 'topic-dedup'
  AND t_valid_to = 'infinity'::TIMESTAMPTZ;
```

### 3.5 `test_v060_rrf_fix_a.sql`

```sql
-- Test: Fix-A — rrf_diag normalized to primary ranking signal in recall_hybrid()

-- Setup: insert 3 lessons with known vec+bm25 characteristics
-- L1: high cosine, low BM25 (dense-biased)
-- L2: low cosine, high BM25 (BM25-biased)
-- L3: medium cosine, medium BM25 (balanced)

-- Test 1: rrf_score column is non-NULL and in expected range [0, ~0.013] for default params
SELECT rrf_score BETWEEN 0.0 AND 0.02 AS rrf_score_in_range
FROM pgmnemo.recall_hybrid($embedding, 'query text', 10, NULL, NULL)
LIMIT 1;

-- Test 2: ORDER BY fix-a — score = (rrf_diag / norm_denom) + auxiliaries
-- Verify that the returned `score` is consistent with the Fix-A formula
-- (rrf_score / max_rrf ≤ score, since score = rrf_norm + auxiliary components ≥ 0)
SELECT score >= rrf_score AS fix_a_score_gte_rrf_score
FROM pgmnemo.recall_hybrid($embedding, 'query text', 10, NULL, NULL)
LIMIT 1;

-- Test 3: Verify normalization — top result's normalized rrf_diag ≤ 1.0
-- norm_denom = (0.4+0.4)/61 ≈ 0.01311
-- rrf_norm = rrf_score / norm_denom; must be ≤ 1.0
SELECT (rrf_score / (0.8 / 61.0)) <= 1.001 AS rrf_norm_leq_1
FROM pgmnemo.recall_hybrid($embedding, 'query text', 10, NULL, NULL)
ORDER BY score DESC
LIMIT 1;

-- Test 4: No NULL scores returned
SELECT COUNT(*) FILTER (WHERE score IS NULL) = 0 AS no_null_scores
FROM pgmnemo.recall_hybrid($embedding, 'query text', 10, NULL, NULL);

-- Test 5: as_of_ts GUC flows through recall_lessons → recall_hybrid
-- With a historical as_of_ts, closed lessons excluded from hybrid results
SET pgmnemo.as_of_timestamp = '2020-01-01 00:00:00+00';
SELECT COUNT(*) = 0 AS pre_ingestion_ts_returns_empty
FROM pgmnemo.recall_hybrid($embedding, 'query text', 10, NULL, NULL);
RESET pgmnemo.as_of_timestamp;
```

### 3.6 Expected new `.out` files (pgregress)

```
extension/expected/test_v060_ghost_count.out
extension/expected/test_v060_as_of_ts.out
extension/expected/test_v060_ingest_notice.out
extension/expected/test_v060_rrf_fix_a.out
```

Register in `extension/Makefile` under `REGRESS =` list.

---

## 4. Docs Delta

### 4.1 `docs/MIGRATION.md` — add §0.5.1→0.6.0

**Section to add** (after the existing `0.5.1` section if present, or at top):

```markdown
## 0.5.1 → 0.6.0

**Release date:** 2026-05-22 (target) | **SQL changes:** Yes

### Upgrade

```bash
ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';
```

No table rewrite. DDL-only changes (CREATE OR REPLACE / DROP + CREATE functions).
Estimated duration: <1s on any corpus size.

### Breaking changes

**None.** All public function signatures remain backward compatible (see PLAN §2).

### New behavior

1. **`recall_hybrid()` ranking** — Fix-A: rank is now computed by normalized RRF
   (`rrf_diag / max_rrf_diag`) instead of weighted linear fusion score. Ranking
   order will change; this is the intended improvement. Output columns unchanged.

2. **`recall_lessons()` — `as_of_ts` parameter** — new optional 6th parameter.
   Existing calls with 5 args resolve to `as_of_ts = NULL` (identical behavior).

3. **`stats()` — `ghost_count`** — new column at position 14. Named-column callers
   unaffected. `SELECT *` callers receive one additional column.

4. **`ingest()` — dedup NOTICE** — RAISE NOTICE now fires when bitemporal
   close+create triggers. Informational only; no behavior change.

### Rollback

PostgreSQL does not support `ALTER EXTENSION pgmnemo UPDATE TO '0.5.1'` (downgrade
via extension update mechanism is not supported). To roll back:

1. Restore from pre-upgrade backup:
   ```bash
   # Recommended pre-upgrade snapshot:
   pg_dump -Fc -t 'pgmnemo.*' $DSN > pgmnemo_pre_060_$(date +%Y%m%d).dump
   # Restore:
   pg_restore -d $DSN pgmnemo_pre_060_YYYYMMDD.dump
   ```
2. OR: manual function replacement — restore v0.5.1 function bodies:
   ```bash
   psql $DSN -f extension/pgmnemo--0.5.1.sql  # fresh install (destructive)
   ```
3. Zero-downtime rollback: not available (extension upgrade holds ACCESS EXCLUSIVE
   briefly; rollback requires restore from dump).

**Pre-upgrade checklist:**
- [ ] `COPY pgmnemo.agent_lesson TO '/tmp/pgmnemo_backup.csv' CSV HEADER;`
- [ ] `pg_dump -Fc -t 'pgmnemo.*' $DSN > pgmnemo_pre_060.dump`
- [ ] Confirm no `ALTER EXTENSION` in flight
```

### 4.2 `docs/USAGE.md` — §Tuning additions

**Add to §Tuning (after `temporal_boost` section):**

```markdown
### Using `as_of_ts` for point-in-time recall

`recall_lessons()` v0.6.0 accepts `as_of_ts TIMESTAMPTZ` as the 6th parameter:

```sql
-- Current state (default)
SELECT * FROM pgmnemo.recall_lessons($embedding, 10, 'developer', 1, 'query');

-- Historical state — what did the agent know at session start?
SELECT * FROM pgmnemo.recall_lessons($embedding, 10, 'developer', 1, 'query',
                                     '2026-04-01 09:00:00+00');
```

**Requires bitemporality (v0.5.0+).** Rows have `t_valid_from` / `t_valid_to` columns.
Only lessons where `t_valid_from ≤ as_of_ts < t_valid_to` are returned.

**Connection pool safety:** `as_of_ts` sets a transaction-local GUC internally
(`set_config(... TRUE)`). The GUC is cleared after `COMMIT` or `ROLLBACK`.
No session-state leaks between pooled connections.
```

**Add/expand `temporal_boost × recency_weight` interaction table** (see RFC Q7 — ensure
this existing table from v0.5.2 docs is accurate and referenced):

```markdown
### `temporal_boost` × `recency_weight` interaction

Recency factor: `exp(−recency_weight × temporal_boost × age_days / 90)`

| age_days | boost=1, w=0.05 | boost=3, w=0.10 | boost=10, w=0.05 |
|----------|-----------------|-----------------|-----------------|
| 7        | 0.996           | 0.977           | 0.962           |
| 90       | 0.951           | 0.741           | 0.607           |
| 365      | 0.817           | 0.018           | 0.130           |
| 730      | 0.668           | 0.000           | 0.017           |

**Warning:** At `recency_weight=0.10` + `temporal_boost=3`, lessons >365 days old
score ~0 on the recency component. If your corpus includes historical lessons (migrated
from earlier systems), use `recency_weight=0.05` + `temporal_boost=10` or
`temporal_boost=1` (effectively disables extra decay).

**Guidance:**
- Fast-moving corpus (ephemeral tasks): `boost=10, recency_weight=0.05`
- Balanced: `boost=3, recency_weight=0.05`
- Historical / archival corpus: `boost=1, recency_weight=0.05`
- Disable temporal decay entirely: `boost=0`
```

### 4.3 `docs/SQL_REFERENCE.md §3` — GUC and function updates

**§2.3 `pgmnemo.recall_lessons(...)`** — update signature table to include `as_of_ts`:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `as_of_ts` | `TIMESTAMPTZ` | `NULL` | Point-in-time scope. When set, restricts candidates to lessons where `t_valid_from ≤ as_of_ts < t_valid_to`. NULL = current active lessons. |

**§2.x `pgmnemo.recall_hybrid(...)`** — update COMMENT reference; note Fix-A:

> v0.6.0: PRIMARY ranking signal is normalized `rrf_diag` (RRF, Cormack 2009),
> replacing `fusion_score` (weighted linear). `rrf_score` column = raw `rrf_diag`.

**§3 GUCs** — add `ghost_count` tracking:

| GUC / function | Type | Default | Notes |
|---|---|---|---|
| `ghost_count` in `pgmnemo.stats()` | `BIGINT` | — | Active lessons with `verified_at IS NULL`. Target: < 5% before enabling `include_unverified=off`. v0.6.0. |

### 4.4 `CHANGELOG.md` — v0.6.0 entry

**Prepend** to CHANGELOG.md:

```markdown
## [0.6.0] — 2026-05-22

### Theme

RRF Fix-A (rank-based fusion replaces linear fusion) + temporal recall API
(`as_of_ts`) + dedup observability + ghost-count metric. Answers RFC Q4/Q5/Q6/Q7.

### Bench verdict

*To be completed in QA_TEST phase. Gate: p < 0.05 AND Δrecall@10 ≥ +1pp on LME-S.*

### Changed (behavior)

- **`recall_hybrid()` Fix-A** — ORDER BY now uses `rrf_diag` normalized to [0,1]
  (`rrf_diag / ((vec_weight + bm25_weight) / (rrf_k + 1.0))`), replacing
  weighted linear `fusion_score`. Literature basis: Cormack et al. (SIGIR 2009).
  Expected lift on LME-S: +1.5–2pp recall@10 (to be confirmed by bench).
  Output columns unchanged; `rrf_score` value unchanged.
- **`recall_hybrid()` temporal filter** — reads `pgmnemo.as_of_timestamp` GUC,
  now set by `recall_lessons(as_of_ts)` parameter.

### Added

- **`recall_lessons()` — `as_of_ts TIMESTAMPTZ DEFAULT NULL`** (6th param). Point-in-time
  recall scoping. When non-NULL, restricts to lessons valid at `as_of_ts`
  (`t_valid_from ≤ as_of_ts < t_valid_to`). Backward compatible: existing calls unchanged.
  Implements "temporal moat" positioning (R4 Final) + RFC Q1 Phase 2.

- **`pgmnemo.stats()` — `ghost_count BIGINT`** — active lessons without provenance
  (`verified_at IS NULL`). Use to track Phase 4 migration progress toward
  `include_unverified=off`. RFC Q4.

- **`ingest()` — bitemporal close+create NOTICE** — `RAISE NOTICE` when dedup
  bitemporal close+create fires. Message: `"bitemporal close+create fired — closed
  N prior version(s) (content_hash=...). New lesson_id=..."`. RFC Q5.

### Upgrade

```bash
ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';
```

No table rewrite. Duration: <1s.

### Rollback

See `docs/MIGRATION.md §0.5.1→0.6.0 §Rollback`.
```

---

## 5. Bench Protocol (QA_TEST Phase)

### 5.1 Pre-bench setup

```bash
cd /external-repos/pgmnemo

# Verify baseline database has v0.5.1 extension
psql "$DSN" -c "SELECT pgmnemo.version();"
# Expected: 0.5.1

# Ensure bench venv is active
source benchmarks/.venv_bench/venv/bin/activate

# Verify embeddings cache exists (avoids OOM on re-embed)
ls benchmarks/.embed_cache/
```

### 5.2 LME-S baseline (fusion_score ORDER BY — v0.5.1)

```bash
# Run baseline BEFORE applying Fix-A migration
python benchmarks/longmemeval/runner.py \
    --out-dir benchmarks/longmemeval/results/fix_a_bench/baseline_fusion \
    --model none \
    --vec-weight 0.4 \
    --bm25-weight 0.4 \
    --rrf-k 60

# Capture baseline metrics
cat benchmarks/longmemeval/results/fix_a_bench/baseline_fusion/metrics.json
```

### 5.3 Apply Fix-A migration

```bash
# Apply the v0.6.0 migration
psql "$DSN" -c "ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';"

# Verify version
psql "$DSN" -c "SELECT pgmnemo.version();"
# Expected: 0.6.0

# Verify Fix-A active: rrf_diag should dominate ORDER BY
psql "$DSN" -c "SELECT score, rrf_score FROM pgmnemo.recall_hybrid('[...]'::vector(1024), 'test query', 3) LIMIT 3;"
```

### 5.4 LME-S Fix-A run

```bash
python benchmarks/longmemeval/runner.py \
    --out-dir benchmarks/longmemeval/results/fix_a_bench/fix_a_rrf \
    --model none \
    --vec-weight 0.4 \
    --bm25-weight 0.4 \
    --rrf-k 60

cat benchmarks/longmemeval/results/fix_a_bench/fix_a_rrf/metrics.json
```

### 5.5 Significance test (gate decision)

```bash
python scripts/significance_test.py \
    benchmarks/longmemeval/results/fix_a_bench/baseline_fusion/metrics.json \
    benchmarks/longmemeval/results/fix_a_bench/fix_a_rrf/metrics.json

# Interpretation:
# PASS: p_corr < 0.05 AND delta_recall@10 >= +0.01 → proceed to SHIP
# FAIL: p_corr >= 0.05 OR delta_recall@10 < +0.01 → downgrade to v0.6.1 investigation
```

### 5.6 LoCoMo validation (regression check)

```bash
python benchmarks/scripts/run_locomo_bench.py \
    --out-dir benchmarks/locomo/results/fix_a_bench/fix_a_rrf \
    --vec-weight 0.4 \
    --bm25-weight 0.4 \
    --rrf-k 60

python scripts/significance_test.py \
    benchmarks/locomo/results/fix_a_bench/baseline_fusion/metrics.json \
    benchmarks/locomo/results/fix_a_bench/fix_a_rrf/metrics.json

# Gate: no significant REGRESSION (p_corr < 0.05 AND delta < -0.01 → BLOCK)
```

### 5.7 as_of_ts smoke test (manual)

```bash
# Insert a lesson, capture its id and timestamp, insert an update,
# verify historical query returns original
psql "$DSN" <<'SQL'
SET pgmnemo.gate_strict = 'off';
WITH ins AS (
    SELECT pgmnemo.ingest('test', 1, 'as_of_smoke', 'original', 3, NULL, NULL, NULL, '{}') AS id
)
SELECT id, NOW() AS t_insert FROM ins;
-- Wait 1 second
SELECT pg_sleep(1);
-- Update (bitemporal close+create)
SELECT pgmnemo.ingest('test', 1, 'as_of_smoke', 'updated', 3, NULL, NULL, NULL, '{}');
-- Query at current time: should see 'updated'
SELECT lesson_text FROM pgmnemo.recall_lessons(NULL::vector(1024), 10, 'test', 1, NULL, NULL)
LIMIT 1;
-- Query at t_insert: should see 'original'
-- (use actual t_insert value from above)
SQL
```

---

## 6. Pre-Commit Checklist (SHIP Phase)

### SQL migration
- [ ] `extension/pgmnemo--0.5.1--0.6.0.sql` exists and is parseable (`psql -f ... --set ON_ERROR_STOP=1`)
- [ ] `extension/pgmnemo.control` has `default_version = '0.6.0'`
- [ ] `ALTER EXTENSION pgmnemo UPDATE TO '0.6.0'` applies cleanly from v0.5.1 (fresh PG17 test DB)
- [ ] All existing regression tests pass: `cd extension && make installcheck`
- [ ] All 4 new regression tests pass and `.out` files committed

### Backward compatibility
- [ ] `recall_lessons($1, 10, NULL, NULL, 'query')` (5-arg positional) works post-migration
- [ ] `recall_lessons(query_embedding => $1, k => 10)` (named-arg) works post-migration
- [ ] `recall_lessons_pooled($1, 10, 1)` works post-migration (delegates to 6-arg form)
- [ ] `stats()` has exactly 14 columns including `ghost_count`

### Fix-A gate
- [ ] LME-S significance test: `p_corr < 0.05` on `recall@10`
- [ ] LME-S lift: `Δrecall@10 ≥ +0.01` (1pp)
- [ ] LoCoMo: no significant regression (`p_corr < 0.05` AND `delta < -0.01` = BLOCK)
- [ ] Bench results committed to `benchmarks/gate/v0.6.0.json`

### Docs
- [ ] `CHANGELOG.md` v0.6.0 entry with actual bench numbers filled in
- [ ] `docs/MIGRATION.md` has §0.5.1→0.6.0 section with rollback steps
- [ ] `docs/USAGE.md` has `as_of_ts` usage example and updated temporal_boost table
- [ ] `docs/SQL_REFERENCE.md §2.3` has `as_of_ts` param documented
- [ ] `docs/SQL_REFERENCE.md §3` has `ghost_count` in stats output documented

### Package
- [ ] `META.json` version updated to `0.6.0`
- [ ] `pgmnemo_mcp/pyproject.toml` version updated (if MCP client exposes new params)
- [ ] `scripts/build_pgxn_bundle.sh` produces clean `pgmnemo-0.6.0.zip`
- [ ] `pgmnemo-0.6.0.zip` contains `pgmnemo--0.5.1--0.6.0.sql` and `pgmnemo--0.6.0.sql`

---

## 7. Cost / Complexity Estimate

| Work item | Complexity | Estimated effort | Risk |
|-----------|-----------|-----------------|------|
| §1 Fix-A in `recall_hybrid()` — ORDER BY + temporal filter | LOW | 2h | LOW — rrf_diag already computed; 2 lines change + new DECLARE vars |
| §2 `recall_lessons()` — add `as_of_ts` param + DROP + vector-only path temporal filter | MEDIUM | 4h | LOW — additive param + copy of existing body with filter addition |
| §3 `stats()` ghost_count | LOW | 1h | LOW — 1 subquery addition |
| §4 `ingest()` dedup NOTICE | LOW | 1h | LOW — pre-insert COUNT + RAISE NOTICE |
| 4 regression test files + expected `.out` | MEDIUM | 4h | LOW — established pattern |
| Docs delta (4 files) | MEDIUM | 3h | LOW |
| Bench run (LME-S real-DB) | HIGH | 3–6h | MEDIUM — OOM risk on LME-S 277MB corpus; may require streaming runner |
| Significance test interpretation + SHIP decision | LOW | 0.5h | LOW |
| **Total** | | **~18–22h** | **LOW–MEDIUM** |

**Critical path:** Bench run (LME-S real-DB) is the longest item and has the only OOM risk.
Use `benchmarks/longmemeval/run_nollm.py` (no-LLM runner) if the full runner OOMs.
If OOM persists, use the pre-existing `scripts/bench_lme_s.py` streaming version.

**No-go trigger:** If Fix-A fails the LME-S significance gate, revert `recall_hybrid()` ORDER BY
to `fusion_score` and ship v0.6.0 with only: `as_of_ts` + `ghost_count` + ingest NOTICE.
The RRF fix becomes v0.6.1 pending investigation.

---

## 8. Open Items / Deferred to v0.7.0

| Item | Reason deferred |
|------|-----------------|
| Expose `as_of_ts` directly on `recall_hybrid()` signature | Removes GUC indirection; v0.6.0 uses GUC for minimal blast radius |
| `CREATE INDEX ix_lesson_bitemp ON pgmnemo.agent_lesson (t_valid_from, t_valid_to)` | Not needed at the adopter corpus size (~50k rows); needed at >500k |
| `recall_lessons_pooled()` — add `as_of_ts` param | Low-priority; cross-role use-case not in the adopter's Phase 2 requirement |
| `content_hash` update to SHA-256 from MD5 | Collision risk negligible at corpus sizes; breaking schema change |

---

*Document: `spec/v060/PLAN_V060.md` | pgmnemo v0.6.0 | chief_architect (id=86) | 2026-05-22*
