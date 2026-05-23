---
date: 2026-05-23
author: chief_architect (id=86)
task_id: SWDEV-260523-2-PLAN
phase: PLAN
parent_dag: SWDEV-260523-2
input: spec/v062/RESEARCH_V062.md
base_plan: spec/v061/PLAN_V061.md (commit fb56181)
status: complete
---

# pgmnemo v0.6.2 — Implementation Plan

**Version:** 0.6.2 (upgrade from 0.6.1)  
**Predecessor:** v0.6.1 (2026-05-23) — F2 as_of_ts + F3 stress test shipped; F1 deferred (−22.44pp gate fail)  
**Baseline recall@10 (LME-S, bge-m3):** 0.9334 (v0.5.1 baseline; v0.6.2 gate: ≥ 0.9434)  
**Baseline recall@10 (LoCoMo session):** 0.7994 (MUST NOT REGRESS)

---

## 0. Delta from v0.6.1 Plan (commit fb56181)

v0.6.1 plan covered three features (F1, F2, F3). For v0.6.2:

- **F2 (as_of_ts) — SHIPPED in v0.6.1 (commit e4d640e).** No re-implementation.
- **F3 (stress test) — SHIPPED in v0.6.1 (commit e4d640e).** No re-implementation.
- **F1 (RRF Fix-A) — DEFERRED. Changed approach.**

v0.6.1 F1 used "A-scale" (ORDER BY rrf_diag with scaled aux constants). Real-DB bench
showed −22.44pp regression (0.9334 → 0.7090). Root cause: `ROW_NUMBER()` over all
candidates assigns arbitrary bm25_rank to zero-score items, corrupting RRF fusion for
sparse corpora (avg 48 segments/session, k=60). Any variant that ORDER BYs on `rrf_diag`
as computed in v0.6.1 inherits this defect.

**v0.6.2 F1 approach: sparse-safe proper RRF** (Research Alternative A).  
Key change: zero-BM25 items receive sentinel rank instead of arbitrary rank.

Budget caps increased: IMPLEMENT max_turns=200 (was 120), max_cost=$12 (was $5).

---

## 1. Scope Summary

| # | Feature | Status | v0.6.2 action |
|---|---------|--------|---------------|
| F1 | RRF Fix-A (sparse-safe) | DEFERRED from v0.6.1 | Implement with corrected semantics |
| F2 | `as_of_ts` on `recall_lessons()` | **SHIPPED v0.6.1** | Version string update only |
| F3 | Stress test #29 | **SHIPPED v0.6.1** | Version string update only |

**Upgrade path:** `extension/pgmnemo--0.6.1--0.6.2.sql`  
**Fresh install:** `extension/pgmnemo--0.6.2.sql` (must squash all history — mandatory)

---

## 2. Feature F1 — Sparse-Safe Proper RRF

### 2.1 Root cause of v0.6.1 regression (from gate file v0.6.1.json)

```
rrf_ranked CTE (v0.6.1):
    ROW_NUMBER() OVER (ORDER BY raw_bm25_score DESC NULLS LAST) AS bm25_rank
```

For a corpus with 48 lessons and query with 3 BM25 matches:
- 3 items get bm25_rank 1, 2, 3 (meaningful)
- 45 items get bm25_rank 4–48 (from tied 0.0 scores — arbitrary tie-break by internal order)

Result: high-cosine/no-BM25 answers may fall below low-cosine/BM25-matching non-answers
in RRF ranking. `fusion_score` doesn't have this bug (zero BM25 weight = 0 contribution).

### 2.2 Fix approach (PARTITION BY trick — no separate CTEs required)

**Only two CTEs change**: `rrf_ranked` and `scored`. No new CTEs. No CTE removal.

**`rrf_ranked` CTE changes:**

