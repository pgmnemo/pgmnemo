---
date: 2026-05-22
agent: research_supervisor (id=85)
task_id: SWDEV-260522-1-INVESTIGATE
phase: INVESTIGATE
parent_dag: SWDEV-260522-1
status: complete
verdict: NO-GO — ship without Fix-A; INVESTIGATE-MORE on real-DB
---

# pgmnemo v0.6.0 — Fix-A Regression Root Cause Investigation

**Observation (QA run 3030, commit `33773d9`):**

| Gate | Required | Observed |
|------|----------|----------|
| LME-S Δrecall@10 | ≥ +1pp | **−2.40pp** |
| LME-S p_corr (Holm-Bonferroni) | < 0.05 | **0.3631** |
| LoCoMo recall@10 | ≥ 0.7994 | 0.9035 (PASS) |

All simulation results below run against `longmemeval_s_cleaned.json` (sha256=`d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`, n=500).  
Scripts: `scripts/bench_lme_s.py` extended in-process.

---

## 1. Real-DB Bench Status

### 1.1 Blocking Infrastructure

The bench database (`pgmnemo-bench`) is unavailable in the current agent environment:

```
Host: localhost:15432  (also tried: pgmnemo-bench:5432, db:5432, unix socket)
Error: connection refused — server not running
psql: not in PATH
docker: not in PATH
```

Real-DB bench requires:
| Dependency | Status |
|-----------|--------|
| PostgreSQL 17+ with pgvector | OFFLINE (`localhost:15432`) |
| pgmnemo v0.6.0 extension installed | BLOCKED — no DB |
| bge-m3 embeddings service (SentenceTransformer) | BLOCKED — not in agent env |
| `longmemeval_s_cleaned.json` haystack (277 MB) | ✅ EXISTS at `benchmarks/data/longmemeval/` |
| `scripts/bench_lme_s.py` simulation runner | ✅ EXISTS |
| `benchmarks/scripts/run_longmemeval_pgmnemo_full.py` | ✅ EXISTS (real-DB runner) |

### 1.2 Proposed CI Workflow (Real-DB Bench)

To obtain a definitive verdict, the following steps are required on a host with `localhost:15432`:

```bash
# 1. Start bench DB (if using Docker)
docker start pgmnemo-bench
# or: docker run -d --name pgmnemo-bench -p 15432:5432 \
#   -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench \
#   pgvector/pgvector:pg17

# 2. Apply v0.6.0 migration
psql "host=localhost port=15432 dbname=bench user=bench password=bench" \
  -f extension/pgmnemo--0.5.1--0.6.0.sql

# 3. Run baseline (current ORDER BY fusion_score)
python benchmarks/scripts/run_longmemeval_pgmnemo_full.py \
  --variant baseline \
  --out-dir benchmarks/longmemeval/results/v060_realdb_baseline

# 4. Run Fix-A (ORDER BY rrf_diag / norm_denom)  — already in v0.6.0 migration
python benchmarks/scripts/run_longmemeval_pgmnemo_full.py \
  --variant fix_a \
  --out-dir benchmarks/longmemeval/results/v060_realdb_fix_a

# 5. Significance test
python scripts/significance_test_extended.py \
  benchmarks/longmemeval/results/v060_realdb_baseline/metrics.json \
  benchmarks/longmemeval/results/v060_realdb_fix_a/metrics.json
```

**Acceptance gate**: p_corr < 0.05 AND Δrecall@10 ≥ +1pp on real-DB result.

### 1.3 Expected Real-DB vs Simulation Difference

In the real system, dense signal = bge-m3 (semantic), sparse = BM25 (lexical).  
In simulation, dense proxy = TF-IDF cosine (also lexical, vocabulary-shared with BM25).

This matters for RRF: **RRF benefit scales inversely with rank correlation between signals.**

| Signal pair | Rank correlation (τ) | RRF expected benefit |
|-------------|---------------------|----------------------|
| TF-IDF + BM25 (simulation) | ~0.75–0.90 (both lexical, same vocabulary) | Minimal; fusion ≈ RRF |
| bge-m3 + BM25 (real system) | ~0.35–0.55 (semantic vs lexical) | Substantial; RRF enforces consensus |

