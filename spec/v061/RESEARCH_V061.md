---
date: 2026-05-23
author: principal_investigator (id=77)
task_id: SWDEV-260523-1-RESEARCH
phase: RESEARCH
parent_dag: SWDEV-260523-1
status: complete
---

# pgmnemo v0.6.1 — Research Document

**Scope:** Three independently deliverable features deferred from v0.6.0:
1. RRF Fix-A (A-scale variant) — real-DB benchmark gate
2. `as_of_ts TIMESTAMPTZ` parameter on `recall_lessons()` — minimal-diff implementation
3. Stress test (issue #29) — `recall_lessons()` at 100K/1M/10M rows

---

## 0. Current State Summary

### v0.6.0 delivered (2026-05-22)
- `pgmnemo.stats()` `ghost_count BIGINT` column (RFC Q4)
- `pgmnemo.ingest()` RAISE NOTICE on bitemporal dedup (Q5)
- `pgmnemo.recall_stats` view (R9)
- **`recall_lessons()` and `recall_hybrid()` are BYTE-IDENTICAL to v0.5.1**

### Two features deferred from v0.6.0
1. **RRF Fix-A**: simulation showed −2.40pp recall@10 regression. Root cause: A-norm's
   aux-override problem at top-K boundary (90.3% of ranking variance from aux). Simulation
   uses TF-IDF (lexical + lexical, ρ≈0.85) vs real-DB bge-m3 (semantic + lexical, ρ≈0.45).
   A-scale is recommended alternative but untestable in simulation.
2. **as_of_ts**: implementation in v0.6.0 dev branch caused `AmbiguousColumn: role` and
   `UndefinedTable: graph_walk` runtime failures, caught by `smoke_recall_hybrid.py`.
   Root cause: CTE column name collision when `role_filter` param name clashes with
   `al.role` column alias in ambiguous CTE scope after refactor.

### Baseline metrics (carry-forward from v0.3.0 bench)
| Metric | Value |
|--------|-------|
| LongMemEval-S recall@10 (bge-m3) | 0.9334 (MINIMUM to preserve) |
| LoCoMo session recall@10 (DRAGON) | **0.7994** (GATE: must not go below) |
| pg_regress tests | 14/14 PASS |

---

## 1. Feature 1 — RRF Fix-A: Implementation Alternatives

### Background
`recall_hybrid()` currently uses linear fusion: `ORDER BY fusion_score DESC` where
`fusion_score = vec_weight * cosine_score + bm25_weight * bm25_score`.

RRF replaces this with rank-based fusion: `rrf_diag = vec_w/(rrf_k + vec_rank) + bm25_w/(rrf_k + bm25_rank)`.

RRF benefit scales inversely with rank correlation between signals. bge-m3 + BM25 have
τ ≈ 0.35–0.55 (semantic vs lexical) → expected real-DB benefit +1.5 to +3pp recall@10
(per literature; discounted for pgmnemo specifics → expected +0.5 to +2pp).

**The `rrf_score` (diagnostic) column already exists** in v0.5.1/v0.6.0 output — only the
`ORDER BY` clause and anchor selection in the CTE need to change.

### Alternative 1-A: A-scale (RECOMMENDED)

**Formulation:**
```sql
ORDER BY (
    s.rrf_diag
  + 0.000863 * (s.importance::DOUBLE PRECISION / 5.0)
  + 0.000863 * GREATEST(0.0, 1.0 - LEAST(age_days/90.0, 1.0))
  + 0.000863 * provenance_strength
  + 0.003452 * COALESCE(gp.proximity, 0.0)
) DESC
```

Where `0.000863 = 0.05 × 0.01726` and `0.003452 = 0.20 × 0.01726`.
Ratio `0.01726 = rrf_diag_max / fusion_score_typical = (0.8/61) / 0.76`.

**Diff scope**: Change `anchors` CTE `ORDER BY fusion_score` → `ORDER BY rrf_diag` (2 lines),
change final score formula aux coefficients (4 constants), change final `ORDER BY` (same 4 constants).
**No CTE structural change. No new params. No DROP required.** `CREATE OR REPLACE` sufficient.

| Criterion | Assessment |
|-----------|-----------|
| Aux override risk | **LOW** — max aux diff = 0.006 << rrf_norm delta of 0.016 (vs A-norm's 0.35) |
| Preserves aux as tiebreakers | **YES** — importance/recency/prov still contribute ~0.6% of range |
| Backward compat | **YES** — same function signature, `CREATE OR REPLACE` |
| Diff size | **~10 lines** (smallest of all variants) |
| Simulation testable | **NO** — identical to A-pure in simulation (aux excluded from sim scorer) |
| Smoke test safe | **YES** — no CTE changes, no column renames |
| Literature support | **YES** — A-scale ≈ A-pure theoretically; expected ≈ +0.5 to +2pp on real-DB |

**Pros:**
- Smallest code change — only constants change, no CTE restructuring
- Preserves design intent of aux signals (importance, recency, provenance as tiebreakers)
- No new SQL parameters or GUCs needed
- `smoke_recall_hybrid.py` output column set unchanged → smoke test passes by construction
- Provably safer than A-norm: max aux override capacity drops 58× (0.35 → 0.006)

**Cons:**
- Cannot be verified in simulation (must await real-DB bench)
- Still unproven on real data — if bge-m3/BM25 rank correlation is higher than expected (τ > 0.65), RRF benefit may be marginal
- Magic constant 0.01726 not documented in code unless COMMENT added

### Alternative 1-B: A-pure (rrf_diag only)

**Formulation:**
```sql
ORDER BY s.rrf_diag DESC
```
Remove all aux terms from final score and ORDER BY. Remove `_rrf_norm_denom` variable.

| Criterion | Assessment |
|-----------|-----------|
| Aux override risk | **NONE** — no aux terms |
| Preserves aux signals | **NO** — importance/recency/prov discarded entirely |
| Backward compat | **YES** — same signature |
| Diff size | **~15 lines** (remove aux terms from score + ORDER BY) |
| Simulation testable | **NO** — identical to A-scale in simulation |
| Smoke test safe | **YES** — no CTE changes |

**Pros:**
- Cleanest signal — pure rank consensus, no contamination
- Easier to explain mathematically
- Largest theoretical gain if signals are truly decorrelated

**Cons:**
- Breaks the principle that importance=5 (founder-verified) lessons surface first when recall quality is equal
- Documented use case: `SET pgmnemo.graph_proximity_weight = 0.3` for time-sensitive recall — aux loss affects that pattern
- No empirical advantage over A-scale (theory: A-scale ≈ A-pure ± 0.2pp)
- Harder to defend in paper: "we discarded importance" needs justification

### Alternative 1-C: A-norm (original v0.6.0 attempt — REJECTED)

**Formulation:**
```sql
_rrf_norm_denom := (vec_weight + bm25_weight) / (_rrf_k_f + 1.0);  -- ≈ 0.01311
ORDER BY (s.rrf_diag / _rrf_norm_denom + 0.05*importance + 0.05*recency + ...) DESC
```

**Root cause of v0.6.0 regression** (from INVESTIGATION_FIX_A_REGRESSION.md §2.3):
All top-K candidates cluster at rrf_norm ≈ 0.994 (ceiling effect). Within this cluster,
aux terms dominate: max aux diff = 0.35 >> adjacent rrf_norm delta of 0.016 → aux terms
override retrieval signal at decision boundary → recall regression.

**Pros:**
- Mathematically cleaner normalization (score in [0,1])
- Intended to make aux coefficients "comparable" to rrf_norm

**Cons:**
- Analytically broken: creates the ceiling problem it tries to solve
- Causes 90.3% of top-K ranking variance to come from aux (proven)
- Showed −2.40pp simulation regression (all 4 metrics, all rrf_k values tested)
- **REJECTED** — do not implement

### Alternative 1-D: Parametric weight GUC

Add `pgmnemo.rrf_promotion_weight` GUC (range [0.0, 1.0]) that interpolates between
fusion_score (0.0) and rrf_diag (1.0) for the anchor selection and ORDER BY.

**Pros:** Allows tuning without code change; operators can A/B test without extension upgrade

**Cons:**
- More complex implementation (DECLARE var, COALESCE GUC read, blend formula)
- Increases PLAN scope beyond v0.6.1 target
- Still requires real-DB bench at a specific setting to gate the release
- Not needed if A-scale is the correct default

**Verdict:** Nice-to-have for v0.7.0. Out of scope for v0.6.1.

### Recommendation for Feature 1

**Implement A-scale (Alternative 1-A).** Smallest diff, safest aux handling, real-DB
bench required either way. A-pure as fallback if A-scale fails gate by < 0.5pp.

---

## 2. Feature 2 — as_of_ts Parameter: Implementation Alternatives

### Background

The v0.6.0 attempt added `as_of_ts TIMESTAMPTZ DEFAULT NULL` as a 6th parameter to
`recall_lessons()`, which then set GUC `pgmnemo.as_of_timestamp`, which `recall_hybrid()`
read to filter `t_valid_from <= as_of_ts < t_valid_to`.

**Two bugs hit smoke_recall_hybrid.py:**
1. `AmbiguousColumn: role` — in a refactored CTE, the parameter name `role_filter` and
   column alias `al.role` conflated after scope restructuring. In the v0.5.1 body,
   `recall_hybrid.role_filter IS NULL OR al.role = recall_hybrid.role_filter` uses
   function-qualified reference — a CTE rename broke this qualification.
2. `UndefinedTable: graph_walk` — CTE refactor moved `graph_walk` inside a sub-select
   that could not reference it from an outer CTE, causing UndefinedTable at execute time.

**Constraint (from task spec):** Do NOT rewrite recall_hybrid() body. Use v0.5.1 safe pattern.

### Alternative 2-A: GUC-only approach (no body changes to recall_hybrid)

`recall_lessons()` gets a new 6th param `as_of_ts TIMESTAMPTZ DEFAULT NULL`. If non-NULL,
recall_lessons() calls `SET LOCAL pgmnemo.as_of_timestamp = <ts>` before delegating to
recall_hybrid(). recall_hybrid() adds a single filter line reading the GUC — but **without
any CTE restructuring**. The filter is added as an additional `AND` clause in the existing
`WHERE` predicate of `raw_candidates`.

**Implementation (minimal diff to recall_hybrid() v0.5.1 body):**
```sql
-- In DECLARE block of recall_hybrid() — ADD:
_as_of_ts TIMESTAMPTZ;

-- In BEGIN block — ADD (after include_unverified GUC read):
BEGIN
    _as_of_ts := NULLIF(
        current_setting('pgmnemo.as_of_timestamp', TRUE), ''
    )::TIMESTAMPTZ;
EXCEPTION WHEN OTHERS THEN
    _as_of_ts := NULL;
END;

-- In raw_candidates WHERE clause — ADD (after existing conditions):
AND (_as_of_ts IS NULL
     OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
```

**Implementation (recall_lessons() — 6th param + SET LOCAL):**
```sql
-- New signature (DROP + CREATE required — adds param):
CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT           DEFAULT 10,
    role_filter       TEXT          DEFAULT NULL,
    project_id_filter INT           DEFAULT NULL,
    query_text        TEXT          DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ   DEFAULT NULL  -- NEW
)
...
-- Before delegating to recall_hybrid():
IF as_of_ts IS NOT NULL THEN
    PERFORM set_config('pgmnemo.as_of_timestamp',
                       as_of_ts::TEXT, TRUE);   -- TRUE = transaction-local
END IF;
```

| Criterion | Assessment |
|-----------|-----------|
| recall_hybrid() body changes | **Minimal** — DECLARE + GUC read + 3-line WHERE clause addition |
| CTE restructuring | **NONE** |
| Column ambiguity risk | **NONE** — no CTE renames |
| UndefinedTable risk | **NONE** — no CTE scope changes |
| Backward compat | **YES** — NULL default → existing calls unchanged |
| vector-only path (recall_lessons fallback) | Need same filter on `candidates` CTE |
| smoke_recall_hybrid.py | Should pass — no output column changes |
| GUC leakage risk | **LOW** — `set_config(..., TRUE)` is transaction-local |

**Pros:**
- Minimal diff — no structural changes to CTEs
- GUC is already the established pattern (ef_search, include_unverified, temporal_boost all use GUCs)
- Consistent API: callers who call recall_hybrid() directly can also set the GUC manually
- Avoids the v0.6.0 failure modes (no CTE restructuring = no AmbiguousColumn, no UndefinedTable)
- Both paths (hybrid + vector-only) covered by same GUC mechanism

**Cons:**
- GUC leakage if caller forgets transaction isolation (mitigated by `set_config(..., TRUE)`)
- Extra DB round-trip if connection pool reuses session across calls
- `pgmnemo.as_of_timestamp` GUC must be registered in `postgresql.conf` as a custom GUC, or use `current_setting(..., TRUE)` to tolerate undefined
- The GUC-only path means `recall_hybrid()` callers cannot pass as_of_ts directly — must use SET

### Alternative 2-B: Direct parameter pass-through to recall_hybrid

Add `as_of_ts TIMESTAMPTZ DEFAULT NULL` as a 9th parameter to `recall_hybrid()` **and**
as a 6th parameter to `recall_lessons()`. recall_lessons() passes the value directly.

```sql
-- recall_hybrid() new signature:
CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    as_of_ts          TIMESTAMPTZ      DEFAULT NULL   -- NEW (9th param)
)
```

| Criterion | Assessment |
|-----------|-----------|
| recall_hybrid() body changes | **Minimal** — new param + 3-line WHERE clause |
| CTE restructuring | **NONE** |
| Column ambiguity risk | **NONE** |
| smoke_recall_hybrid.py | **RISK** — smoke test verifies `recall_hybrid` signature. Must update test. |
| Backward compat | **YES** — NULL default |
| recall_lessons() call site | Must pass `as_of_ts` to 9-param recall_hybrid() |
| Direct recall_hybrid() callers | **YES** — can pass as_of_ts directly |

**Pros:**
- No GUC state — cleaner functional interface
- Direct callers of recall_hybrid() get first-class support
- More explicit: function signature documents the capability

**Cons:**
- `smoke_recall_hybrid.py` tests that recall_hybrid signature accepts documented params — the new 9th param must be added to smoke assertions
- Any external callers using positional params must update (unlikely given all params have defaults)
- Slightly more complex call site in recall_lessons() router

### Alternative 2-C: Caller-side GUC only (no param addition)

Don't add any parameters. Document that callers should `SET LOCAL pgmnemo.as_of_timestamp = '2026-01-01'` before calling. recall_hybrid() reads the GUC internally.

```sql
-- Caller pattern:
BEGIN;
SET LOCAL pgmnemo.as_of_timestamp = '2026-01-15T10:00:00Z';
SELECT * FROM pgmnemo.recall_lessons(...);
COMMIT;  -- GUC resets to NULL
```

**Pros:**
- Zero changes to function signatures — no DROP, no compatibility concerns
- GUC pattern is idiomatic PostgreSQL for session-scoped configuration
- Simplest implementation

**Cons:**
- **API regression**: the production-feedback RFC explicitly requested `recall_lessons(as_of_ts := ...)` syntax for an as_of_ts injection pattern
- Forces callers to manage transaction scope for GUC isolation
- CHANGELOG v0.6.0 already documented `as_of_ts` as a parameter — removing it would be misleading
- Cannot be used with connection pools that don't support SET LOCAL isolation

**Verdict:** Does not satisfy the production-feedback RFC requirement. Out of scope.

### Recommendation for Feature 2

**Implement Alternative 2-A (GUC approach) for recall_hybrid() and add param to recall_lessons().**

Rationale:
1. Minimal diff = minimal risk. The v0.6.0 failure was CTE restructuring, not the GUC mechanism.
2. Consistent with existing GUC patterns in the codebase.
3. The adopter's pattern sets the GUC before calling — this is already the downstream integration pattern.
4. smoke_recall_hybrid.py output column assertions unchanged.

**CRITICAL implementation guard:** Do NOT rename, restructure, or add CTEs to `recall_hybrid()`. The only body changes are:
- DECLARE `_as_of_ts TIMESTAMPTZ`
- Read GUC in BEGIN block (wrapped in EXCEPTION WHEN OTHERS)
- Add AND clause to raw_candidates WHERE predicate (both dense branch already has filter, BM25 branch also)

For the vector-only path in recall_lessons() (when hybrid is disabled), the same `as_of_ts`
filter must be added to the `candidates` CTE: `AND (_as_of_ts IS NULL OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))`.

---

## 3. Feature 3 — Stress Test (Issue #29): Implementation Alternatives

### Background

Issue #29 requests `recall_lessons()` performance data at 100K/1M/10M rows.
Required outputs: query latency (p50/p95/p99) and memory footprint at each scale.
No existing stress test infrastructure in the repo.

### Alternative 3-A: Pure SQL synthetic corpus via GENERATE_SERIES (RECOMMENDED)

Generate synthetic `agent_lesson` rows directly in PostgreSQL using `INSERT ... SELECT generate_series(...)`.
Embeddings are random unit vectors (generated via `array_fill + normalize` or cast from random arrays).
BM25/tsvector populated from a fixed vocabulary pool.

```sql
-- Prototype: insert 100K rows
INSERT INTO pgmnemo.agent_lesson (role, project_id, topic, lesson_text, importance,
                                  embedding, commit_sha, verified_at)
SELECT
    'stress_' || (i % 10),
    (i % 5) + 1,
    'topic_' || (i % 1000),
    'lesson text for item ' || i || ' about topic ' || (i % 1000),
    (1 + (i % 5))::SMALLINT,
    -- Random unit vector (1024-dim): approximate by scaling random floats
    (array_agg(random()::FLOAT4)::vector(1024))  -- requires custom generation
    ,
    'sha_' || i,
    NOW()
FROM generate_series(1, 100000) AS i;
```

Script: `benchmarks/scripts/stress_recall.py` — Python script that:
1. Connects to `pgmnemo-bench` DB
2. Seeds synthetic corpus at 100K / 1M / 10M scale (each independently)
3. Generates query embeddings (random unit vectors)
4. Runs recall_lessons() N=100 times per scale, measures latency
5. Collects `pg_stat_user_functions` for memory proxy
6. Emits `benchmarks/gate/v0.6.1-stress.json` with p50/p95/p99 per scale

| Criterion | Assessment |
|-----------|-----------|
| Infrastructure req | pgvector/pgvector:pg17 container (already used for LME bench) |
| Embedding quality | Random vectors — acceptable for latency stress, not recall quality |
| Data volume at 10M | ~10M × 1024 × 4 bytes = 40GB (HNSW index may take 8–20GB) |
| Execution time | 100K: ~5 min; 1M: ~60 min; 10M: may require distributed or skip |
| External deps | psycopg2, numpy (minimal) |

**Pros:**
- No external corpus required — fully self-contained
- Reproducible across environments
- Scales to 1M quickly; 10M feasible on a dedicated bench box
- Generates valid `tsvector` and vector embeddings for realistic query plans

**Cons:**
- Random vectors don't represent real recall distributions — latency numbers are realistic but quality numbers are not meaningful
- 10M rows requires ~40GB disk for embeddings alone — may exceed CI environment
- HNSW build at 10M takes 2–4 hours → CI use requires pre-built snapshot

### Alternative 3-B: Scaled LongMemEval corpus (repeat + jitter)

Use the existing LongMemEval-S corpus (500 sessions, ~50K segments with bge-m3 embeddings)
and repeat it N times with small random jitter to reach 100K/1M/10M rows.

```python
# Repeat 500-session corpus ×200 = 100K rows, ×2000 = 1M, ×20000 = 10M
for replica_id in range(n_replicas):
    for row in base_corpus:
        insert_with_jitter(row, jitter_magnitude=0.01)
```

**Pros:**
- Real embeddings from bge-m3 — plausible semantic structure
- Re-uses existing data pipeline and embeddings infrastructure
- Can test recall quality degradation with scale (not just latency)

**Cons:**
- Requires the LongMemEval bge-m3 embeddings to be pre-computed and loaded (~277 MB JSON)
- "Jittered duplicates" are not realistic — recall quality numbers are meaningless
- 10M rows × 4KB per row ≈ 40GB — same infrastructure problem as 3-A
- Much more complex to set up in CI

### Alternative 3-C: pg_regress synthetic stress (test file)

Add a pg_regress test `stress_recall.sql` that inserts 10K rows (not 100K+) and measures
`EXPLAIN (ANALYZE, BUFFERS)` output to verify index usage and timing structure.
A separate `scripts/stress_recall_large.py` does the 100K/1M/10M run on the bench host.

| Criterion | Assessment |
|-----------|-----------|
| CI integration | YES — small (10K rows) fits in pg_regress time budget |
| Scale coverage | Partial — CI covers 10K; large-scale numbers from bench host only |
| Benchmark output | EXPLAIN ANALYZE + custom timing in Python script |
| External deps | None for pg_regress; psycopg2 + numpy for large-scale script |

**Pros:**
- Splits concerns: CI verifies index usage; bench host provides timing numbers
- pg_regress 10K stress fits in <30s (acceptable for CI)
- Large-scale Python script runs only on bench host, not CI

**Cons:**
- Does not produce 100K/1M/10M timing in CI
- Two-tier approach increases complexity
- Must document clearly which numbers come from which test

### Recommendation for Feature 3

**Implement Alternative 3-A (pure SQL) with 3-C's two-tier split:**
- `extension/expected/stress_recall.out` + `extension/sql/stress_recall.sql` for pg_regress at 10K
- `benchmarks/scripts/stress_recall_large.py` for 100K/1M/10M on bench host
- Output stored in `benchmarks/gate/v0.6.1-stress.json`

**10M mitigation:** if bench DB <40GB free space, report 10M as "extrapolated from 1M linear regression with documented HNSW O(n log n) caveat."

---

## 4. Real-DB Bench Infrastructure (Headline Gate)

### 4.1 Requirements

```
PostgreSQL 17 + pgvector:    docker run -d --name pgmnemo-bench -p 15432:5432 \
                              -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench \
                              -e POSTGRES_DB=bench pgvector/pgvector:pg17
MLX bge-m3 embedder:         host.docker.internal:9200 (LaunchAgent already running)
LongMemEval corpus:          benchmarks/data/longmemeval/longmemeval_s_cleaned.json (277 MB)
                             sha256=d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442
pgmnemo v0.6.1 extension:    Apply pgmnemo--0.5.1--0.6.1.sql after bench DB starts
Bench script:                benchmarks/scripts/run_longmemeval_pgmnemo_full.py (exists)
Significance test:           scripts/significance_test_extended.py (exists)
```

### 4.2 Gate: All-or-Nothing

The release gate is **all-or-nothing** (from task spec):
- LME-S recall@10: p_corr < 0.05 AND Δrecall@10 ≥ +1pp vs v0.5.1 baseline (0.9334)
- LoCoMo session recall@10: ≥ 0.7994 (must not regress)
- pg_regress: 14/14 PASS + smoke_recall_hybrid.py PASS
- Stress test: timing numbers published for 100K/1M/10M

If real-DB bench cannot run → DO NOT SHIP, defer to v0.6.2.

### 4.3 Why Real-DB vs Simulation Differ

Simulation (TF-IDF proxy): rank correlation between dense and sparse signals ρ ≈ 0.85
(both lexical, same vocabulary). RRF benefit minimal — fusion and RRF produce nearly
identical rankings.

Real-DB (bge-m3 + BM25): rank correlation ρ ≈ 0.35–0.55 (semantic vs lexical). RRF
benefit substantial — rank disagreement means RRF enforces consensus where signals conflict.

The −2.40pp simulation result is therefore a conservative lower bound. Expected real-DB
result: +0.5 to +2pp (literature +2–4pp, discounted for pgmnemo corpus characteristics).

### 4.4 Bench Run Order

1. Baseline: apply `pgmnemo--0.6.0.sql` (current state), run bench → establishes v0.5.1 comparison baseline
2. Fix-A A-scale: apply `pgmnemo--0.6.1.sql`, run bench → compare vs baseline
3. Significance test: `python scripts/significance_test_extended.py baseline/metrics.json fix_a/metrics.json`
4. If PASS: record in `benchmarks/gate/v0.6.1.json`, proceed to PLAN
5. If FAIL (Δrecall@10 < +1pp): test A-pure variant. If also FAIL: close Fix-A as won't-fix, ship v0.6.1 with as_of_ts + stress only

---

## 5. Pre-Tag Checklist Analysis

Based on v0.6.0 mistakes and task spec requirements:

| Item | Risk | Notes |
|------|------|-------|
| Fresh-install `pgmnemo--0.6.1.sql` | **HIGH** (killed v0.6.0 attempt #3) | Must squash ALL v0.5.1 + v0.6.0 + v0.6.1 changes |
| `pgmnemo--0.5.1--0.6.0.sql` already exists | N/A | v0.6.1 upgrade path is `pgmnemo--0.6.0--0.6.1.sql` |
| pg_regress fixtures with `ALTER EXTENSION UPDATE TO` | **MEDIUM** | grep existing fixtures; update version strings |
| Makefile DATA list | **LOW** | Add `pgmnemo--0.6.0--0.6.1.sql` and `pgmnemo--0.6.1.sql` |
| smoke_recall_hybrid.py | **HIGH** | Must pass before any bench run |
| benchmarks/gate/v0.6.1.json | **HIGH** | Gate snapshot required before tag |

---

## 6. CHANGELOG.md Correction Note

The v0.6.0 CHANGELOG has an internal inconsistency:
- "Changed (behavior): recall_hybrid() temporal filter..." — incorrectly claims as_of_ts shipped
- "Note on bitemporal as_of_ts (also deferred)..." — correctly says deferred
- "Added: recall_lessons() — as_of_ts TIMESTAMPTZ DEFAULT NULL" — incorrectly claims it was added

**The actual v0.6.0.sql confirms `as_of_ts` was NOT shipped.** The CHANGELOG body section
"Changed (behavior)" and "Added" bullets describing as_of_ts are editorial errors from
revising the CHANGELOG after the deferral decision. v0.6.1 CHANGELOG entry should be
the authoritative first mention of as_of_ts as a shipped feature.

The v0.6.0 CHANGELOG should be corrected (strikethrough or NOTE) in v0.6.1 editorial pass.

---

## 7. Evidence Grades (D79 §3.3)

| Claim | Grade |
|-------|-------|
| A-scale expected +0.5 to +2pp on real-DB | PRELIMINARY (literature-derived, unconfirmed on this corpus) |
| A-scale max aux override risk = 0.006 << 0.016 (rrf delta) | STRONG (analytical proof in INVESTIGATION §4.3) |
| GUC approach avoids v0.6.0 CTE regression | MODERATE (analytical: different code path = different failure mode) |
| as_of_ts v0.6.0 failure cause = CTE restructuring | STRONG (confirmed by INVESTIGATION + smoke test output) |
| Stress test 100K/1M feasible in pgvector:pg17 | MODERATE (similar benchmarks exist; 10M requires caveat) |
| Real-DB bench required for Fix-A gate | STRONG (simulation proxy invalid per §1.3 rank correlation analysis) |

---

## 8. Decision Summary

| Feature | Alternative | Decision |
|---------|-------------|----------|
| RRF Fix-A | **A-scale** (1-A) | Implement; gate on real-DB bench |
| as_of_ts | **GUC + 6th param** (2-A) | Implement; minimal diff to v0.5.1 body |
| Stress test | **Pure SQL + two-tier** (3-A + 3-C split) | Implement; 10M extrapolated if disk limited |
| Real-DB bench | bge-m3 at localhost:15432 | **Prerequisite for all** — Fix-A cannot ship without it |

**If real-DB bench infrastructure unavailable when IMPLEMENT starts:**  
- Ship as_of_ts + stress test as v0.6.1  
- Defer Fix-A to v0.6.2 (as per task spec gate)
