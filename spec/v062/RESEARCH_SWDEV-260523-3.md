---
date: 2026-05-23
author: principal_investigator (id=77)
task_id: SWDEV-260523-3-RESEARCH
phase: RESEARCH
parent_dag: SWDEV-260523-3
status: complete
base_research: spec/v062/RESEARCH_V062.md (commit e839b1f) — fix alternatives
---

# pgmnemo v0.6.2 — RESEARCH SWDEV-260523-3
## Bench → Gate → Ship Decision Document

**Scope:** SWDEV-260523-3 focuses on the execution path: run the bench, evaluate
the gate, ship or roll back. The fix itself (sparse-safe RRF) is already implemented
in `extension/pgmnemo--0.6.1--0.6.2.sql` and `extension/pgmnemo--0.6.2.sql`. This
document identifies ≥3 alternatives for what to do at each gate outcome, based on
the bench result. No new implementation is proposed here; this is a decision framework.

---

## 0. Pre-Conditions (must verify before bench)

| Pre-condition | Check | Expected |
|--------------|-------|---------|
| v3-next container health | (internal container health check) | `0` |
| MLX:9200 reachable | `curl -s http://localhost:9200/health` or bge-m3 smoke | HTTP 200, 1024d |
| LME-S data present | `ls benchmarks/data/longmemeval/longmemeval_s_cleaned.json` | file exists |
| Embedding cache present | `ls benchmarks/.embed_cache/` | non-empty (same as v0.6.1 bench) |
| PostgreSQL 17 + pgvector reachable | `psql $PGURL -c '\dx pgvector'` | installed |
| pgmnemo installed at v0.6.1 | `SELECT pgmnemo.version()` | `0.6.1` |
| Bench script present | `ls benchmarks/scripts/run_v062_sparse_safe_bench.py` | exists |

Note per task description: v3-next RestartCount=0 throughout v0.6.2 attempt 1; MLX:9200
verified healthy 2026-05-23 19:14 UTC. Pre-conditions are expected to be healthy.

---

## 1. Implementation State (unchanged from PLAN v0.6.2)

All v0.6.2 code is in the working tree, uncommitted:
- `extension/pgmnemo--0.6.2.sql` — fresh-install with sparse-safe RRF
- `extension/pgmnemo--0.6.1--0.6.2.sql` — upgrade migration
- `extension/sql/rrf_sparse.sql` + `extension/expected/rrf_sparse.out` — pg_regress
- `benchmarks/scripts/run_v062_sparse_safe_bench.py` — bench, NOT YET RUN
- Version bumps: META.json, pgmnemo.control, pgmnemo_mcp/pyproject.toml → 0.6.2

The sparse-safe RRF implementation uses:
- `RANK() OVER (PARTITION BY (bm25_score > 0) ORDER BY bm25_score DESC)` for BM25 ranks
- Sentinel `COALESCE(bm25_rank_sparse, n_candidates + 1)` for zero-BM25 items
- This is semantically correct per Cormack et al. 2009

---

## 2. Gate Criteria (locked)

```
PASS iff ALL of:
  recall@10(sparse-safe) >= recall@10(baseline 0.9334) + 0.01  → ≥ 0.9434
  p_corr (paired t-test) < 0.05  (statistical significance)
  LoCoMo recall@10 >= 0.7994  (must not regress)
  pg_regress 17/17 PASS  (+rrf_sparse vs v0.6.1 16)
  scripts/smoke_recall_hybrid.py PASS
```

---

## 3. Alternatives by Gate Outcome

### Alternative A: Gate PASS → Ship v0.6.2 as-is (PRIMARY PATH)

**Trigger:** All 5 gate criteria met.

**Actions:**
1. Write `benchmarks/gate/v0.6.2.json` with `gate_status=PASS` and real-DB evidence pointer
2. Write `CHANGELOG.md [0.6.2]` entry (>200 chars), note F1 sparse-safe vs v0.6.1 A-scale
3. Write `docs/release_notes/v0.6.2_telegram.md` (≤3500 chars)
4. `git add` all uncommitted v0.6.2 files in single SHIP commit
5. `git tag v0.6.2` and push; verify `release.yml` CI green (validated for v0.6.1)

**Pros:**
- Fixes the root cause confirmed in v0.6.1 bench (−22.44pp from tied 0-score bm25_rank)
- Semantically correct RRF (Cormack 2009) — defensible in paper citation
- Single clean commit; no version rollback complexity
- Release pipeline already proven working for v0.6.1

