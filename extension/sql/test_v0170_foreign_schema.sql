-- test_v0170_foreign_schema.sql
-- pg_regress tests for pgmnemo v0.17.0 — foreign-schema CI gate (R3)
--
-- Proves every user-facing capability returns non-empty (or succeeds without
-- error) when called in a database whose schema, roles and topics look nothing
-- like the pgmnemo development corpus.
--
-- "Foreign schema" means:
--   - Roles: 'cs_agent', 'billing_reviewer', 'med_clerk' (customer-support / medical)
--   - project_id: -1700 (isolated from all other test data)
--   - Topics: appointment scheduling, billing disputes, prescription refill
--   - No agent-fleet terminology in any lesson text
--   - No pre-existing mem_edge rows for these lessons
--
-- Strategy:
--   - INSERT lessons directly (gate_strict=off, include_unverified=on)
--   - Use ingest() for the lesson that needs entity_keys populated (B6/D2)
--   - Suppress NULL-embedding NOTICE with client_min_messages=WARNING for tabular
--     tests so expected output is fully deterministic
--   - Use real array_fill embedding for B2 (recall_fast HNSW test)
--
-- Coverage:
--   A1: corpus seeded — 6 alien lessons (3 INSERT + 3 ingest) exist
--   A2: stats() returns exactly 1 row (schema introspection, always non-empty)
--   B1: recall_hybrid() — ≥1 row on alien BM25 query (role+project filtered)
--   B2: recall_fast() — ≥1 row with real embedding (HNSW path)
--   B3: recall_lessons() — ≥1 row via hybrid BM25 path
--   B4: recall_lessons_pooled() — ≥1 row (unfiltered, at least alien data present)
--   B5: recall_situation() — ≥1 row for alien incident fingerprint
--   B6: recall_entity() — ≥1 row for alien failure-class entity key
--   C1: navigate_locate() — ≥1 row for BM25-matchable alien text
--   C2: navigate_expand() — succeeds, no crash on alien corpus (0 edges is ok)
--   C3: navigate_locate_dispatch() — ≥1 row on alien corpus
--   D1: reinforce() — succeeds on alien lesson_id (confidence updates)
--   D2: extract_entity_keys() — correct keys from alien medical/billing text
--   D3: extract_sit_fp() — correct fingerprint for alien incident topic
--   E1: graph_proximity_weight default = 0.0 (R2 ablation-based reset):
--       recall count identical with explicit 0.0 vs unset (COALESCE)
--   F1: classify_content_type() — non-NULL for alien text ('must' → procedure)
--   F2: reclassify_corpus(dry_run=TRUE) — ≥1 row (global corpus scan)
--   F3: consolidate(dry_run=TRUE) — ≥1 cluster (I4+I6 near-duplicate pair)
--
-- Test isolation: role 'cs_agent'/'billing_reviewer'/'med_clerk', project_id -1700.
-- gate_strict off: bypass provenance gate for test writes.
-- SPDX-License-Identifier: Apache-2.0

SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.20.0';

-- =============================================================================
-- Fixture: alien-corpus lessons
-- =============================================================================

-- 3 direct-INSERT lessons (no embeddings — BM25 + situation + graph paths tested)
INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, is_active,
     content_type, verified_at, artifact_hash, t_valid_from, t_valid_to)
VALUES
    -- Lesson I1: appointment scheduling (BM25 target, cs_agent)
    ('cs_agent', -1700,
     'appointment scheduling policy update Q3',
     'appointment scheduling: patients must confirm 24 hours before their appointment or the slot is released to the waiting list.',
     3, TRUE, 'procedure',
     now(), 'alien-test-hash-i1',
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ),
    -- Lesson I2: incident with sit_fp (recall_situation target)
    ('billing_reviewer', -1700,
     '[INCIDENT:BILLING_DISPUTE_UNRESOLVED] Billing dispute unresolved after 30 days',
     'failure_class=BILLING_DISPUTE_UNRESOLVED outcome=ESCALATED The customer disputed charge. Resolution pending.',
     4, TRUE, 'incident',
     now(), 'alien-test-hash-i2',
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ),
    -- Lesson I3: escalation policy (navigate_locate target)
    ('cs_agent', -1700,
     'escalation workflow for tier-2 support',
     'escalation: billing dispute unresolved after 5 business days goes to tier-2 support.',
     3, TRUE, 'fact',
     now(), 'alien-test-hash-i3',
     '-infinity'::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ);

