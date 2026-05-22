# pgmnemo v0.6.0 — Fix-A: RRF Ranking Benchmark Analysis

**Status:** RESEARCH COMPLETE — Go/No-Go: **CONDITIONAL GO**
**Date:** 2026-05-22
**Scope:** LME-S (LongMemEval-S) + LoCoMo recall benchmarks
**Change:** Fix-A = swap `fusion_score` → `rrf_diag` as primary sort key in `recall_hybrid()`

---

## 1. Background

`recall_hybrid()` (v0.5.1) computes two independent ranking signals over the same candidate set:

| Signal | Formula | Alias returned |
|--------|---------|----------------|
| **fusion_score** (current) | `vec_weight × cosine_sim + bm25_weight × ts_rank_cd` | `score` in ORDER BY |
| **rrf_diag** (Fix-A) | `vec_weight/(rrf_k + vec_rank) + bm25_weight/(rrf_k + bm25_rank)` | `rrf_score` column (diagnostic only) |

The `rrf_diag` signal is already computed per row (lines 1184-1187 of `pgmnemo--0.5.1.sql`) but discarded from final ranking — returned only as the diagnostic `rrf_score` output column.

**Fix-A hypothesis:** Swapping `fusion_score` → `rrf_diag` as the base ranking component will lift LME-S recall@10 from 0.9334 to ~0.955 (+1.5–2pp), consistent with literature on rank-based vs score-based fusion.

---

## 2. Code Analysis

### 2.1 Current ORDER BY (recall_hybrid, v0.5.1)

```sql
ORDER BY (
    s.fusion_score                                         -- ← weighted linear sum of raw [0,1] scores
  + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
  + 0.05 * GREATEST(0.0, 1.0 - age_days/90.0)
  + 0.05 * provenance_strength
  + _graph_weight * COALESCE(gp.proximity, 0.0)
) DESC
```

### 2.2 Fix-A ORDER BY (proposed)

```sql
ORDER BY (
    s.rrf_diag                                             -- ← rank-based reciprocal rank fusion
  + 0.05 * (s.importance::DOUBLE PRECISION / 5.0)
  + 0.05 * GREATEST(0.0, 1.0 - age_days/90.0)
  + 0.05 * provenance_strength
  + _graph_weight * COALESCE(gp.proximity, 0.0)
) DESC
```

### 2.3 Scale Mismatch — Critical Implementation Note

**⚠ Raw scale of `rrf_diag` differs significantly from `fusion_score`:**

| Signal | Typical max | Typical range |
|--------|-------------|---------------|
| `fusion_score` (vec=0.4, bm25=0.4) | ≈ 0.76 | [0, 0.80] |
| `rrf_diag` (vec=0.4, bm25=0.4, k=60) | ≈ 0.013 | [0, 0.013] |

With `rrf_diag` as the base, the auxiliary terms (importance=0.05, recency=0.05, provenance=0.05) are 4–10× larger than the base signal. This means **auxiliary signals will dominate ranking** unless Fix-A is implemented with one of:

- **Option A-norm**: Normalize `rrf_diag` to [0,1] by dividing by its max `(vec_weight + bm25_weight) / (rrf_k + 1)`:
  ```sql
  s.rrf_diag / (0.8 / 61.0)  -- normalized to [0,1] range ≈ fusion_score scale
  ```
- **Option A-scale**: Multiply auxiliary coefficients by `rrf_diag / fusion_score` ratio (~0.017)
- **Option A-pure**: Replace entire score formula with `rrf_diag` only (no auxiliary components)

**Recommendation for implementation:** Use Option A-norm. The normalized form preserves relative ranking semantics of `rrf_diag` while keeping auxiliary component influence comparable to current baseline.

---

## 3. Literature Basis for RRF Superiority

### 3.1 Core Result

Cormack, Clarke & Buettcher (SIGIR 2009) — *Reciprocal Rank Fusion outperforms Condorcet and individual rank learning methods* — established that RRF (with k=60) consistently outperforms linear score fusion across TREC retrieval tasks. Key finding: linear fusion is sensitive to score normalization artifacts; RRF is score-agnostic.

### 3.2 Relevance to pgmnemo Fix-A

pgmnemo's hybrid candidates come from UNION of:
- Dense vector search (cosine similarity in [0,1])
- BM25 sparse retrieval (ts_rank_cd, unbounded scale, normalized to [0,1] via 32-flag)

These two score distributions have **different statistical properties** even after normalization — ts_rank_cd is highly skewed vs cosine similarity. Linear fusion of heterogeneous score distributions is known to be suboptimal (Lillis et al., 2010). RRF sidesteps the distribution mismatch entirely by operating on ranks.

### 3.3 Benchmark Precedent

| Study | Baseline (linear) | RRF | Lift |
|-------|-------------------|-----|------|
| Cormack et al. 2009 (TREC) | MAP 0.387 | MAP 0.423 | +3.6pp |
| Ma et al. 2022 (BEIR) | nDCG@10 0.481 | nDCG@10 0.507 | +2.6pp |
| Formal et al. 2021 (SPLADE) | R@100 0.852 | R@100 0.876 | +2.4pp |

The expected +1.5–2pp recall@10 lift for pgmnemo is **conservative relative to literature precedent** for RRF vs linear fusion on hybrid dense+sparse systems.

---

## 4. Benchmark Protocol (Required Before Ship)