**Cons:**
- Bench not yet run — gate outcome unknown
- Requires real-DB execution (not simulation); latency ~15–30 min for N=500

**Evidence for expected PASS:** Root cause of v0.6.1 regression was the `ROW_NUMBER()`
arbitrary tie-break on tied 0-scores. Sparse-safe RRF eliminates this by giving non-BM25
items sentinel rank = n+1, preserving their relative vector-based ordering. Analytical
reasoning strongly supports recovery to ≥ baseline. Evidence grade: PRELIMINARY
(sound theoretical basis; real-DB confirmation required).

---

### Alternative B: Gate marginal near-miss (+0pp to +0.99pp) → Add adaptive-k and re-bench

**Trigger:** `recall@10(fix_a) ≥ 0.9334` (no regression) but `< 0.9434` (just below +1pp gate).
OR: `p_corr ≥ 0.05` with `delta ≥ 0.01` (gain real but not statistically significant at N=500).

**Diagnosis:** Sparse-safe RRF removes the corruption, but fixed k=60 still over-compresses
rank differences in small corpora (48 segs/session). Adaptive k = max(5, N/10) ≈ 5 for 48
segments, reducing denominator compression and increasing rank signal discrimination.

**Actions:**
1. Add `_rrf_k_f := GREATEST(5.0, _total_candidates::DOUBLE PRECISION / 10.0)` to
   `recall_hybrid()` DECLARE + BEGIN (remove CONSTANT annotation)
2. Run bench again with this composable change (same script, ~30 min)
3. If gate now PASSES: proceed as Alternative A with both changes documented
4. If still misses: escalate to Alternative C or D

**Implementation delta from current v0.6.2:** ~5 lines in `recall_hybrid()`. No CTE
restructuring. The bench script's simulation computes `_rrf_k_f` client-side; update
`RRF_K = max(5.0, len(sessions)/10.0)` in the script correspondingly.

**Pros:**
- Composable add-on to sparse-safe RRF; no regression risk
- Smallest possible diff; no CTE restructuring risk
- Addresses the secondary rank-compression issue analytically
- Mathematical property: for N=48 segs, k=5 → denominator 6 vs 61 (10× better discrimination)

**Cons:**
- Adds non-constant behavior: different corpus sizes get different k (non-deterministic from user perspective)
- Heuristic `N/10` has no literature support for this specific dataset
- Requires a second bench run (~30 min extra)
- May behave unexpectedly for very large corpora (k grows unbounded)

**Evidence grade:** MODERATE (mathematical property demonstrated; LME-S-specific gain unverified).

---

### Alternative C: Gate clear fail (regression or <0pp delta) → BM25-gate conditional fusion

**Trigger:** `recall@10(fix_a) < 0.9334` (regression vs baseline) regardless of delta size.
This means sparse-safe RRF still harms recall, indicating a second unidentified defect.

**Diagnosis:** If sparse-safe RRF regresses despite sentinel rank fix, the residual issue is
likely the ORDER BY rrf_sparse denominator behavior for pure-vector queries (no BM25 match at
all). Conditional fusion preserves baseline for zero-BM25 items while applying RRF to BM25-
matching items. This was Alternative C from SWDEV-260523-2-RESEARCH (research doc e839b1f).

**Implementation:**
```sql
-- scored CTE: add bm25_rank_among_matched window function for matched-only subset
CASE WHEN raw_bm25_score > 0
     THEN RANK() OVER (PARTITION BY (raw_bm25_score > 0) ORDER BY raw_bm25_score DESC)
     ELSE NULL
END AS bm25_rank_matched,

-- Final ORDER BY (conditional):
ORDER BY (
    CASE WHEN s.bm25_score > 0
         THEN vec_weight / (_rrf_k_f + s.vec_rank)
              + bm25_weight / (_rrf_k_f + s.bm25_rank_matched)
         ELSE s.v_score  -- pure vector for non-BM25 items
    END
  + _aux_scale * (importance + recency + provenance)
) DESC
```

**Actions:**
1. Rewrite `recall_hybrid()` with conditional ORDER BY
2. Run smoke_recall_hybrid.py (must PASS before bench)
3. Run bench; gate criteria apply equally
4. If PASS: commit with notation "Alt-C conditional fusion, not pure RRF"
5. If FAIL: proceed to Alternative D