-- 1 ingest()-based lesson with a real embedding (recall_fast HNSW target)
DO $$
DECLARE
    -- cosine 0.961 to I4: above consolidate's 0.92 clustering threshold,
    -- below ingest's 0.98 dedupe guard (an exact copy is swallowed, not stored).
    _emb  vector(1024) := (SELECT (array_fill(-0.05::float4, ARRAY[20])
                                || array_fill(0.05::float4, ARRAY[1004]))::vector(1024));
    _id   BIGINT;
BEGIN
    _id := pgmnemo.ingest(
        'cs_agent'::TEXT,
        -1700::INT,
        'appointment reminder protocol'::TEXT,
        'appointment reminder: send SMS 48 hours before scheduled appointment. Include cancellation link for self-service.'::TEXT,
        3::SMALLINT,
        _emb,
        NULL::TEXT,  -- commit_sha (gate_strict=off)
        'alien-test-hash-i4'::TEXT,
        '{}'::JSONB,
        'procedure'::TEXT
    );
    RAISE NOTICE 'FIXTURE I4 PASS: ingest with embedding succeeded';
END;
$$;

-- 1 ingest()-based lesson for entity key auto-population (recall_entity target)
DO $$
DECLARE
    _id   BIGINT;
    _keys JSONB;
BEGIN
    _id := pgmnemo.ingest(
        'med_clerk'::TEXT,
        -1700::INT,
        'prescription refill gateway failure'::TEXT,
        'failure_class=REFILL_GATEWAY_TIMEOUT outcome=PARTIAL_FAILURE The refill gateway timed out. Route to schema:pharmacy.requests fallback queue.'::TEXT,
        5::SMALLINT,
        NULL::vector(1024),
        NULL::TEXT,
        'alien-test-hash-i5'::TEXT,
        '{}'::JSONB,
        'procedure'::TEXT
    );
    SELECT metadata->'entity_keys' INTO _keys FROM pgmnemo.agent_lesson WHERE id = _id;
    IF _keys IS NOT NULL AND jsonb_array_length(_keys) >= 1 THEN
        RAISE NOTICE 'FIXTURE I5 PASS: ingest auto-populated entity_keys';
    ELSE
        RAISE EXCEPTION 'FIXTURE I5 FAIL: entity_keys not populated by ingest; got %', _keys;
    END IF;
END;
$$;

-- 1 ingest()-based lesson with a near-duplicate embedding to I4 (consolidate target)
DO $$
DECLARE
    _emb  vector(1024) := (SELECT array_fill(0.05::float4, ARRAY[1024])::vector(1024));
    _id   BIGINT;
BEGIN
    _id := pgmnemo.ingest(
        'cs_agent'::TEXT,
        -1700::INT,
        'appointment scheduling sms reminder'::TEXT,
        'appointment reminder: send text message 48 hours before scheduled appointment. Cancellation link included for self-service.'::TEXT,
        3::SMALLINT,
        _emb,
        NULL::TEXT,  -- commit_sha (gate_strict=off)
        'alien-test-hash-i6'::TEXT,
        '{}'::JSONB,
        'procedure'::TEXT
    );
    RAISE NOTICE 'FIXTURE I6 PASS: ingest with near-duplicate embedding succeeded (consolidate target)';
END;
$$;

-- =============================================================================
-- A1: Alien corpus seeded — verify lesson count
-- =============================================================================

DO $$
DECLARE
    _count INT;