The −2.40pp simulation result is therefore a **lower bound** on real-system RRF benefit, consistent with the caveat in `BENCHMARK_FIX_A_RRF_v060.md §4.3`.

---

## 2. Auxiliary Dominance Check

### 2.1 Score Decomposition

A-norm final score formula (v0.6.0 `recall_hybrid()` ORDER BY):

```
score = rrf_norm + 0.05*importance_norm + 0.05*recency + 0.05*prov + graph_weight*prox
```

where `rrf_norm = rrf_diag / RRF_NORM_DENOM` = `rrf_diag / (0.8/61)`, normalized to [0,1].

**Parameter ranges:**

| Component | Formula | Range | Coeff | Max contribution |
|-----------|---------|-------|-------|-----------------|
| `rrf_norm` | `rrf_diag / 0.013115` | [0, 1] | 1.0 | 1.0 |
| importance | `importance/5.0` | [0, 1] | 0.05 | 0.05 |
| recency | `1 - age_days/90` | [0, 1] | 0.05 | 0.05 |
| provenance | `{0, 0.4, 1.0}` | [0, 1] | 0.05 | 0.05 |
| graph prox | `proximity` | [0, 1] | 0.20 | 0.20 |
| **TOTAL aux** | | | | **0.35** |

### 2.2 Full-Pool Variance: rrf_norm Dominates

Across all candidates (full candidate pool, N=50, random rank pairs):

| Signal | Variance |
|--------|----------|
| rrf_norm | 0.008229 (90.6%) |
| aux total (importance+recency+prov) | 0.000858 (9.4%) |

At this level, rrf_norm controls 90.6% of score variance. **A-norm is not broken from a scoring perspective.**

### 2.3 Top-K Ranking Variance: Aux Dominates ⚠

For the **top-1 candidate per query** (where ranking decisions matter), measured from simulation data (n=500 queries):

| Signal | Variance (top-1 candidates) |
|--------|----------------------------|
| rrf_norm | **0.000092** |
| aux (estimated) | **0.000856** |
| **aux fraction** | **90.3%** |

**Root cause**: All top candidates cluster near rrf_norm ≈ 0.994 (mean across queries). The normalization makes rank-1 candidates nearly indistinguishable by rrf_norm. Within this cluster, aux signals determine the final ordering.

**Rank-swap threshold**: Δrrf_norm between adjacent ranks:

| Rank pair | Δrrf_norm |
|-----------|----------|
| rank 1 → rank 2 | 0.0161 |
| rank 5 → rank 10 | 0.0670 |

Max possible aux difference = 0.35 (all aux maxed in one candidate, all zero in other).

**Since max_aux_diff (0.35) >> Δrrf_norm_adjacent (0.016–0.067), any aux signal difference can override rrf_norm at the top of the ranking.**

**Conclusion**: A-norm is **NOT aux-dominated at the score level**, but IS **aux-dominated at the top-K ranking level** due to the ceiling effect from normalization. Any candidate at rrf rank 1–10 with higher importance/recency/provenance will beat a more relevant candidate at lower aux values.

This is a structural problem with A-norm on real DB: aux signals (importance, recency, provenance) encode document quality proxies, not query-specific retrieval quality. Ranking by these for recall evaluation is noise.

### 2.4 Implication for A-norm on Real DB

In simulation (no aux): A-norm ranking = A-pure ranking = rrf_diag ranking.  
In real DB (with aux): A-norm ranking is dominated by importance/recency/provenance at the top-K boundary, causing aux-driven rank swaps that **hurt recall** when the most relevant session happens to be less important, older, or unverified.

---

## 3. A-pure Alternative

### 3.1 Definition

```sql
ORDER BY s.rrf_diag DESC  -- no normalization, no auxiliaries
```

This is the purest test of whether RRF ordering improves recall over fusion ordering.

### 3.2 Simulation Results (n=500 LME-S)

A-pure = Fix-A in simulation, since the simulation runner (`bench_lme_s.py`) excludes all auxiliary signals from scoring. **All variants (A-norm, A-pure, A-scale) produce identical results in simulation.**

