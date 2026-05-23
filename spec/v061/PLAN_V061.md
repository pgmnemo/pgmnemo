---
date: 2026-05-23
author: chief_architect (id=86)
task_id: SWDEV-260523-1-PLAN
phase: PLAN
parent_dag: SWDEV-260523-1
input: spec/v061/RESEARCH_V061.md
status: complete
---

# pgmnemo v0.6.1 — Implementation Plan

**Version:** 0.6.1 (upgrade from 0.6.0)  
**Predecessor:** v0.6.0 (2026-05-22) — `recall_lessons()` / `recall_hybrid()` byte-identical to v0.5.1  
**Baseline recall@10 (LME-S, bge-m3):** 0.9334  
**Baseline recall@10 (LoCoMo session):** 0.7994 (MUST NOT REGRESS)

---

## 0. Scope Summary

Three independently deliverable work items, all gated on a single real-DB bench run:

| # | Feature | SQL Δ | Risk |
|---|---------|-------|------|
| F1 | RRF Fix-A (A-scale) | ~12 lines in `recall_hybrid()` | Medium — gated on bench |
| F2 | `as_of_ts` param on `recall_lessons()` | ~20 lines across two functions | Low — additive, NULL default |
| F3 | Stress test #29 | New `benchmarks/` script + pg_regress fixture | Low — no prod changes |

**Upgrade path:** `extension/pgmnemo--0.6.0--0.6.1.sql`  
**Fresh install:** `extension/pgmnemo--0.6.1.sql` (must squash all history — this is mandatory)

---

## 1. Feature F1 — RRF Fix-A (A-scale)

### 1.1 What changes

Only `recall_hybrid()` body. No signature change, no CTE structural change, no new params.

**File:** `extension/pgmnemo--0.6.0--0.6.1.sql` (upgrade migration)  
**Function:** `pgmnemo.recall_hybrid(vector, TEXT, INT, TEXT, INT, FLOAT8, FLOAT8, INT)`  
**Operation:** `CREATE OR REPLACE` (no DROP needed — signature unchanged)

### 1.2 Precise SQL diff

**DECLARE block — add 1 constant:**
```sql
-- ADD after existing DECLARE vars:
_aux_scale        CONSTANT DOUBLE PRECISION := 0.01726;
-- Derivation: (vec_w + bm25_w)/(rrf_k+1) / fusion_score_typical
--             = (0.8/61) / 0.76 ≈ 0.01726
-- Purpose: scales aux terms to same order of magnitude as rrf_diag
-- so aux max contribution (0.006) stays below rrf_diag adjacent-rank
-- delta (0.016), preventing aux override of retrieval signal.
```

**anchors CTE — change ORDER BY (1 line):**
```sql
-- BEFORE:
anchors AS (
    SELECT id
    FROM scored
    ORDER BY fusion_score DESC
    LIMIT 5
),
-- AFTER:
anchors AS (
    SELECT id
    FROM scored
    ORDER BY rrf_diag DESC  -- Fix-A: anchor by rank-based signal, not linear fusion
    LIMIT 5
),
```

**Final SELECT — score column (change 2 occurrences: SELECT + ORDER BY):**
```sql
-- BEFORE (both SELECT score column and ORDER BY):
    s.fusion_score
  + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
  + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                1.0
            ))::DOUBLE PRECISION
  + 0.05 * (CASE
              WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
              WHEN s.commit_sha IS NOT NULL                               THEN 0.4
              ELSE                                                             0.0
            END)::DOUBLE PRECISION
  + _graph_weight * COALESCE(gp.proximity, 0.0)

-- AFTER (both occurrences):
    s.rrf_diag  -- Fix-A A-scale: primary signal
  + _aux_scale * 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
  + _aux_scale * 0.05 * GREATEST(0.0, 1.0 - LEAST(
                             EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0),
                             1.0
                         ))::DOUBLE PRECISION
  + _aux_scale * 0.05 * (CASE
                           WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                           WHEN s.commit_sha IS NOT NULL                               THEN 0.4
                           ELSE                                                             0.0
                         END)::DOUBLE PRECISION
  + _aux_scale * _graph_weight * COALESCE(gp.proximity, 0.0)
```