BEGIN
    SELECT count(*) INTO _count
    FROM pgmnemo.agent_lesson
    WHERE project_id = -1700 AND is_active;

    IF _count = 6 THEN
        RAISE NOTICE 'A1 PASS: 6 alien-corpus lessons seeded (project_id=-1700)';
    ELSE
        RAISE EXCEPTION 'A1 FAIL: expected 6 alien lessons, got %', _count;
    END IF;
END;
$$;

-- =============================================================================
-- A2: stats() — 1 row (schema introspection, always non-empty)
-- =============================================================================

SELECT count(*) = 1 AS a2_stats_non_empty FROM pgmnemo.stats();

-- =============================================================================
-- B1: recall_hybrid() — non-empty on alien BM25 query
-- Suppress NULL-embedding NOTICE for stable output.
-- =============================================================================

SET client_min_messages = WARNING;

SELECT count(*) >= 1 AS b1_recall_hybrid_non_empty
FROM pgmnemo.recall_hybrid(
    NULL::vector(1024),
    'appointment scheduling',
    5,
    'cs_agent',
    -1700
);

SET client_min_messages = NOTICE;

-- =============================================================================
-- B2: recall_fast() — ≥1 row with real embedding (HNSW path, lesson I4)
-- =============================================================================

DO $$
DECLARE
    _emb   vector(1024) := (SELECT array_fill(0.05::float4, ARRAY[1024])::vector(1024));
    _count INT;
BEGIN
    SELECT count(*) INTO _count
    FROM pgmnemo.recall_fast(
        _emb,
        5,
        'cs_agent',
        -1700
    );
    IF _count >= 1 THEN
        RAISE NOTICE 'B2 PASS: recall_fast() returned ≥1 row with real embedding';
    ELSE
        RAISE EXCEPTION 'B2 FAIL: expected ≥1 rows from recall_fast, got %', _count;
    END IF;
END;
$$;

-- =============================================================================
-- B3: recall_lessons() — non-empty on alien hybrid query
-- =============================================================================

SET client_min_messages = WARNING;

SELECT count(*) >= 1 AS b3_recall_lessons_non_empty
FROM pgmnemo.recall_lessons(
    NULL::vector(1024),
    5,
    'cs_agent',
    -1700,
    'appointment scheduling'
);

SET client_min_messages = NOTICE;

-- =============================================================================
-- B4: recall_lessons_pooled() — non-empty (alien data included)
-- =============================================================================

SET client_min_messages = WARNING;

SELECT count(*) >= 1 AS b4_pooled_non_empty
FROM pgmnemo.recall_lessons_pooled(
    NULL::vector(1024),
    5,
    NULL  -- app_id: NULL pools all tenants
);

SET client_min_messages = NOTICE;

-- =============================================================================
-- B5: recall_situation() — ≥1 row for alien incident fingerprint
-- =============================================================================

DO $$
DECLARE
    _fp    TEXT;
    _count INT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:BILLING_DISPUTE_UNRESOLVED] Billing dispute unresolved after 30 days',
        'failure_class=BILLING_DISPUTE_UNRESOLVED outcome=ESCALATED The customer disputed charge. Resolution pending.'
    );
    IF _fp IS NULL THEN
        RAISE EXCEPTION 'B5 FAIL: extract_sit_fp returned NULL for alien incident';
    END IF;

    SELECT count(*) INTO _count
    FROM pgmnemo.recall_situation(_fp, p_project_id => -1700, p_k => 10);

    IF _count >= 1 THEN
        RAISE NOTICE 'B5 PASS: recall_situation() non-empty for alien incident (fp=%)', _fp;
    ELSE
        RAISE EXCEPTION 'B5 FAIL: expected ≥1 rows for fp=%, got %', _fp, _count;
    END IF;
END;
$$;

-- =============================================================================
-- B6: recall_entity() — ≥1 row for alien failure-class entity key
-- (entity_keys populated by ingest() in fixture I5)
-- =============================================================================

DO $$
DECLARE
    _count INT;
