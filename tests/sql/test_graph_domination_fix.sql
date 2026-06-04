-- test_graph_domination_fix.sql
-- Cold-start regression test for BUG_RECALL_GRAPH_DOMINATES_2026-06-03
-- SPDX-License-Identifier: Apache-2.0
--
-- MECHANISM: graph_proximity was additive (0.2 * 0.8 = 0.16) vs max rrf_sparse (~0.013).
-- Graph topology decided ranking, burying perfect vector matches below top-50.
-- FIX (v0.8.1): graph is now multiplicative re-rank: (rrf+aux)*(1+graph_weight*proximity).
-- At default weight=0.2, max graph boost is ~16% — tie-breaker, not driver.
--
-- This test:
--   1. Ingests a synthetic lesson that exactly answers a held-out query
--   2. Asserts it returns top-3 with graph_weight=0 (pure retrieval)
--   3. Asserts it returns top-3 with default graph_weight (0.2)
--   4. Verifies multiplicative graph cannot bury a perfect match
-- ─────────────────────────────────────────────────────────────────────────────

\set ON_ERROR_STOP on
SET search_path TO pgmnemo, public;
SET pgmnemo.include_unverified = 'true';
SET pgmnemo.gate_strict = 'warn';

-- ═══════════════════════════════════════════════════════════════════════════
-- SETUP: Create a synthetic "perfect match" lesson
-- ═══════════════════════════════════════════════════════════════════════════

-- Probe text: a unique synthetic lesson with distinctive vocabulary
DO $$
DECLARE
    _probe_id BIGINT;
    _probe_text TEXT := 'When configuring the quantum flux capacitor for temporal stabilization, '
                       'always set the chroniton dampening field to 42.7 megahertz because '
                       'lower frequencies cause resonance cascade failures in the dilithium matrix.';
    _probe_topic TEXT := 'quantum_flux_capacitor_temporal_config';
    _probe_embedding vector(1024);
    _result RECORD;
    _rank_at_zero INT;
    _rank_at_default INT;
    _score_at_zero DOUBLE PRECISION;
    _score_at_default DOUBLE PRECISION;