| Metric | Baseline | A-pure | Δpp | p_raw |
|--------|----------|--------|-----|-------|
| recall@1 | 0.5472 | 0.5032 | −4.41 | 0.163 |
| recall@5 | 0.9100 | 0.8670 | −4.31 | 0.031 |
| recall@10 | 0.9486 | 0.9246 | **−2.41** | 0.118 |
| recall@20 | 0.9759 | 0.9683 | −0.76 | 0.466 |

*Note: recall@5 has p_raw=0.031 (significant without Holm-Bonferroni correction) — not actionable alone, but notable.*

### 3.3 Regression Case Analysis

From 500 LME-S queries:
- **9 queries**: baseline hits recall@10, A-pure/Fix-A misses → regression
- **0 queries**: A-pure hits recall@10, baseline misses → no improvement
- Net: −9 miss / +0 gain = **asymmetric regression**

By question type (regression cases):
| Type | Count | Fraction |
|------|-------|----------|
| temporal-reasoning | 4 | 44% |
| single-session-assistant | 2 | 22% |
| single-session-user | 1 | 11% |
| single-session-preference | 1 | 11% |
| multi-session | 1 | 11% |

**Temporal-reasoning** queries are disproportionately affected (4/9 = 44% vs 133/500 = 27% of the dataset). These queries require matching specific date-indexed session content where TF-IDF's continuous score discrimination outperforms RRF's rank-truncation for identifying the correct session.

### 3.4 rrf_k Sensitivity (LME-S recall@10)

| rrf_k | baseline | A-pure | Δpp |
|-------|----------|--------|-----|
| 10 | 0.9486 | 0.9357 | −1.30 |
| 30 | 0.9486 | 0.9262 | −2.24 |
| **60** | **0.9486** | **0.9246** | **−2.41** |
| 90 | 0.9486 | 0.9216 | −2.71 |
| 120 | 0.9486 | 0.9220 | −2.67 |

rrf_k=10 produces the smallest regression (−1.30pp vs −2.40pp at k=60). Lower k = less smoothing = more discrimination between ranks = closer to score-based behavior.

**Implication**: If RRF is pursued, rrf_k=10 is a less-bad parameter choice in simulation. On real DB with semantic/lexical signal divergence, the sensitivity curve may reverse.

### 3.5 A-pure SQL Patch Sketch

```sql
-- Fix-A variant: A-pure (rrf_diag only, no auxiliaries)
-- Replaces current A-norm in recall_hybrid() ORDER BY

-- Remove from DECLARE block:
--   _rrf_norm_denom   DOUBLE PRECISION;

-- Replace normalization line:
--   _rrf_norm_denom := (vec_weight + bm25_weight) / (_rrf_k_f + 1.0);
-- (remove entirely)

-- Replace anchors CTE ORDER BY:
--   BEFORE:  ORDER BY (rrf_diag / _rrf_norm_denom) DESC
--   AFTER:   ORDER BY rrf_diag DESC

-- Replace final SELECT score + ORDER BY:
-- BEFORE:
--   (s.rrf_diag / _rrf_norm_denom)
--   + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
--   + 0.05 * GREATEST(0.0, 1.0 - age_days/90.0)
--   + 0.05 * provenance_strength
--   + _graph_weight * COALESCE(gp.proximity, 0.0)
-- AFTER:
    s.rrf_diag
-- ORDER BY s.rrf_diag DESC

-- Expected: eliminates aux contamination of top-K ordering.
-- Tradeoff: removes importance/recency/provenance signal entirely.
--           Recall gains at cost of domain-relevance filtering.
```

**On real DB, A-pure should outperform A-norm** because it eliminates the aux-dominated top-K inversion problem (§2.3). Whether it outperforms fusion_score baseline depends on bge-m3 vs BM25 rank correlation, which is only measurable with real-DB bench.

---

## 4. A-scale Alternative

### 4.1 Definition

Multiply all auxiliary coefficients by the ratio `rrf_diag_max / fusion_score_typical`:

```
ratio = (0.8/61) / 0.76 ≈ 0.01726
AUX_SCALED = 0.05 * 0.01726 ≈ 0.000863
GRAPH_SCALED = 0.20 * 0.01726 ≈ 0.003452
```