BEGIN
    SELECT count(*) INTO _count
    FROM pgmnemo.recall_entity('failure:REFILL_GATEWAY_TIMEOUT', k => 10);

    IF _count >= 1 THEN
        RAISE NOTICE 'B6 PASS: recall_entity() non-empty for alien failure key';
    ELSE
        RAISE EXCEPTION 'B6 FAIL: expected ≥1 rows from recall_entity(failure:REFILL_GATEWAY_TIMEOUT), got %', _count;
    END IF;
END;
$$;

-- =============================================================================
-- C1: navigate_locate() — ≥1 row on alien BM25 text
-- =============================================================================

SET client_min_messages = WARNING;

SELECT count(*) >= 1 AS c1_navigate_locate_non_empty
FROM pgmnemo.navigate_locate(
    NULL::vector(1024),
    'appointment scheduling billing dispute',
    50000,
    NULL::JSONB
);

SET client_min_messages = NOTICE;

-- =============================================================================
-- C2: navigate_expand() — succeeds on alien lesson IDs (0 edges is acceptable)
-- =============================================================================

DO $$
DECLARE
    _lid   BIGINT;
    _count INT;
BEGIN
    SELECT id INTO _lid FROM pgmnemo.agent_lesson
    WHERE artifact_hash = 'alien-test-hash-i1' LIMIT 1;

    IF _lid IS NULL THEN
        RAISE EXCEPTION 'C2 FAIL: alien lesson I1 not found';
    END IF;

    SELECT count(*) INTO _count
    FROM pgmnemo.navigate_expand(
        ARRAY[_lid],
        ARRAY['lesson_text', 'topic'],
        2,
        0.5
    );
    -- count may be 0 (no edges) or >= 1 (if seeds included); function must not crash
    -- count may be 0 (no neighbors, seed not included) or ≥1 — function must not crash
    RAISE NOTICE 'C2 PASS: navigate_expand() completed without error on alien corpus';
END;
$$;

-- =============================================================================
-- C3: navigate_locate_dispatch() — ≥1 row on alien corpus
-- =============================================================================

SET client_min_messages = WARNING;

SELECT count(*) >= 1 AS c3_dispatch_non_empty
FROM pgmnemo.navigate_locate_dispatch(
    NULL::vector(1024),
    'billing dispute appointment escalation'
);

SET client_min_messages = NOTICE;

-- =============================================================================
-- D1: reinforce() — succeeds on alien lesson (confidence update)
-- =============================================================================

DO $$
DECLARE
    _lid      BIGINT;
    _old_conf REAL;
    _new_conf REAL;
BEGIN
    SELECT id, confidence INTO _lid, _old_conf
    FROM pgmnemo.agent_lesson
    WHERE artifact_hash = 'alien-test-hash-i1' LIMIT 1;

    PERFORM pgmnemo.reinforce(_lid, 'success');

    SELECT confidence INTO _new_conf
    FROM pgmnemo.agent_lesson WHERE id = _lid;

    -- Beta posterior: new confidence = (success_count + alpha) / (total + alpha + beta)
    -- After 1 success: (1+1)/(1+1+1) = 0.667 (if prior counts were 0)
    IF _new_conf > _old_conf THEN
        RAISE NOTICE 'D1 PASS: reinforce(success) raised alien lesson confidence';
    ELSE
        RAISE EXCEPTION 'D1 FAIL: reinforce(success) did not increase confidence (was %, now %)', _old_conf, _new_conf;
    END IF;
END;
$$;

-- =============================================================================
-- D2: extract_entity_keys() — correct keys from alien medical/billing text
-- =============================================================================

DO $$
DECLARE
    _keys TEXT[];
BEGIN
    _keys := pgmnemo.extract_entity_keys(
        'failure_class=REFILL_GATEWAY_TIMEOUT outcome=PARTIAL_FAILURE The refill gateway timed out on schema:pharmacy.requests table.'
    );
    IF 'failure:REFILL_GATEWAY_TIMEOUT' = ANY(_keys)
       AND 'schema:pharmacy.requests' = ANY(_keys)
    THEN
        RAISE NOTICE 'D2 PASS: extract_entity_keys() found alien failure + schema keys';
    ELSE
        RAISE EXCEPTION 'D2 FAIL: expected failure:REFILL_GATEWAY_TIMEOUT and schema:pharmacy.requests in %', _keys;
    END IF;