**COMMENT update (1 line):**
```sql
COMMENT ON FUNCTION pgmnemo.recall_hybrid(...) IS
    -- prepend: 'v0.6.1 Fix-A (A-scale): rrf_diag as primary ranking signal; '
    --          'aux terms scaled by _aux_scale=0.01726 (max aux contribution 0.006 << rrf_delta 0.016). '
```

### 1.3 Invariants to verify

- `smoke_recall_hybrid.py` output column set unchanged — ✅ (rrf_score still returned, score formula is different value only)
- `_rrf_norm_denom` variable NOT introduced — ✅ (A-norm rejected; we use rrf_diag directly, no normalization needed)
- No CTE restructuring — ✅ (raw_candidates, rrf_ranked, scored, anchors, graph_walk, graph_proximity all unchanged in structure)
- `rrf_diag` column exists in `scored` CTE — ✅ (already computed in `scored` as diagnostic; now also used for ranking)

### 1.4 Lines changed: ~12 (1 DECLARE + 1 anchors ORDER BY + 2×5 score lines + 1 COMMENT)

---

## 2. Feature F2 — as_of_ts Parameter

### 2.1 What changes

Two functions modified:
1. `recall_hybrid()`: add GUC read + WHERE clause filter (~6 lines)
2. `recall_lessons()`: add 6th param + GUC set + vector-only path filter (~14 lines)

### 2.2 recall_hybrid() — GUC approach (CRITICAL: no CTE restructuring)

**DECLARE block — add 1 variable:**
```sql
_as_of_ts   TIMESTAMPTZ;
```

**BEGIN block — add GUC read (after include_unverified GUC read):**
```sql
-- as_of_ts: point-in-time temporal filter (v0.6.1).
-- Set by recall_lessons(as_of_ts := ...) via set_config().
-- Callers may also SET LOCAL pgmnemo.as_of_timestamp = '...' directly.
BEGIN
    _as_of_ts := NULLIF(
        current_setting('pgmnemo.as_of_timestamp', TRUE), ''
    )::TIMESTAMPTZ;
EXCEPTION WHEN OTHERS THEN
    _as_of_ts := NULL;
END;
```

**raw_candidates WHERE clause — add 1 temporal condition (after existing conditions, BEFORE the OR union):**
```sql
-- BEFORE (last line of WHERE):
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
          )

-- AFTER:
          AND (_as_of_ts IS NULL
               OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
          AND (
              (_has_vec  AND al.embedding   IS NOT NULL)
           OR (_has_text AND al.lesson_tsv @@ _tsquery)
          )
```

**COMMENT update**: add note about `pgmnemo.as_of_timestamp` GUC.

### 2.3 recall_lessons() — new 6th param

**Signature change requires DROP + CREATE** (new param = new overload, old overload must be removed):
```sql
DROP FUNCTION IF EXISTS pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT);

CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT           DEFAULT 10,
    role_filter       TEXT          DEFAULT NULL,
    project_id_filter INT           DEFAULT NULL,
    query_text        TEXT          DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ   DEFAULT NULL   -- NEW v0.6.1
)
```

**BEGIN block — set GUC before delegating to recall_hybrid():**
```sql
-- Insert AFTER the disable_hybrid GUC read, BEFORE the hybrid delegation block:
IF as_of_ts IS NOT NULL THEN
    -- Set transaction-local GUC; recall_hybrid() reads it for temporal filter.
    PERFORM set_config('pgmnemo.as_of_timestamp', as_of_ts::TEXT, TRUE);
END IF;
```

**Vector-only path candidates CTE — add temporal filter:**
In the vector-only path (when hybrid is disabled or query_text is NULL), the `candidates` CTE
filters `WHERE al.is_active`. Add:
```sql
-- After: AND (_include_unverified OR al.verified_at IS NOT NULL)
-- Add:
AND (as_of_ts IS NULL
     OR (al.t_valid_from <= as_of_ts AND al.t_valid_to > as_of_ts))
```