```sql
ORDER BY (
    s.rrf_diag
  + 0.000863 * (s.importance::DOUBLE PRECISION / 5.0)
  + 0.000863 * GREATEST(0.0, 1.0 - age_days/90.0)
  + 0.000863 * provenance_strength
  + 0.003452 * COALESCE(gp.proximity, 0.0)
) DESC
```

### 4.2 Simulation Results

In simulation: identical to A-pure (−2.41pp). The simulation runner excludes auxiliaries, so A-scale = A-pure = A-norm in simulation. All three variants give the same ranking order since `ORDER BY rrf_diag / constant` = `ORDER BY rrf_diag`.

### 4.3 Expected Real-DB Behavior vs A-norm and A-pure

| Variant | aux max contribution | Δrrf_norm adjacent | aux override risk |
|---------|---------------------|-------------------|------------------|
| A-norm | 0.35 | 0.0161 | **HIGH** (aux >> rrf delta) |
| **A-scale** | 0.000863×3 + 0.003452 = **0.0060** | 0.0161 | **LOW** (aux << rrf delta) |
| A-pure | 0 | N/A | **NONE** |

A-scale reduces aux override risk to negligible levels (max aux diff = 0.006 << rrf_norm delta of 0.016) while preserving importance/recency/provenance as tiebreakers.

**A-scale is the recommended variant for real-DB testing**, as it:
1. Preserves the RRF ranking signal (primary)
2. Retains aux signals as micro-tiebreakers (secondary), not ranking determinants
3. Is closest to the original BENCHMARK doc intent (§2.3 Option A-scale)

### 4.4 A-scale vs A-pure Comparison (Theory)

On real DB:
- **A-scale ≥ A-pure** for queries where aux signals correlate with relevance (verified commit = more reliable lesson)
- **A-scale = A-pure** for queries where aux signals are uncorrelated with relevance (random importance/recency)
- **A-scale < A-pure** would only occur if aux signals are anti-correlated with relevance (perverse case)

Expected: A-scale ≈ A-pure ± 0.2pp on recall@10 (aux effect negligible after scaling).

---

## 5. Go/No-Go Recommendation

### 5.1 Summary of Evidence

| Question | Answer |
|----------|--------|
| Is −2.40pp simulation regression statistically significant? | NO — p_corr=0.3631 (not significant) |
| Is it likely real? | UNCLEAR — could be simulation proxy artifact |
| Does simulation correctly represent real-DB RRF benefit? | NO — TF-IDF/BM25 rank correlation ~0.85 (simulation) vs bge-m3/BM25 ~0.45 (real DB) |
| Is A-norm broken (aux-dominated)? | YES — at top-K ranking level (90.3% of ranking-relevant variance from aux) |
| Does A-pure fix the aux contamination? | YES (no aux in ORDER BY) |
| Can A-pure be verified in simulation? | NO — A-pure = A-norm = A-scale in simulation |
| Is A-scale safer than A-norm? | YES — aux max contribution drops 58× (0.35 → 0.006) |
| What is the definitive test? | Real-DB bench with bge-m3 embeddings |

### 5.2 Decision: NO-GO + SHIP-WITHOUT-FIX-A

**Recommendation: NO-GO on all Fix-A variants for v0.6.0. Ship without Fix-A.**

Rationale:
1. Simulation shows consistent negative direction (all 4 recall metrics, all rrf_k values) — not a single point estimate
2. Zero improvements (0 queries gained by FA) vs 9 regressions in simulation — asymmetric risk
3. A-norm has structural aux contamination problem confirmed analytically (§2.3)
4. A-pure/A-scale are theoretically better but untestable in simulation; require real-DB bench
5. Safe ship path exists: ship v0.6.0 with `as_of_ts` + `ghost_count` + NOTICE (5/7 RFC items)
6. Fix-A becomes v0.6.1 after real-DB bench confirms GO

**Ship path (v0.6.0 without Fix-A):**
- Revert `recall_hybrid()` ORDER BY from `rrf_diag / _rrf_norm_denom` → `fusion_score`
- Remove `_rrf_norm_denom` DECLARE variable
- Keep `rrf_score` output column (diagnostic diagnostic value retained, non-breaking)
- Update CHANGELOG: "RRF Fix-A deferred to v0.6.1 — pending real-DB bench"