```sql
-- BEFORE:
rrf_ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST) AS vec_rank,
        ROW_NUMBER() OVER (ORDER BY raw_bm25_score DESC NULLS LAST) AS bm25_rank
    FROM raw_candidates
),

-- AFTER:
rrf_ranked AS (
    SELECT *,
        COUNT(*) OVER ()                                              AS n_candidates,
        ROW_NUMBER() OVER (ORDER BY raw_vec_score  DESC NULLS LAST)  AS vec_rank,
        -- Sparse-safe: only BM25-matching items get a real rank; others get NULL
        CASE WHEN raw_bm25_score > 0
             THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0)
                               ORDER BY raw_bm25_score DESC NULLS LAST)
             ELSE NULL
        END                                                           AS bm25_rank_sparse
    FROM raw_candidates
),
```

**`scored` CTE changes:**

```sql
-- BEFORE (rrf_diag line):
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + r.bm25_rank::DOUBLE PRECISION))
                AS rrf_diag,

-- AFTER:
            -- Sparse-safe RRF: absent items use sentinel = n_candidates+1 (Cormack 2009)
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION))
                AS rrf_sparse,
            -- Keep legacy rrf_diag for backward-compat output column (= rrf_score)
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + r.bm25_rank_sparse_or_sentinel::DOUBLE PRECISION))
```

**Simpler scored CTE (single formula, same result):**
```sql
            -- rrf_sparse: bm25-absent items use sentinel n_candidates+1 (v0.6.2 Fix-A)
            (vec_weight  / (_rrf_k_f + r.vec_rank::DOUBLE PRECISION)
           + bm25_weight / (_rrf_k_f + COALESCE(r.bm25_rank_sparse,
                                                 r.n_candidates + 1)::DOUBLE PRECISION))
                AS rrf_sparse
```

**`anchors` CTE changes (1 line):**

```sql
-- BEFORE:
        ORDER BY fusion_score DESC
-- AFTER:
        ORDER BY rrf_sparse DESC   -- Fix-A: anchor by sparse-safe RRF signal
```

**Final SELECT changes (score column + ORDER BY):**

```sql
-- BEFORE:
        (
            s.fusion_score
          + _aux_scale * (...)
        ) AS score,
    ...
    ORDER BY score DESC

-- AFTER:
        (
            s.rrf_sparse          -- Fix-A primary signal
          + _aux_scale * (...)    -- aux unchanged: importance, recency, prov, graph
        ) AS score,
    ...
    ORDER BY score DESC           -- no ORDER BY change needed; driven by score column
```

**rrf_score output column:** keep returning `s.rrf_sparse AS rrf_score` (v0.6.1 returned
`s.rrf_diag AS rrf_score` as diagnostic). Callers using the `rrf_score` output column
will see different values — this is expected and documented in CHANGELOG.

### 2.3 COMMENT update

```sql
COMMENT ON FUNCTION pgmnemo.recall_hybrid(...) IS
    'v0.6.2 Fix-A: sparse-safe RRF (Cormack 2009). '
    'BM25-absent items use sentinel rank = n_candidates+1, not ROW_NUMBER() tie-break. '
    'rrf_sparse is primary ranking signal; fusion_score returned for backward compat. '
    ...
```

### 2.4 Invariants to verify

- `smoke_recall_hybrid.py` output column set unchanged — ✅ (`rrf_score` still returned)
- No new params on `recall_hybrid()` — ✅ (signature unchanged → `CREATE OR REPLACE`)
- `fusion_score` still computed and returned — ✅ (backward compat, consumers may use it)
- `_as_of_ts` GUC read (F2, shipped v0.6.1) — ✅ unchanged
- `_include_unverified` GUC read — ✅ unchanged

### 2.5 Lines changed: ~18

| Location | Lines |
|----------|-------|
| `rrf_ranked` CTE: +n_candidates, +bm25_rank_sparse CASE | +5 |
| `scored` CTE: rrf_sparse formula (replaces rrf_diag) | ~3 |
| `anchors` CTE ORDER BY | 1 |
| Final SELECT: `score` formula base term (fusion_score → rrf_sparse) | 1 |
| COMMENT update | ~3 |
| **Total** | **~13–18** |

### 2.6 recall_lessons() — no changes required

`recall_lessons()` delegates to `recall_hybrid()`. The ranking change is internal to
`recall_hybrid()`. The `as_of_ts` 6th param (shipped v0.6.1) passes through unchanged.