**COMMENT update:** add note on `as_of_ts` param semantics and GUC.

### 2.4 Migration header note

```sql
-- §1  recall_hybrid() — Fix-A A-scale: rrf_diag as primary ranking signal
--                       + as_of_ts temporal filter via pgmnemo.as_of_timestamp GUC
-- §2  recall_lessons() — as_of_ts TIMESTAMPTZ DEFAULT NULL (6th param, v0.6.1)
--                        Point-in-time recall: restricts to lessons valid at as_of_ts.
--                        Backward-compatible: NULL default preserves v0.6.0 behavior.
```

### 2.5 GUC transaction-local safety

`set_config('pgmnemo.as_of_timestamp', value, TRUE)` — the third arg `TRUE` means the GUC
resets at transaction end (equivalent to SET LOCAL). If the caller's connection pool reuses
connections across transactions without RESET, the GUC is correctly cleared at COMMIT/ROLLBACK.
No leakage risk for standard usage.

### 2.6 Lines changed: ~20 (6 in recall_hybrid + 14 in recall_lessons)

---

## 3. Feature F3 — Stress Test (Issue #29)

### 3.1 Files to create

| File | Purpose |
|------|---------|
| `benchmarks/scripts/stress_recall_large.py` | 100K/1M/10M bench on pgmnemo-bench host |
| `extension/sql/stress_recall.sql` | pg_regress fixture (10K rows, verifies HNSW index usage) |
| `extension/expected/stress_recall.out` | Expected output for pg_regress |
| `benchmarks/gate/v0.6.1-stress.json` | Timing results (written by stress_recall_large.py at run time) |

### 3.2 stress_recall_large.py design

```
Input:  DATABASE_URL (env), scale in [100_000, 1_000_000, 10_000_000]
Steps:
  1. Drop + recreate schema (isolated from production data)
  2. Insert N rows with random unit vectors (1024-dim) and synthetic tsvectors
  3. Build HNSW index (CREATE INDEX IF NOT EXISTS)
  4. Run recall_lessons() N=50 queries, record wall-clock
  5. Collect pg_stat_user_functions for call count + total_time
  6. Record p50/p95/p99 latency + peak shared_buffers hit ratio
  7. Write benchmarks/gate/v0.6.1-stress.json

10M caveat: if disk < 40GB, extrapolate from 1M with documented O(n log n) HNSW note.
```

**Synthetic vector generation (no external dep, pure Python):**
```python
import random, math
def random_unit_vector(dim=1024):
    v = [random.gauss(0, 1) for _ in range(dim)]
    norm = math.sqrt(sum(x*x for x in v))
    return [x/norm for x in v]
```

### 3.3 pg_regress fixture (extension/sql/stress_recall.sql)

```sql
-- stress_recall.sql: verifies HNSW index used at N=10K, no full-seq-scan
SET pgmnemo.include_unverified = 'true';
-- ... insert 10K synthetic rows ...
-- ... EXPLAIN (FORMAT JSON) SELECT ... (assert Index Scan) ...
-- Cleanup: DELETE WHERE role = 'stress_test'
```

Expected output in `extension/expected/stress_recall.out` is deterministic (EXPLAIN structure,
not timing numbers).

### 3.4 Makefile addition

```makefile
# In REGRESS line, append:
REGRESS = ... bitemporality_smoke stress_recall
```

---

## 4. Real-DB Bench Infrastructure

### 4.1 Bench container setup

```bash
# Start bench DB (one-time)
docker run -d --name pgmnemo-bench \
  -p 15432:5432 \
  -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench \
  pgvector/pgvector:pg17

# Apply fresh v0.6.1 install
psql "host=localhost port=15432 dbname=bench user=bench password=bench" \
  -f extension/pgmnemo--0.6.1.sql

# Verify extension loaded
psql "..." -c "SELECT pgmnemo.version();"
```

