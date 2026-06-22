-- pgmnemo--0.10.1--0.11.0.sql
-- pgmnemo upgrade 0.10.1 → 0.11.0
-- ADR-61 §3 D3 / P0.2: typed recall — p_content_types in recall_hybrid
--
-- Single change: add optional parameter p_content_types text[] DEFAULT NULL (LAST)
-- to pgmnemo.recall_hybrid.
--
--   NULL  → unchanged behavior (all content types; full backward compat).
--   non-NULL → pushes content_type = ANY(p_content_types) into BOTH subplans
--               (vector + BM25) BEFORE RRF fusion.
--               Uses index ix_pgmnemo_content_type_active — pushdown, not post-filter.
--   '{}'  → zero rows (explicit empty array, no silent fallback to all-types).
--
-- All other functions unchanged from 0.10.1.
-- Users on 0.10.0 should apply pgmnemo--0.10.0--0.11.0.sql instead.
--
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.11.0'" to load this file. \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- recall_hybrid — v0.11.0 (based on 0.10.1 body + p_content_types param)
--
-- Drop old 9-param overload (from 0.10.1) to prevent ambiguous-function errors.
-- The 10-param version is backward-compatible: p_content_types DEFAULT NULL.
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS pgmnemo.recall_hybrid(
    vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT
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
    p_content_types   text[]           DEFAULT NULL   -- P0.2: typed recall; NULL=all types
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
              -- P0.2: typed recall pushdown into BM25 subplan (ix_pgmnemo_content_type_active)
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

    RETURN QUERY
    WITH RECURSIVE
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
          -- P0.2: typed recall pushdown into vector subplan (ix_pgmnemo_content_type_active)
          AND (recall_hybrid.p_content_types IS NULL
               OR al.content_type = ANY(recall_hybrid.p_content_types))
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
        ORDER BY al.embedding <=> query_embedding
        LIMIT _fetch_k_vec
    ),
    all_candidates AS (
        SELECT
            v.id, v.role, v.project_id, v.topic, v.lesson_text,
            v.importance, v.metadata, v.commit_sha, v.artifact_hash,
            v.verified_at, v.created_at, v.confidence,
            v.raw_vec_score,
            COALESCE(bw.raw_bm25_score, 0.0::DOUBLE PRECISION) AS raw_bm25_score
        FROM vec_candidates v
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
        WHERE bw.id NOT IN (SELECT id FROM vec_candidates)
    ),
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