### 2.7 New pg_regress fixture: rrf_sparse.sql

Test cases for the sparse-safe behavior:
1. Corpus with 10 items, 3 BM25-matching. Run `recall_hybrid()` with `bm25_weight=0.4`.
   Assert: top result has highest cosine_score OR highest bm25_score (not a zero-bm25 item above them).
2. All-zero BM25 corpus (no text matches). Assert: results ordered by cosine only.
3. Tie-break: two items with identical cosine, one with bm25>0. Assert: bm25-matching item ranks higher.

`EXPLAIN (FORMAT JSON)` assertion: `rrf_sparse` must not appear in execution plan as a
full-seq-scan indicator — HNSW index path expected.

### 2.8 PARTITION BY (bm25_score > 0) — correctness proof

PostgreSQL evaluates `ROW_NUMBER() OVER (PARTITION BY (raw_bm25_score > 0) ORDER BY raw_bm25_score DESC)`:
- TRUE partition: items with bm25_score > 0, ranked 1, 2, 3, … by bm25_score DESC. ✅
- FALSE partition: items with bm25_score = 0, ranked 1, 2, … arbitrarily (tied). ✗ but discarded.

The CASE WHEN wrapper returns NULL for FALSE-partition rows. COALESCE replaces NULL with
sentinel `n_candidates + 1`. This means all absent-BM25 items receive an equal
"worst possible" BM25 rank, which is correct per the Cormack 2009 formulation.

---

## 3. Migration File Structure

### 3.1 Upgrade script: `extension/pgmnemo--0.6.1--0.6.2.sql`

```
Header: §0 scope (F1 only — F2/F3 already in 0.6.1)
§1: recall_hybrid() — sparse-safe RRF (CREATE OR REPLACE — no DROP)
§2: COMMENT update for recall_hybrid()
```

Estimated length: ~60 lines (shorter than v0.6.1 upgrade at 100 lines — no as_of_ts F2
SQL needed here, only F1 recall_hybrid() change).

### 3.2 Fresh install: `extension/pgmnemo--0.6.2.sql`

**Process:** copy `pgmnemo--0.6.1.sql` as base, apply F1 changes inline to `recall_hybrid()`.
All F2 (as_of_ts) and F3 code already in the base — no additional changes needed.
Update all version references from `0.6.1` → `0.6.2`.

**Mandatory verification:**
```bash
DROP EXTENSION pgmnemo; CREATE EXTENSION pgmnemo;   -- fresh install
SELECT pgmnemo.version();                            -- must return '0.6.2'
SELECT lesson_id FROM pgmnemo.recall_lessons(NULL::vector(1024), 5);   -- must work
```

### 3.3 Makefile additions

```makefile
DATA = ...
       pgmnemo--0.6.1--0.6.2.sql \   # NEW
       pgmnemo--0.6.2.sql             # NEW

REGRESS = ... stress_recall rrf_sparse   # ADD rrf_sparse
```

---

## 4. Real-DB Bench Infrastructure

### 4.1 Bench container setup (same as v0.6.1 plan)

```bash
# If pgmnemo-bench container exists from v0.6.1 run:
docker start pgmnemo-bench

# Apply v0.6.2 upgrade:
psql "host=localhost port=15432 dbname=bench user=bench password=bench" \
  -c "ALTER EXTENSION pgmnemo UPDATE TO '0.6.2';"
# OR fresh install from pgmnemo--0.6.2.sql

# Verify:
psql "..." -c "SELECT pgmnemo.version();"   -- '0.6.2'
```

### 4.2 Bench run sequence

```bash
# Baseline: v0.6.1 (fusion_score ordering — same as v0.5.1)
# NOTE: v0.6.1 bench results already exist at benchmarks/longmemeval/results/v0.6.1_realdb_20260523/
# Reuse as baseline — no re-run needed.

# v0.6.2 Fix-A bench:
DATABASE_URL="host=localhost port=15432 ..." \
python benchmarks/scripts/bench_v061_real.py \     # same script as v0.6.1 bench
  --variant sparse_safe_rrf \
  --out-dir benchmarks/longmemeval/results/v062_realdb_sparse_rrf

# Significance test (gate):
python scripts/significance_test_extended.py \
  benchmarks/longmemeval/results/v0.6.1_realdb_20260523/metrics.json \
  benchmarks/longmemeval/results/v062_realdb_sparse_rrf/metrics.json \
  --regression-pp 1.0
```