**Pros:**
- Conservative: non-BM25 sessions are unaffected — baseline preserved for worst case
- Addresses sparse-BM25 corruption for queries where BM25 matches
- No need for full CTE restructuring; window function partition is additive
- Easier to explain: "RRF when BM25 matches, pure vector otherwise"

**Cons:**
- Non-standard: no literature supports this exact conditional formulation
- Cannot claim "proper RRF" in papers — would need different framing
- Gain bounded by fraction of queries where BM25 produces nonzero scores
- Two execution paths make benchmarking interpretation more complex
- The `rrf_score` output column would carry a conditional meaning

**Evidence grade for Alternative C baseline-preservation:** STRONG (degrades to fusion_score
for zero-BM25 items = current v0.6.1 behavior; mathematical identity confirmed).

---

### Alternative D: All gates fail → Defer F1 entirely, roll back version bumps

**Trigger:** Alternatives A, B, and C all fail the gate (unlikely but possible).

**Actions:**
1. Write `benchmarks/gate/v0.6.2.json` with `gate_status=NO_GO`, metrics, and analysis
2. Restore version bumps to 0.6.1: `META.json`, `pgmnemo.control`, `pgmnemo_mcp/pyproject.toml`
3. Do NOT tag, do NOT ship any partial revert (lesson from v0.6.0)
4. ESCALATE — log finding in ROADMAP.md as "F1 deferred to v0.6.3 or v0.7.0"
5. Document failure mode in `spec/v062/` for future approach design

**Pros:** Zero regression risk; all baselines preserved; clean state for future work

**Cons:**
- F1 deferred for the third time (after v0.6.0 and v0.6.1)
- Cannot pass the headline gate (LME recall@10 ≥ 0.9434) — version bump wasted
- Task spec explicitly states this is the gate-fail path, not a valid ship path

**Evidence grade for likelihood of Alternative D:** CONJECTURE — three independent regression
modes (A-scale, A-pure, A-norm already failed analytically; sparse-safe is the one remaining
variant with correct theoretical basis). Probability of needing Alt D is low.

---

## 4. Decision Tree

```
Pre-flight PASS?
├── NO  → Fix infra, do not run bench
└── YES → Run run_v062_sparse_safe_bench.py

Gate PASS (all 5)?
├── YES → Alternative A (SHIP)
└── NO  → What failed?
    ├── recall@10 ∈ [0.9334, 0.9434) OR p≥0.05 → Alternative B (adaptive-k, re-bench)
    │   └── B gate PASS? → SHIP (A+B) | FAIL → Alternative C
    ├── recall@10 < 0.9334 (regression) → Alternative C (conditional fusion)
    │   └── C gate PASS? → SHIP (Alt-C) | FAIL → Alternative D
    └── LoCoMo regression / pg_regress fail → Debug CTE scoping; fix and re-run
```

---

## 5. Evidence Summary

| Claim | Grade | Source |
|-------|-------|--------|
| v0.6.1 rrf_diag regressed −22.44pp on LME-S | STRONG | `benchmarks/gate/v0.6.1.json` real bench N=500 |
| Root cause: tied 0-score ROW_NUMBER() tie-break | STRONG | Analytical + corpus stats (~48 segs/session) |
| Sparse-safe RRF (sentinel rank) eliminates the tie-break | STRONG | Mathematical identity |
| Sparse-safe RRF will recover to ≥ baseline + 1pp | PRELIMINARY | Theory sound; no pgmnemo-specific bench yet |
| Adaptive-k reduces rank-compression for small corpora | MODERATE | Mathematical property; LME-S magnitude unverified |
| Alt-C conditional fusion preserves baseline for zero-BM25 | STRONG | Mathematical identity (degrades to fusion_score) |
| Simulation is an invalid proxy for real-DB gate | STRONG | v0.6.1 confirmed ρ(sim,real) ≈ −1.0 for this fix-class |

---

## 6. RESEARCH Verdict

**Proceed with bench run immediately.** Alt A is the primary path. Alternatives B and C
are well-defined fallbacks if A misses gate. Alt D is the documented worst-case exit.

Pre-flight verification before bench (from task spec absolute priority order 1):
- `docker inspect ...RestartCount` → 0
- MLX:9200 → 200 OK, 1024d
- Then execute `python3 benchmarks/scripts/run_v062_sparse_safe_bench.py`

Expected outcome: GATE PASS on first run (Alt A). Evidence grade: PRELIMINARY.

**If bench completes and gate passes, SHIP immediately per task spec.**