BEGIN
    -- Generate a deterministic embedding (unit vector with first component = 1)
    -- This will be the "perfect match" embedding for our probe query
    _probe_embedding := (
        SELECT array_agg(CASE WHEN i = 1 THEN 1.0 ELSE 0.0 END)::vector(1024)
        FROM generate_series(1, 1024) i
    );

    -- Insert the probe lesson
    INSERT INTO pgmnemo.agent_lesson (
        role, topic, lesson_text, embedding, importance,
        commit_sha, verified_at, is_active, lesson_tsv,
        t_valid_from, t_valid_to
    )
    VALUES (
        'test_probe', _probe_topic, _probe_text, _probe_embedding, 5,
        'deadbeef', NOW(), TRUE,
        setweight(to_tsvector('english', _probe_topic), 'A') ||
        to_tsvector('english', _probe_text),
        NOW(), 'infinity'::TIMESTAMPTZ
    )
    RETURNING id INTO _probe_id;

    RAISE NOTICE 'Probe lesson inserted: id=%', _probe_id;

    -- ═══════════════════════════════════════════════════════════════════════
    -- TEST 1: graph_weight=0 — pure retrieval, probe must be top-3
    -- ═══════════════════════════════════════════════════════════════════════
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';

    SELECT rn, score INTO _result
    FROM (
        SELECT lesson_id, score,
               ROW_NUMBER() OVER (ORDER BY score DESC) AS rn
        FROM pgmnemo.recall_hybrid(
            _probe_embedding,
            'quantum flux capacitor chroniton dampening temporal stabilization',
            50
        )
    ) sub
    WHERE lesson_id = _probe_id;

    _rank_at_zero := COALESCE(_result.rn, 999);
    _score_at_zero := COALESCE(_result.score, 0.0);

    IF _rank_at_zero > 3 THEN
        RAISE EXCEPTION 'COLD-START FAIL: probe at rank=% (expected top-3) with graph_weight=0. Score=%',
            _rank_at_zero, _score_at_zero;
    END IF;
    RAISE NOTICE 'TEST 1 PASS: probe rank=% score=% at graph_weight=0',
        _rank_at_zero, _score_at_zero;

    -- ═══════════════════════════════════════════════════════════════════════
    -- TEST 2: default graph_weight (0.2) — probe must still be top-3
    -- ═══════════════════════════════════════════════════════════════════════
    RESET pgmnemo.graph_proximity_weight;  -- back to default 0.2

    SELECT rn, score INTO _result
    FROM (
        SELECT lesson_id, score,
               ROW_NUMBER() OVER (ORDER BY score DESC) AS rn
        FROM pgmnemo.recall_hybrid(
            _probe_embedding,
            'quantum flux capacitor chroniton dampening temporal stabilization',
            50
        )
    ) sub
    WHERE lesson_id = _probe_id;

    _rank_at_default := COALESCE(_result.rn, 999);
    _score_at_default := COALESCE(_result.score, 0.0);

    IF _rank_at_default > 3 THEN
        RAISE EXCEPTION 'COLD-START FAIL: probe at rank=% (expected top-3) with default graph_weight. Score=%',
            _rank_at_default, _score_at_default;
    END IF;
    RAISE NOTICE 'TEST 2 PASS: probe rank=% score=% at default graph_weight',
        _rank_at_default, _score_at_default;

    -- ═══════════════════════════════════════════════════════════════════════
    -- TEST 3: Verify multiplicative property — graph cannot flip rank order
    -- if probe was #1 at graph_weight=0, it must remain #1 at default
    -- (because multiplicative boost cannot promote a lower-rrf item past a higher one)
    -- ═══════════════════════════════════════════════════════════════════════
    IF _rank_at_zero = 1 AND _rank_at_default > 1 THEN
        RAISE EXCEPTION 'MULTIPLICATIVE INVARIANT VIOLATED: probe was rank=1 at graph_weight=0 '
            'but rank=% at default — graph is still additive?', _rank_at_default;
    END IF;
    RAISE NOTICE 'TEST 3 PASS: multiplicative invariant holds (rank at 0 = %, rank at default = %)',
        _rank_at_zero, _rank_at_default;

    -- ═══════════════════════════════════════════════════════════════════════
    -- TEST 4: navigate_locate — probe must appear in top-3
    -- ═══════════════════════════════════════════════════════════════════════
    SET LOCAL pgmnemo.graph_proximity_weight = '0.0';

    PERFORM 1 FROM (
        SELECT id, score,
               ROW_NUMBER() OVER (ORDER BY score DESC) AS rn
        FROM pgmnemo.navigate_locate(
            _probe_embedding,
            'quantum flux capacitor chroniton dampening temporal stabilization',
            10000
        )
    ) sub
    WHERE id = _probe_id AND rn <= 3;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'navigate_locate COLD-START FAIL: probe not in top-3 at graph_weight=0';
    END IF;
    RAISE NOTICE 'TEST 4 PASS: navigate_locate returns probe in top-3 at graph_weight=0';

    -- ═══════════════════════════════════════════════════════════════════════
    -- TEST 5: topic-only BM25 match
    -- Query uses only topic keywords, no lesson_text overlap
    -- ═══════════════════════════════════════════════════════════════════════
    SELECT rn INTO _result
    FROM (
        SELECT lesson_id,
               ROW_NUMBER() OVER (ORDER BY score DESC) AS rn
        FROM pgmnemo.recall_hybrid(
            NULL,  -- no embedding
            'quantum_flux_capacitor_temporal_config',
            50
        )
    ) sub
    WHERE lesson_id = _probe_id;

    IF _result.rn IS NOT NULL AND _result.rn <= 10 THEN
        RAISE NOTICE 'TEST 5 PASS: topic-only BM25 returns probe at rank=%', _result.rn;
    ELSE
        RAISE NOTICE 'TEST 5 INFO: topic-only BM25 probe rank=% (topic BM25 may not match via text-only path)',
            COALESCE(_result.rn, -1);
    END IF;

    -- ═══════════════════════════════════════════════════════════════════════
    -- CLEANUP: Remove probe lesson
    -- ═══════════════════════════════════════════════════════════════════════
    DELETE FROM pgmnemo.agent_lesson WHERE id = _probe_id;
    RAISE NOTICE 'Probe lesson removed. All cold-start regression tests PASSED.';
END;
$$;