### 4.3 Gate criteria (unchanged from task spec)

- exit 1 (significant improvement): p_corr < 0.05 AND Δrecall@10 ≥ +1pp → **PASS, ship**
- exit 0 (neutral): **FAIL** — try Alternative B (adaptive k) composable add-on
- exit 2 (regression): **FAIL** — try Alternative C (BM25-gate conditional fusion)
- All variants fail: defer F1 to v0.7.0, ship v0.6.2 with version bumps + docs only

### 4.4 Bench fallback sequence (from RESEARCH §3)

1. Alt A (sparse-safe RRF, PARTITION trick) → gate
2. If FAIL: Alt A + Alt B (adaptive k = GREATEST(5.0, n_candidates/10.0)) → gate
3. If FAIL: Alt C (conditional fusion: ORDER BY rrf for bm25_score>0 items) → gate
4. If all FAIL: close F1 as won't-fix for this semantics. Update CHANGELOG with finding.

---

## 5. pg_regress Fixtures

### 5.1 New fixture: rrf_sparse.sql + expected/rrf_sparse.out

Tests sparse-safe behavior. ~35 lines SQL + ~30 lines expected output.

### 5.2 Existing fixture version strings

```bash
grep -r "ALTER EXTENSION pgmnemo UPDATE TO" extension/sql/ extension/expected/
```

Likely fixtures with hardcoded `'0.6.1'` version string:
- `extension/sql/version.sql` → update to `'0.6.2'`
- `extension/expected/version.out` → update to `'0.6.2'`
- Any fixture with `UPDATE TO '0.6.1'` → update to `'0.6.2'`

Current REGRESS list has 16 tests. After v0.6.2: 17 tests (+ rrf_sparse).

---

## 6. Pre-Tag Checklist (sequential)

```
□ Step 1: SQL implementation
  □ Write pgmnemo--0.6.1--0.6.2.sql (§1 recall_hybrid() sparse-safe RRF)
  □ Write pgmnemo--0.6.2.sql (squashed fresh install from 0.6.1 base)
  □ Update extension/pgmnemo.control: default_version = '0.6.2'
  □ Update extension/Makefile: DATA (2 new entries) + REGRESS (rrf_sparse)

□ Step 2: pg_regress
  □ Write extension/sql/rrf_sparse.sql + expected/rrf_sparse.out
  □ Update version.sql / version.out to '0.6.2'
  □ Fix any other fixtures with hardcoded '0.6.1' version string
  □ Run: make installcheck → 17/17 PASS

□ Step 3: Smoke test (MUST pass before bench)
  □ DATABASE_URL=postgresql://bench:bench@localhost:15432/bench \
      python3 scripts/smoke_recall_hybrid.py
  □ All assertions PASS → proceed
  □ Any FAIL → fix root cause, never bypass

□ Step 4: Real-DB bench
  □ docker start pgmnemo-bench (or docker run fresh)
  □ Apply pgmnemo--0.6.2.sql (or UPDATE TO '0.6.2')
  □ Run v0.6.2 bench → benchmarks/longmemeval/results/v062_realdb_sparse_rrf/
  □ Run significance_test_extended.py (vs v0.6.1 baseline)
  □ Evaluate gate. If FAIL: try fallback sequence (§4.4)
  □ Record result in benchmarks/gate/v0.6.2.json

□ Step 5: Documentation & metadata
  □ META.json: version = '0.6.2'
  □ pgmnemo_mcp/pyproject.toml: version = '0.6.2'
  □ CHANGELOG.md: [0.6.2] entry >200 chars with real bench numbers + v0.6.1 deferral note
  □ README.md: badge bump + recent-updates note
  □ docs/SQL_REFERENCE.md: recall_hybrid() updated COMMENT note
  □ docs/release_notes/v0.6.2_telegram.md (≤3500 chars)
  □ docs/release_notes/v0.6.2_announcement.md (optional)
  □ CI: .github/workflows/release.yml — update version refs 0.6.1 → 0.6.2 (Job 0 pre-flight)

□ Step 6: Final verification
  □ make installcheck → 17/17 PASS
  □ smoke_recall_hybrid.py → PASS
  □ benchmarks/gate/v0.6.2.json exists with bench_db_tested=true
  □ pgmnemo.control default_version = '0.6.2'
  □ git tag v0.6.2
  □ git push origin main --tags
  □ Manual Telethon publication (NOT auto-bot per founder directive)
```