COMMENT ON FUNCTION pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT, text[]) IS
    'v0.11.0 — ADR-61 §3 D3 / P0.2: typed recall. '
    'New param p_content_types text[] DEFAULT NULL (LAST, backward-compatible). '
    'NULL → unchanged behavior (all content types). '
    'non-NULL → pushes content_type = ANY(p_content_types) into BOTH subplans (vec + BM25) '
    'BEFORE RRF fusion — uses ix_pgmnemo_content_type_active (pushdown, not post-filter). '
    'Empty array ''{}'': zero rows returned (no silent fallback to all-types). '
    'Inherits all v0.10.1 (#87) fixes: query_text cap, indexed full_text BM25, '
    'bm25_budget_ms timeout, simple tsconfig. '
    'VOLATILE (side-effects: recency stamp, temp table _pgmnemo_bm25_work).';

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Typed WRITE API — ADR-61 §3 D2 (P1.1 / MEM-ERA-P1.1)
--    Identical to the G section in pgmnemo--0.10.0--0.11.0.sql.
--    pgmnemo.canonical_slug  — normalizer / entity-key validator
--    pgmnemo.remember_fact   — bitemporal write with PII gate + FOR UPDATE
--    pgmnemo.remember_event  — append-only event write
--    pgmnemo.remember_relation — entity-hub upsert + idempotent edge write
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.canonical_slug(p_raw text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE STRICT
AS $$
DECLARE
    _s    text;
    _type text;
    _id   text;
    _sep  int;
BEGIN
    _s   := regexp_replace(lower(trim(p_raw)), '[^a-z0-9_:]', '_', 'g');
    _sep := position(':' IN _s);
    IF _sep = 0 THEN
        RAISE EXCEPTION
            'pgmnemo.canonical_slug: input must contain ":" separator: %', p_raw;
    END IF;
    _type := left(_s, _sep - 1);
    _id   := substring(_s FROM _sep + 1);

    IF _type NOT IN ('person','org','project','product','location','concept') THEN
        RAISE EXCEPTION
            'pgmnemo.canonical_slug: unknown type prefix "%": '
            'valid={person,org,project,product,location,concept}', _type;
    END IF;

    _id := regexp_replace(regexp_replace(_id, '_{2,}', '_', 'g'), '^_|_$', '', 'g');
    IF _id = '' THEN
        RAISE EXCEPTION
            'pgmnemo.canonical_slug: id part is empty after normalization: %', p_raw;
    END IF;

    RETURN _type || ':' || _id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.canonical_slug(text) IS
    'P1.1 / ADR-61 D2: normalise a raw entity key to <type>:<id>. '
    'Lowercases input, replaces non-[a-z0-9_] with underscore, '
    'validates type prefix in {person,org,project,product,location,concept}. '
    'IMMUTABLE STRICT — raises on NULL input or unknown type.';

CREATE OR REPLACE FUNCTION pgmnemo.remember_fact(
    p_role          text,
    p_project_id    int,
    p_entity_key    text,
    p_property      text,
    p_value         text,
    p_confidence    real            DEFAULT 0.5,
    p_source_type   text            DEFAULT 'auto_captured',
    p_source_run_id text            DEFAULT NULL,
    p_t_valid_from  timestamptz     DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    _topic      text;
    _existing   RECORD;
    _new_id     bigint;
    _state      text;
    _is_pii     boolean;
    _art_hash   text;
BEGIN
    IF p_entity_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION
            'pgmnemo.remember_fact: invalid entity_key "%" — '
            'must match ^(person|org|project|product|location|concept):[a-z0-9_]+$',
            p_entity_key;
    END IF;

    _topic := p_entity_key || ':' || p_property;

    _is_pii := p_property IN ('email','phone','address','telegram','full_name')
               AND p_entity_key LIKE 'person:%';

    IF _is_pii AND p_source_type <> 'system' THEN
        _state := 'candidate';
    ELSE
        _state := CASE WHEN p_confidence >= 0.8 THEN 'validated' ELSE 'candidate' END;
    END IF;

    SELECT id, lesson_text, confidence, version_n
    INTO _existing
    FROM pgmnemo.agent_lesson
    WHERE role         = p_role
      AND topic        = _topic
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND content_type = 'fact'
      AND t_valid_to   = 'infinity'::timestamptz
      AND is_active    = TRUE
    FOR UPDATE;

    IF NOT FOUND THEN
        _art_hash := 'rf:' || p_role || ':'
                     || COALESCE(p_project_id::text, '') || ':' || _topic;

        INSERT INTO pgmnemo.agent_lesson (
            role, project_id, topic, lesson_text,
            content_type, state, state_changed_at,
            confidence, source_type, source_run_id,
            t_valid_from, t_valid_to,
            version_n, patch_count,
            artifact_hash, verified_at
        ) VALUES (
            p_role, p_project_id, _topic, p_value,
            'fact', _state, NOW(),
            p_confidence, p_source_type, p_source_run_id,
            p_t_valid_from, 'infinity'::timestamptz,
            1, 0,
            _art_hash, NOW()
        ) RETURNING id INTO _new_id;

        RETURN _new_id;

    ELSIF _existing.lesson_text = p_value THEN
        UPDATE pgmnemo.agent_lesson
        SET confidence  = GREATEST(confidence, p_confidence),
            patch_count = patch_count + 1,
            updated_at  = NOW()
        WHERE id = _existing.id;

        RETURN _existing.id;

    ELSE
        UPDATE pgmnemo.agent_lesson
        SET t_valid_to       = NOW(),
            state            = 'superseded',
            state_changed_at = NOW(),
            is_active        = FALSE,
            updated_at       = NOW()
        WHERE id = _existing.id;

        _art_hash := 'rf:' || p_role || ':'
                     || COALESCE(p_project_id::text, '') || ':' || _topic
                     || ':v' || (_existing.version_n + 1)::text;

        INSERT INTO pgmnemo.agent_lesson (
            role, project_id, topic, lesson_text,
            content_type, state, state_changed_at,
            confidence, source_type, source_run_id,
            t_valid_from, t_valid_to,
            version_n, patch_count,
            artifact_hash, verified_at
        ) VALUES (
            p_role, p_project_id, _topic, p_value,
            'fact', _state, NOW(),
            p_confidence, p_source_type, p_source_run_id,
            p_t_valid_from, 'infinity'::timestamptz,
            _existing.version_n + 1, 0,
            _art_hash, NOW()
        ) RETURNING id INTO _new_id;

        RETURN _new_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_fact(text, int, text, text, text, real, text, text, timestamptz) IS
    'P1.1 / ADR-61 D2: bitemporal fact write with PII gate. '
    'SELECT FOR UPDATE serialises concurrent writes. '
    'Same value → GREATEST(confidence), patch_count+1. '
    'New value → supersede prior + INSERT version_n+1. '
    'PII gate: email/phone/address/telegram/full_name on person:* → candidate unless source_type=system.';

CREATE OR REPLACE FUNCTION pgmnemo.remember_event(
    p_role          text,
    p_project_id    int,
    p_entity_key    text,
    p_event_type    text,
    p_ts            timestamptz,
    p_summary       text,
    p_confidence    real        DEFAULT 0.8,
    p_source_type   text        DEFAULT 'auto_captured',
    p_source_run_id text        DEFAULT NULL,
    p_source_dag_id text        DEFAULT NULL,
    p_metadata      jsonb       DEFAULT '{}'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    _new_id   bigint;
    _topic    text;
    _state    text;
    _art_hash text;
BEGIN
    _topic    := COALESCE(p_entity_key, '') || ':event:' || p_event_type;
    _state    := CASE WHEN p_confidence < 0.5 THEN 'candidate' ELSE 'validated' END;
    _art_hash := 're:' || p_role || ':'
                 || COALESCE(p_project_id::text, '') || ':'
                 || _topic || ':' || p_ts::text;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text,
        content_type, state, state_changed_at,
        confidence, source_type, source_run_id, source_dag_id,
        metadata,
        t_valid_from, t_valid_to,
        artifact_hash, verified_at
    ) VALUES (
        p_role, p_project_id, _topic, p_summary,
        'event', _state, NOW(),
        p_confidence, p_source_type, p_source_run_id, p_source_dag_id,
        COALESCE(p_metadata, '{}'),
        p_ts, 'infinity'::timestamptz,
        _art_hash, NOW()
    ) RETURNING id INTO _new_id;

    RETURN _new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_event(text, int, text, text, timestamptz, text, real, text, text, text, jsonb) IS
    'P1.1 / ADR-61 D2: append-only event write. '
    'Always INSERTs (events are immutable historical facts). '
    'topic = COALESCE(entity_key,"")||":event:"||(event_type). '
    't_valid_from = p_ts; t_valid_to = infinity. '
    'state = validated (or candidate when confidence < 0.5).';

CREATE OR REPLACE FUNCTION pgmnemo.remember_relation(
    p_role       text,
    p_project_id int,
    p_from_key   text,
    p_to_key     text,
    p_relation   text,
    p_confidence real   DEFAULT 0.5,
    p_metadata   jsonb  DEFAULT '{}'
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    _from_id    bigint;
    _to_id      bigint;
    _edge_id    bigint;
    _old_meta   jsonb;
    _new_meta   jsonb;
    _art_hash   text;
    _edge_kind  pgmnemo.edge_kind;
    _weight     real;
BEGIN
    IF p_from_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION
            'pgmnemo.remember_relation: invalid from_key "%"', p_from_key;
    END IF;
    IF p_to_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION
            'pgmnemo.remember_relation: invalid to_key "%"', p_to_key;
    END IF;

    _edge_kind := CASE
        WHEN p_relation IN ('CAUSED_BY','DERIVED_FROM','CONTRADICTS')
            THEN 'causal'::pgmnemo.edge_kind
        WHEN p_relation IN ('CO_OCCURRED','PRECEDED_BY')
            THEN 'temporal'::pgmnemo.edge_kind
        WHEN p_relation IN ('ENTITY_LINK','SHARED_TAG','IS_A','PART_OF','MEMBER_OF',
                             'OWNS','MANAGES','REPORTS_TO','RELATED_TO')
            THEN 'entity'::pgmnemo.edge_kind
        ELSE 'semantic'::pgmnemo.edge_kind
    END;

    _weight  := GREATEST(0.0::real, LEAST(1.0::real, COALESCE(p_confidence, 0.5::real)));
    _new_meta := COALESCE(p_metadata, '{}') ||
                 jsonb_build_object('from_key', p_from_key, 'to_key', p_to_key);

    SELECT id INTO _from_id
    FROM pgmnemo.agent_lesson
    WHERE content_type = 'entity'
      AND topic        = p_from_key
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active    = TRUE
      AND t_valid_to   = 'infinity'::timestamptz
    LIMIT 1;

    IF NOT FOUND THEN
        _art_hash := 'rs_ent:' || p_role || ':'
                     || COALESCE(p_project_id::text, '') || ':' || p_from_key;
        INSERT INTO pgmnemo.agent_lesson (
            role, project_id, topic, lesson_text,
            content_type, state, state_changed_at,
            t_valid_from, t_valid_to,
            artifact_hash, verified_at,
            metadata
        ) VALUES (
            p_role, p_project_id, p_from_key, p_from_key,
            'entity', 'candidate', NOW(),
            NOW(), 'infinity'::timestamptz,
            _art_hash, NOW(),
            jsonb_build_object('canonical_name', p_from_key, 'stub', true)
        ) RETURNING id INTO _from_id;
    END IF;

    SELECT id INTO _to_id
    FROM pgmnemo.agent_lesson
    WHERE content_type = 'entity'
      AND topic        = p_to_key
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active    = TRUE
      AND t_valid_to   = 'infinity'::timestamptz
    LIMIT 1;

    IF NOT FOUND THEN
        _art_hash := 'rs_ent:' || p_role || ':'
                     || COALESCE(p_project_id::text, '') || ':' || p_to_key;
        INSERT INTO pgmnemo.agent_lesson (
            role, project_id, topic, lesson_text,
            content_type, state, state_changed_at,
            t_valid_from, t_valid_to,
            artifact_hash, verified_at,
            metadata
        ) VALUES (
            p_role, p_project_id, p_to_key, p_to_key,
            'entity', 'candidate', NOW(),
            NOW(), 'infinity'::timestamptz,
            _art_hash, NOW(),
            jsonb_build_object('canonical_name', p_to_key, 'stub', true)
        ) RETURNING id INTO _to_id;
    END IF;

    SELECT me.id, me.metadata INTO _edge_id, _old_meta
    FROM pgmnemo.mem_edge me
    WHERE me.source_id     = _from_id
      AND me.target_id     = _to_id
      AND me.relation_type = p_relation
      AND me.valid_until   IS NULL;

    IF NOT FOUND THEN
        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata, valid_from)
        VALUES
            (_from_id, _to_id, p_relation, _edge_kind, _weight, _new_meta, clock_timestamp())
        RETURNING id INTO _edge_id;

    ELSIF _old_meta IS DISTINCT FROM _new_meta THEN
        UPDATE pgmnemo.mem_edge
        SET valid_until = clock_timestamp(),
            updated_at  = clock_timestamp()
        WHERE id = _edge_id;

        INSERT INTO pgmnemo.mem_edge
            (source_id, target_id, relation_type, edge_kind, weight, metadata, valid_from)
        VALUES
            (_from_id, _to_id, p_relation, _edge_kind, _weight, _new_meta, clock_timestamp())
        RETURNING id INTO _edge_id;
    END IF;

    RETURN _edge_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_relation(text, int, text, text, text, real, jsonb) IS
    'P1.1 / ADR-61 D2: entity-hub relation write. '
    'Resolves from/to by content_type=entity AND topic=key; auto-stubs missing entities. '
    'Idempotent on triple (from_key, to_key, relation): '
    '  same metadata → return existing edge_id; '
    '  new metadata → close active edge + insert replacement. '
    'Returns mem_edge.id of the current active edge.';