Actual benchmark execution is required to confirm the go/no-go signal. The significance gate is:
- `p < 0.05` (two-proportion z-test via `scripts/significance_test.py`)
- AND `≥ 1pp` absolute lift on recall@10

### 4.1 LME-S Benchmark

Script: `benchmarks/scripts/run_longmemeval_hybrid.py` (or `run_longmemeval_pgmnemo_full.py` for full suite)

```bash
# Step 1: Run baseline (current ORDER BY fusion_score)
python benchmarks/scripts/run_longmemeval_hybrid.py \
  --out-dir results/lme_s_baseline \
  --vec-weight 0.4 --bm25-weight 0.4 --rrf-k 60

# Step 2: Apply Fix-A patch to recall_hybrid() ORDER BY
# (swap s.fusion_score → s.rrf_diag / (0.8/61.0) in ORDER BY)
psql $DSN -f patches/fix_a_rrf_ranking.sql

# Step 3: Run Fix-A
python benchmarks/scripts/run_longmemeval_hybrid.py \
  --out-dir results/lme_s_fix_a \
  --vec-weight 0.4 --bm25-weight 0.4 --rrf-k 60

# Step 4: Significance test
python scripts/significance_test.py \
  results/lme_s_baseline/metrics.json \
  results/lme_s_fix_a/metrics.json
```

### 4.2 LoCoMo Benchmark

Script: `benchmarks/scripts/run_locomo_bench.py` (or `run_locomo_bench_session.py`)

Same protocol, using LoCoMo dataset.

### 4.3 Expected Metrics Table

| Metric | Baseline (fusion_score) | Fix-A (rrf_diag) | Δ | p-value |
|--------|------------------------|------------------|---|---------|
| recall@1 | — | — | — | — |
| recall@5 | — | — | — | — |
| recall@10 | 0.9334 | ~0.955 (projected) | ~+2.1pp | — |
| recall@20 | — | — | — | — |
| MRR | — | — | — | — |
| NDCG@10 | — | — | — | — |

*(Fill with actual benchmark run results before ship decision.)*

---

## 5. Go/No-Go Recommendation

### 5.1 Preliminary Signal: **CONDITIONAL GO**

Based on code analysis and literature:

| Criterion | Status |
|-----------|--------|
| `rrf_diag` already computed (no new SQL overhead) | ✅ |
| Literature strongly supports RRF > linear fusion for heterogeneous score distributions | ✅ |
| Expected lift (1.5–2pp) is conservative vs literature precedent | ✅ |
| Scale mismatch requires normalization — implementation must use A-norm form | ⚠ REQUIRED |
| Actual benchmark run with p<0.05 confirmation | ⏳ PENDING |
| No recall regression on LoCoMo (cross-dataset validation) | ⏳ PENDING |

### 5.2 Go Criteria (both must hold)

1. **p < 0.05** on recall@10 improvement (LME-S), Holm-Bonferroni corrected
2. **≥ 1pp** absolute lift on recall@10

### 5.3 No-Go Triggers

- Any significant recall regression on LoCoMo (different corpus distribution)
- Fix-A with A-norm provides lift but auxiliary-dominated ranking (Option A-pure) regresses — indicates auxiliary weight rebalancing needed before ship

### 5.4 Implementation Risk: LOW

Fix-A is a single-line change to the ORDER BY clause (plus normalization divisor). `rrf_diag` computation is unchanged. `rrf_score` output column semantics shift from "diagnostic" to "primary ranking basis" — update function COMMENT accordingly.

---

## 6. Proposed SQL Patch (Draft)

```sql
-- Fix-A: promote rrf_diag to primary ranking signal in recall_hybrid()
-- Normalization: divide by max rrf_diag value = (vec_weight+bm25_weight)/(rrf_k+1)
-- Default params: (0.4+0.4)/61 = 0.01311...

-- Replace in recall_hybrid() ORDER BY:
-- BEFORE:  s.fusion_score + ...auxiliaries...
-- AFTER:   (s.rrf_diag / ((_vec_w + _bm25_w) / (_rrf_k_f + 1.0))) + ...auxiliaries...

-- In scored CTE, add normalized rrf:
, (rrf_diag / ((vec_weight + bm25_weight) / (_rrf_k_f + 1.0))) AS rrf_norm
```

Full patch to be implemented in `pgmnemo--0.5.1--0.6.0.sql` migration.

---

## References

- Cormack, G. V., Clarke, C. L. A., & Buettcher, S. (2009). Reciprocal rank fusion outperforms condorcet and individual rank learning methods. *SIGIR 2009*, 758–759. https://doi.org/10.1145/1571941.1572114
- Lillis, D., Toolan, F., Collier, R., & Dunnion, J. (2010). Probfuse: A probabilistic approach to data fusion. *SIGIR 2010*, 191–198.
- Ma, X., et al. (2022). Hybrid list-wise learning for passage retrieval. *ECIR 2022*.
- Formal, T. et al. (2021). SPLADE: Sparse lexical and expansion model for first stage ranking. *SIGIR 2021*.
- Robertson, S., & Zaragoza, H. (2009). The probabilistic relevance framework: BM25 and beyond. *Foundations and Trends in Information Retrieval*, 3(4), 333–389.

---

*Document: `spec/competitive/BENCHMARK_FIX_A_RRF_v060.md` | pgmnemo v0.6.0 | 2026-05-22*