### 4.2 Bench run sequence (gate: all-or-nothing)

```bash
# Step 1: Baseline run (v0.6.0 = v0.5.1 ordering = fusion_score)
DATABASE_URL="host=localhost port=15432 ..." \
MLX_EMBED_HOST="host.docker.internal:9200" \
python benchmarks/scripts/run_longmemeval_pgmnemo_full.py \
  --variant baseline \
  --out-dir benchmarks/longmemeval/results/v061_realdb_baseline

# Step 2: Fix-A A-scale run (v0.6.1 ordering = rrf_diag + scaled aux)
DATABASE_URL="..." \
python benchmarks/scripts/run_longmemeval_pgmnemo_full.py \
  --variant fix_a_ascale \
  --out-dir benchmarks/longmemeval/results/v061_realdb_fix_a

# Step 3: Significance test (gate)
python scripts/significance_test_extended.py \
  benchmarks/longmemeval/results/v061_realdb_baseline/metrics.json \
  benchmarks/longmemeval/results/v061_realdb_fix_a/metrics.json \
  --regression-pp 1.0

# Gate criteria:
# - exit 1 (significant improvement): PASS — ship Fix-A
# - exit 0 (neutral): FAIL — do NOT ship Fix-A; ship as_of_ts + stress only as v0.6.1
# - exit 2 (regression): FAIL — A-pure fallback test; if also fails, close Fix-A as won't-fix

# Step 4: LoCoMo regression check (optional but recommended)
python benchmarks/scripts/run_locomo_bench_session.py \
  --pgmnemo-version 0.6.1 \
  --out-dir benchmarks/locomo/results/v061_session
# Gate: recall@10 >= 0.7994
```

### 4.3 MLX bge-m3 integration

The bench script `run_longmemeval_pgmnemo_full.py` currently uses `SentenceTransformer` directly.
It needs to be adapted to call the MLX host at `host.docker.internal:9200` instead of loading
the model locally. **This is not a blocker** — the bench runs on macOS host with direct Python,
not inside Docker. The SentenceTransformer path should work directly on macOS.

If running inside Docker/container: use `requests.post("http://host.docker.internal:9200/embed", ...)`.

### 4.4 Bench fallback if Fix-A fails gate

If `significance_test_extended.py` exits 0 or 2 on Fix-A A-scale:
1. Test A-pure (`ORDER BY s.rrf_diag DESC` with no aux at all)
2. If A-pure also fails: close Fix-A as `won't-fix` for this release
3. Ship v0.6.1 with F2 (as_of_ts) + F3 (stress test) only
4. Record failure in `benchmarks/gate/v0.6.1.json` with verdict `FIX_A_DEFERRED`

---

## 5. Migration File Structure

### 5.1 Upgrade script: `extension/pgmnemo--0.6.0--0.6.1.sql`

```
Header comment (§0–§2 scope)
§1  recall_hybrid() — Fix-A A-scale (CREATE OR REPLACE — no DROP)
§2  recall_lessons() — as_of_ts 6th param (DROP old signature, CREATE new)
§3  COMMENT updates for both functions
```

Total estimated length: ~100 lines (vs v0.6.0 upgrade at 229 lines)

### 5.2 Fresh install: `extension/pgmnemo--0.6.1.sql`

**MANDATORY: must squash ALL changes** from v0.0.1 → v0.6.1 into a single coherent script.
**Process:** copy `pgmnemo--0.6.0.sql` as base, then apply F1 and F2 changes inline.