END;
$$;

-- =============================================================================
-- D3: extract_sit_fp() — correct fingerprint for alien incident topic
-- =============================================================================

DO $$
DECLARE
    _fp TEXT;
BEGIN
    _fp := pgmnemo.extract_sit_fp(
        '[INCIDENT:BILLING_DISPUTE_UNRESOLVED] Billing dispute unresolved after 30 days'
    );
    IF _fp = 'class=BILLING_DISPUTE_UNRESOLVED' THEN
        RAISE NOTICE 'D3 PASS: extract_sit_fp() returned correct fingerprint for alien incident';
    ELSE
        RAISE EXCEPTION 'D3 FAIL: expected class=BILLING_DISPUTE_UNRESOLVED, got %', _fp;
    END IF;
END;
$$;

-- =============================================================================
-- E1: graph_proximity_weight default = 0.0 (R2 ablation-based reset)
-- Verify: result count with explicit 0.0 == result count with unset GUC
-- (COALESCE default changed from 0.2 to 0.0 in v0.17.0)
-- =============================================================================

SET client_min_messages = WARNING;

DO $$
DECLARE
    _count_explicit INT;
    _count_default  INT;
BEGIN
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';
    SELECT count(*) INTO _count_explicit
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'appointment scheduling', 10, 'cs_agent', -1700
    );

    RESET pgmnemo.graph_proximity_weight;
    SELECT count(*) INTO _count_default
    FROM pgmnemo.recall_hybrid(
        NULL::vector(1024), 'appointment scheduling', 10, 'cs_agent', -1700
    );

    IF _count_explicit = _count_default THEN
        RAISE NOTICE 'E1 PASS: graph_proximity_weight COALESCE default=0.0 — result count identical (explicit 0.0 = unset)';
    ELSE
        RAISE EXCEPTION 'E1 FAIL: count mismatch — explicit 0.0=%, unset=%', _count_explicit, _count_default;
    END IF;
END;
$$;

SET client_min_messages = NOTICE;

-- =============================================================================
-- F1: classify_content_type() — returns non-NULL for alien appointment text
-- 'must' keyword triggers the procedure arm; proves classifier works without
-- domain-specific training on our vocabulary.
-- =============================================================================

SELECT pgmnemo.classify_content_type(
    'appointment scheduling: patients must confirm 24 hours before their appointment'
) IS NOT NULL AS f1_classify_non_null;

-- =============================================================================
-- F2: reclassify_corpus(dry_run := TRUE) — returns ≥1 row
-- All 5 alien lessons carry classifier-owned types (procedure, incident, fact)
-- so they appear in the candidate set; the global scan guarantees ≥1 result.
-- =============================================================================

SET client_min_messages = WARNING;

SELECT count(*) >= 1 AS f2_reclassify_non_empty
FROM pgmnemo.reclassify_corpus(TRUE, 10);

SET client_min_messages = NOTICE;

-- =============================================================================
-- F3: consolidate(p_dry_run := TRUE) — finds ≥1 cluster for alien role
-- I4 and I6 (seeded in fixture) both carry array_fill(0.05) embeddings;
-- cosine similarity = 1.0 ≥ p_similarity = 0.92 → pair always detected.
-- =============================================================================

DO $$
DECLARE
    _count INT;
BEGIN
    SELECT count(*) INTO _count
    FROM pgmnemo.consolidate(
        0.92,         -- p_similarity
        TRUE,         -- p_dry_run
        'cs_agent',   -- p_role (scoped to alien corpus — avoids test interference)
        50            -- p_limit
    );

    IF _count >= 1 THEN
        RAISE NOTICE 'F3 PASS: consolidate(dry_run=true) found ≥1 cluster for alien-schema role';
    ELSE
        RAISE EXCEPTION 'F3 FAIL: expected ≥1 cluster row from consolidate (I4+I6 pair), got %', _count;
    END IF;
END;
$$;