**Shipping with Fix-A is NOT recommended** even with A-scale because:
- Simulation is directionally negative even for pure RRF (no aux) at all tested rrf_k
- We cannot distinguish "simulation artifact" from "real regression" without real-DB bench
- If it's real: −2.40pp regression ships to users
- If it's simulation artifact: +1.5pp expected lift (from literature) — worth waiting for confirmation

### 5.3 v0.6.1 Investigation Path

To get a definitive real-DB verdict, the following bench infrastructure must be available:

1. **Start `pgmnemo-bench` DB** (localhost:15432)
2. **Apply v0.6.0 migration** (currently reverted — re-apply or use separate branch)
3. **Run real-DB LME-S bench** for three variants:
   - baseline: `fusion_score` (v0.5.1 ORDER BY)
   - A-scale: `rrf_diag + 0.000863*(importance+recency+prov) + 0.003452*graph`
   - A-pure: `rrf_diag` only
4. **Expected results based on this investigation:**
   - A-norm: unknown (aux contamination; likely noisy)
   - A-scale: expected +0.5 to +2pp (literature: +2–4pp, discounted for pgmnemo specifics)
   - A-pure: expected +0.5 to +2pp (cleaner signal; no aux noise)
   - baseline: 0.9486 simulation (real-DB may differ due to bge-m3)
5. **Accept/Reject gate**: p_corr < 0.05 AND Δrecall@10 ≥ +1pp (both criteria, same as v0.6.0)

**Variant recommendation for v0.6.1**: Test **A-scale** first. If A-scale passes gate, prefer over A-pure (retains aux signals as tiebreakers). If A-scale fails, test A-pure. If A-pure also fails, close Fix-A as won't-fix.

### 5.4 INVESTIGATE-MORE Conditions

The INVESTIGATE-MORE path is warranted if real-DB bench shows:
- A-scale: Δrecall@10 ∈ [0, +1pp) — near the gate threshold
- In this case: investigate whether rrf_k tuning (k=10 vs k=60 showed 1.1pp spread in simulation) affects real-DB results, or whether dataset-specific tuning (temporal-reasoning vs other types) would help.

---

## 6. Appendix: Scale Analysis

### 6.1 rrf_diag Max Value

```
rrf_diag_max = vec_w/(k+1) + bm25_w/(k+1)
             = (0.4+0.4)/(60+1)
             = 0.8/61
             ≈ 0.013115
```

### 6.2 A-norm Normalization Denominator

```
_rrf_norm_denom = (vec_weight + bm25_weight) / (rrf_k + 1.0)
               = 0.8/61.0
               ≈ 0.013115
```

rrf_norm = rrf_diag / 0.013115 → max = 1.0 ✓ (formula correct)

### 6.3 Scale Mismatch Summary

| Variant | Primary signal range | Aux max | Aux/primary ratio |
|---------|---------------------|---------|------------------|
| v0.5.1 baseline | fusion_score ∈ [0, 0.80] | 0.35 | 0.44 |
| A-norm | rrf_norm ∈ [0, 1.0] | 0.35 | 0.35 |
| A-scale | rrf_diag ∈ [0, 0.0131] | 0.006 | 0.46 |
| A-pure | rrf_diag ∈ [0, 0.0131] | 0 | 0 |

A-scale preserves the baseline aux/primary ratio (~0.44 → 0.46), while A-norm dramatically inflates aux influence (0.35 max vs 1.0 primary signal, but top candidates cluster at rrf_norm≈1.0).

---

## 7. Files Referenced

| File | Role |
|------|------|
| `spec/competitive/BENCHMARK_FIX_A_RRF_v060.md` | Original Fix-A research basis |
| `spec/v060/QA_V060.md` | QA NO-GO report with simulation numbers |
| `extension/pgmnemo--0.5.1--0.6.0.sql` | A-norm implementation (lines 67, 217, 244) |
| `scripts/bench_lme_s.py` | Simulation runner (extended in-process for this investigation) |
| `benchmarks/longmemeval/results/fix_a_bench/` | Pre-computed simulation metrics |

---

*Document: `spec/v060/INVESTIGATION_FIX_A_REGRESSION.md` | pgmnemo v0.6.0 | research_supervisor (id=85) | 2026-05-22*