This is the single most likely failure point (killed v0.6.0 attempt #3). Checklist:
- [ ] Fresh `DROP SCHEMA pgmnemo CASCADE; CREATE EXTENSION pgmnemo;` passes smoke test
- [ ] `SELECT pgmnemo.version()` returns `'0.6.1'`
- [ ] `SELECT pgmnemo.recall_lessons(NULL::vector(1024), 5, NULL, NULL, NULL, NULL)` succeeds

### 5.3 Makefile DATA list additions

```makefile
DATA = ...
       pgmnemo--0.5.1.sql \
       pgmnemo--0.5.1--0.6.0.sql \
       pgmnemo--0.6.0.sql \
       pgmnemo--0.6.0--0.6.1.sql \   # NEW
       pgmnemo--0.6.1.sql             # NEW
```

---

## 6. pg_regress Fixtures

### 6.1 New fixture for as_of_ts

**File:** `extension/sql/as_of_ts.sql`  
**Expected:** `extension/expected/as_of_ts.out`

Test cases:
1. `recall_lessons(emb, 10, NULL, NULL, NULL, NULL)` — 6th param NULL, behavior identical to v0.6.0
2. `recall_lessons(emb, 10, NULL, NULL, NULL, '2026-01-01T00:00:00Z'::TIMESTAMPTZ)` — only returns rows valid at that time (0 rows on fresh corpus = expected)
3. Insert row with `t_valid_from = '2026-01-01', t_valid_to = '2026-06-01'`; query with `as_of_ts = '2026-03-01'` → returns row; with `as_of_ts = '2025-12-31'` → 0 rows

### 6.2 Existing fixture updates (ALTER EXTENSION version string)

```bash
# Grep for fixtures that test ALTER EXTENSION version:
grep -r "ALTER EXTENSION pgmnemo UPDATE TO" extension/sql/ extension/expected/
```

Any fixture with hardcoded version string `'0.6.0'` must be updated to `'0.6.1'`.
Expected: likely `bitemporality_smoke.sql` and `version.sql`.

**version.sql / version.out:** must show `0.6.1`.

---

## 7. Pre-Tag Checklist (sequential — all before git tag)

Execute in this order to prevent state contamination between steps:

```
□ Step 1: SQL implementation
  □ Write pgmnemo--0.6.0--0.6.1.sql (§1 Fix-A, §2 as_of_ts)
  □ Write pgmnemo--0.6.1.sql (squashed fresh install)
  □ Update extension/pgmnemo.control: default_version = '0.6.1'
  □ Update extension/Makefile: DATA + REGRESS lists

□ Step 2: pg_regress
  □ Write extension/sql/as_of_ts.sql + expected/as_of_ts.out
  □ Write extension/sql/stress_recall.sql + expected/stress_recall.out
  □ Run: make installcheck  → 16/16 PASS (14 existing + 2 new)
  □ Fix any version string mismatches in existing fixtures

□ Step 3: Smoke test (MUST pass before bench)
  □ DATABASE_URL=postgresql://bench:bench@localhost:15432/bench \
      python3 scripts/smoke_recall_hybrid.py
  □ All assertions PASS → proceed
  □ Any FAIL → fix root cause, never bypass

□ Step 4: Real-DB bench
  □ docker start pgmnemo-bench (or docker run fresh)
  □ Apply pgmnemo--0.6.1.sql to bench DB
  □ Run baseline bench → benchmarks/longmemeval/results/v061_realdb_baseline/
  □ Run Fix-A bench → benchmarks/longmemeval/results/v061_realdb_fix_a/
  □ Run significance_test_extended.py → verdict
  □ If exit 2 (regression): run A-pure variant
  □ Record result in benchmarks/gate/v0.6.1.json

□ Step 5: Stress test
  □ Run stress_recall_large.py at 100K → record timing
  □ Run at 1M → record timing
  □ Run at 10M (or extrapolate) → record timing
  □ Write benchmarks/gate/v0.6.1-stress.json

□ Step 6: Documentation & metadata
  □ META.json: version = '0.6.1'
  □ pgmnemo_mcp/pyproject.toml: version = '0.6.1'
  □ CHANGELOG.md: [0.6.1] entry (>200 chars, with real bench numbers)
    ALSO: correct v0.6.0 entry (remove incorrect as_of_ts "Added" bullet — it wasn't shipped)
  □ README.md: badge bump + recent-updates note
  □ docs/SQL_REFERENCE.md: recall_lessons() 6th param, recall_hybrid() comment
  □ docs/release_notes/v0.6.1_telegram.md (≤3500 chars)
  □ docs/release_notes/v0.6.1_announcement.md (optional)
  □ benchmarks/METRICS_BY_VERSION.md: v0.6.1 rows in Tables 2+3

□ Step 7: Final verification
  □ make installcheck → 16/16 PASS
  □ smoke_recall_hybrid.py → PASS
  □ benchmarks/gate/v0.6.1.json exists with bench results
  □ benchmarks/gate/v0.6.1-stress.json exists
  □ pgmnemo.control default_version = '0.6.1'
  □ git tag v0.6.1
  □ git push origin main --tags
```

---

## 8. Cost & Complexity Estimates

### 8.1 Implementation complexity

| Work item | Lines of SQL | Complexity | Risk |
|-----------|-------------|------------|------|
| F1 recall_hybrid() Fix-A | ~12 | Low — constant swap | Medium (gated on bench) |
| F2 recall_lessons() as_of_ts | ~14 | Low — additive param | Low — NULL default |
| F2 recall_hybrid() GUC read | ~6 | Low | Low |
| F3 stress_recall_large.py | ~120 | Medium — bench tooling | Low |
| F3 pg_regress stress fixture | ~40 | Low | Low |
| Fresh install squash | copy+patch | Medium — error-prone | **HIGH — see §7 Step 1** |
| CHANGELOG + docs | — | Low | Low |
| **Total** | **~192 SQL + ~120 Python** | | |

### 8.2 Turn/cost estimate

| Phase | Model | Est. turns | Est. cost |
|-------|-------|-----------|-----------|
| IMPLEMENT (SQL + stress script) | Sonnet | 18–25 | $0.80–1.20 |
| Bench run (real-DB, 2 variants) | N/A (tooling) | — | ~$0 (local) |
| CODE_REVIEW | Sonnet | 8–12 | $0.40–0.60 |
| QA + SHIP | Haiku | 6–10 | $0.10–0.20 |
| **Total** | | **32–47** | **$1.30–2.00** |

Note: budget ~$15 includes bench infra time on founder's machine — not agent turns.

### 8.3 Critical path

```
IMPLEMENT → smoke_recall_hybrid.py PASS → real-DB bench → gate verdict → CHANGELOG → tag
              ↑ blocking              ↑ blocking on bench infra availability
```

If bench infra (localhost:15432 + bge-m3) is unavailable at IMPLEMENT time:
- Ship F2 + F3 as v0.6.1 (no Fix-A) immediately
- Defer Fix-A to v0.6.2 with bench gate required

---

## 9. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Fresh install squash breaks smoke test | HIGH | Test with `DROP SCHEMA pgmnemo CASCADE` → `CREATE EXTENSION pgmnemo` first |
| v0.6.0 CTE regression repeats in as_of_ts | HIGH | **No CTE restructuring** — only WHERE clause addition + DECLARE var |
| Fix-A fails gate (Δ < +1pp) | MEDIUM | A-pure fallback test; worst case: ship F2+F3 only |
| `recall_lessons_pooled()` not updated | LOW | Uses `recall_lessons(emb, k, NULL, app_id, NULL)` — 5-param call, still works after DROP+CREATE (DROP removes 5-param sig, new 6-param sig with NULL default covers it — BUT 5-param callers still fail after DROP) |
| `recall_lessons_pooled()` call site breakage | MEDIUM | **MUST update**: `recall_lessons_pooled()` calls `recall_lessons(emb, k, NULL, app_id, NULL)` — needs 6th arg `NULL` after param addition |
| GUC leakage between transactions | LOW | `set_config(..., TRUE)` resets at transaction boundary |
| Stress test 10M disk overflow | LOW | Extrapolate from 1M with documented caveat in JSON |

### 9.1 recall_lessons_pooled() fix (critical)

After DROP+CREATE of `recall_lessons(vector, INT, TEXT, INT, TEXT)`, the old 5-param overload
is gone. `recall_lessons_pooled()` calls it with 5 positional args — this will fail after the upgrade.

**Fix (must include in §2 of upgrade script):**
```sql
CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons_pooled(
    query_embedding vector(1024),
    k               INT DEFAULT 10,
    app_id          INT DEFAULT NULL
)
RETURNS TABLE (...)
LANGUAGE plpgsql STABLE PARALLEL SAFE
AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM pgmnemo.recall_lessons(query_embedding, k, NULL, app_id, NULL, NULL);
    --                                                                        ^^^^ ADD
END;
$$;
```

---

## 10. Implementation Sequence (for IMPLEMENT agent)

Execute in this strict order:

1. **Create upgrade script** `extension/pgmnemo--0.6.0--0.6.1.sql`:
   - Header with §0–§2 scope
   - §1: `recall_hybrid()` — add `_aux_scale` + anchors ORDER BY + score formula (CREATE OR REPLACE)
   - §2: `recall_lessons()` — DROP 5-param + CREATE 6-param + GUC set + vector-only filter; update `recall_lessons_pooled()` to pass 6th NULL arg
   - §3: COMMENT updates

2. **Create squashed fresh install** `extension/pgmnemo--0.6.1.sql`:
   - Start from `pgmnemo--0.6.0.sql` (copy)
   - Apply F1 changes inline to `recall_hybrid()` definition
   - Apply F2 changes inline to `recall_lessons()` definition (and pooled variant)
   - Update all version references from `0.6.0` → `0.6.1`

3. **Update `pgmnemo.control`**: `default_version = '0.6.1'`

4. **Update `extension/Makefile`**: add two new entries to DATA list

5. **Write pg_regress fixtures**:
   - `extension/sql/as_of_ts.sql` + `extension/expected/as_of_ts.out`
   - `extension/sql/stress_recall.sql` + `extension/expected/stress_recall.out`
   - Add `as_of_ts stress_recall` to REGRESS in Makefile

6. **Update version strings** in pg_regress fixtures that hardcode version (grep first)

7. **Write `benchmarks/scripts/stress_recall_large.py`**

8. **Run smoke test**: `DATABASE_URL=... python3 scripts/smoke_recall_hybrid.py`  
   → MUST PASS before proceeding

9. **Run pg_regress**: `make installcheck` → 16/16 PASS

10. **Run real-DB bench** (requires localhost:15432):
    - Apply `pgmnemo--0.6.1.sql` to bench DB
    - Run baseline + Fix-A bench scripts
    - Run `significance_test_extended.py`
    - Write `benchmarks/gate/v0.6.1.json`

11. **Run stress bench** → write `benchmarks/gate/v0.6.1-stress.json`

12. **Update docs + metadata** (CHANGELOG, META.json, pyproject.toml, README, SQL_REFERENCE)

13. **Final verification** → tag + push

---

## Appendix A: Definition of Done

- [ ] `make installcheck` → ≥14 PASS (existing) + 2 new as_of_ts + stress_recall = 16 total
- [ ] `scripts/smoke_recall_hybrid.py` → exit 0
- [ ] `benchmarks/gate/v0.6.1.json` exists with `"bench_db_tested": true`
- [ ] `benchmarks/gate/v0.6.1-stress.json` exists with p50/p95/p99 for 100K/1M rows
- [ ] `pgmnemo.control` `default_version = '0.6.1'`
- [ ] `META.json` `version = '0.6.1'`
- [ ] `pgmnemo_mcp/pyproject.toml` `version = '0.6.1'`
- [ ] CHANGELOG.md has [0.6.1] entry >200 chars with real numbers
- [ ] `docs/release_notes/v0.6.1_telegram.md` ≤3500 chars
- [ ] `git tag v0.6.1` created

## Appendix B: Rollback

If `git tag v0.6.1` is not yet created and bugs are found:

```bash
# DB rollback (users still on v0.6.0):
ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';

# Git rollback:
git tag -d v0.6.1
git push origin :refs/tags/v0.6.1
```

If tag is already pushed: create `v0.6.1.1` hotfix branch.