---

## 7. Cost & Complexity Estimates (v0.6.2)

### 7.1 Implementation complexity

| Work item | Lines | Complexity | Risk |
|-----------|-------|------------|------|
| F1 `recall_hybrid()` sparse-safe RRF | ~18 | Low–Medium | Medium — gated on bench |
| pg_regress `rrf_sparse.sql` fixture | ~35 SQL + ~30 expected | Low | Low |
| Version string updates (control, META, pyproject, SQL) | ~10 | Low | Low |
| Fresh install squash (0.6.1 → patch recall_hybrid inline) | copy+patch | Medium | **HIGH — smoke test mandatory** |
| CHANGELOG + docs + telegram | — | Low | Low |
| **Total** | **~93 SQL + ~30 expected** | | |

F3 stress bench script already exists (`benchmarks/scripts/stress_recall_large.py`).
No re-implementation needed. F2 as_of_ts pg_regress fixture (`as_of_ts.sql`) already shipped.

### 7.2 Turn/cost estimate (revised upward from v0.6.1)

| Phase | Model | Est. turns | Est. cost |
|-------|-------|-----------|-----------|
| IMPLEMENT (SQL + fixture + smoke + bench) | Sonnet | 30–50 | $2.00–4.00 |
| Bench run (2 variants, may need fallbacks) | N/A (tooling) | — | ~$0 (local) |
| CODE_REVIEW | Sonnet | 8–12 | $0.40–0.60 |
| QA + SHIP | Haiku/Sonnet | 8–15 | $0.20–0.50 |
| **Total** | | **46–77** | **$2.60–5.10** |

**Budget cap:** max_cost=$12 per phase (IMPLEMENT). Total DAG budget: $30.
Previous failure (v0.6.1 IMPLEMENT) hit $7.20 at turn 120. With max_turns=200 + $12 cap,
the bench + iteration cycles have adequate headroom.

### 7.3 Critical path

```
IMPLEMENT
  → smoke_recall_hybrid.py PASS (blocking)
  → make installcheck 17/17 PASS (blocking)
  → real-DB bench → significance test → gate verdict
  → CHANGELOG + metadata
  → git tag v0.6.2
```

If bench fails: fallback sequence (§4.4). If all fail: close F1, ship docs/version only.

---

## 8. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `PARTITION BY (raw_bm25_score > 0)` syntax — PostgreSQL 14 may not support bool partition | LOW | PG14+ supports boolean partition expressions. Bench runs on PG17. |
| RANK() vs ROW_NUMBER() in BM25 partition affects recall | LOW | RANK() preserves ties (more correct). Use RANK(). |
| rrf_score output column value changes | LOW | Documented in CHANGELOG. No external consumer depends on the numerical value. |
| Fresh install squash breaks smoke test | HIGH | Copy 0.6.1.sql, patch recall_hybrid() inline, run smoke FIRST |
| Bench shows < +1pp again despite fix | MEDIUM | Three fallback alternatives (§4.4). Worst case: defer to v0.7.0. |
| MLX:9200 timeout during bench | MEDIUM | Verified healthy 2026-05-23 15:00 UTC. bge-m3 embeddings pre-cached in bench results. Reuse existing v0.6.1 baseline embeddings. |
| Smoke test AmbiguousColumn / UndefinedTable | MEDIUM | No CTE restructuring (add/remove CTEs). Only `rrf_ranked` and `scored` modified in-place. |

---

## 9. Implementation Sequence (for IMPLEMENT agent)

Execute in strict order:

1. **Write upgrade script** `extension/pgmnemo--0.6.1--0.6.2.sql`:
   - Header §0 (F1 scope only; F2/F3 already in 0.6.1)
   - §1: `CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(...)` — apply §2.2 changes:
     - `rrf_ranked`: add `n_candidates`, change `bm25_rank` → `bm25_rank_sparse` with PARTITION
     - `scored`: change `rrf_diag` formula to use `COALESCE(bm25_rank_sparse, n_candidates+1)`; rename to `rrf_sparse`
     - `anchors`: ORDER BY `rrf_sparse`
     - Final SELECT: base score `rrf_sparse`, ORDER BY `score`
   - §2: COMMENT update

2. **Write squashed fresh install** `extension/pgmnemo--0.6.2.sql`:
   - Copy `pgmnemo--0.6.1.sql` as base
   - Apply F1 changes inline to `recall_hybrid()` definition (identical to §1 above)
   - Update all version references `0.6.1` → `0.6.2`

3. **Update `pgmnemo.control`**: `default_version = '0.6.2'`

4. **Update `extension/Makefile`**: add `pgmnemo--0.6.1--0.6.2.sql`, `pgmnemo--0.6.2.sql` to DATA; add `rrf_sparse` to REGRESS

5. **Write pg_regress fixture** `extension/sql/rrf_sparse.sql` + `extension/expected/rrf_sparse.out`

6. **Update version strings** in existing fixtures (grep `ALTER EXTENSION pgmnemo UPDATE TO`)

7. **Run smoke test**: `DATABASE_URL=... python3 scripts/smoke_recall_hybrid.py` — MUST PASS

8. **Run pg_regress**: `make installcheck` — 17/17 PASS

9. **Run real-DB bench** (requires localhost:15432 + LME corpus):
   - `docker start pgmnemo-bench` (or fresh container)
   - Apply `pgmnemo--0.6.2.sql`
   - Run `bench_v061_real.py --variant sparse_safe_rrf`
   - Run `significance_test_extended.py` vs existing v0.6.1 baseline
   - If FAIL: try adaptive-k add-on (Alt B) → rerun bench
   - If FAIL again: try Alt C (conditional fusion) → rerun bench
   - Write `benchmarks/gate/v0.6.2.json` with verdict

10. **Update docs + metadata**: CHANGELOG (>200 chars with bench numbers), META.json,
    pyproject.toml, README badge, docs/SQL_REFERENCE.md, release.yml version refs

11. **Write release notes**: `docs/release_notes/v0.6.2_telegram.md` (≤3500 chars)

12. **Final verification**: smoke + installcheck + gate file exists

13. **Tag + push**: `git tag v0.6.2 && git push origin main --tags`

14. **Manual Telethon**: per founder directive — NOT auto-bot

---

## Appendix A: Definition of Done

- [ ] `make installcheck` → 17/17 PASS (16 existing + rrf_sparse)
- [ ] `scripts/smoke_recall_hybrid.py` → exit 0
- [ ] `benchmarks/gate/v0.6.2.json` exists with `"bench_db_tested": true`
- [ ] `pgmnemo.control` `default_version = '0.6.2'`
- [ ] `META.json` `version = '0.6.2'`
- [ ] `pgmnemo_mcp/pyproject.toml` `version = '0.6.2'`
- [ ] CHANGELOG.md has [0.6.2] entry >200 chars with real bench numbers + v0.6.1 deferral note
- [ ] `docs/release_notes/v0.6.2_telegram.md` ≤3500 chars
- [ ] `git tag v0.6.2` created and pushed

## Appendix B: Rollback

```bash
# DB rollback:
ALTER EXTENSION pgmnemo UPDATE TO '0.6.1';

# Git rollback (before tag):
git revert HEAD                   # or git reset if not yet pushed

# Git rollback (after tag):
git tag -d v0.6.2
git push origin :refs/tags/v0.6.2
```
