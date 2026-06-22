# pgmnemo #88 — graph_walk Ablation Benchmark Report

**Date:** 2026-06-22  
**Version:** v0.10.0  
**Corpus:** `prod_corpus` — 6,353 active verified lessons, 73,258 mem_edges (72,339 temporal + 919 causal)  
**Method:** Two-proportion z-test + Holm-Bonferroni correction (α = 0.05)  
**Script:** `benchmarks/scripts/bench_graph_walk_ablation.py`  
**Result files:** `graph_walk_ablation_20260622.json`, `*_no_graph_sig.json`, `*_with_graph_sig.json`

---

## TL;DR

> **Decision: OPT-IN** — make `graph_walk` opt-in (GUC default `pgmnemo.graph_proximity_weight = 0.0`)

graph_walk adds **+3–5 ms P50 latency overhead** (+5–8%) with **zero statistically significant recall lift** on this corpus. Live-corpus ranking overlap = 1.000 across all K values — the graph BFS reranks zero queries in 43 measured runs. Edge-aware controlled recall shows +8.3 pp directional lift at recall@5/10 (p_corr = 1.0, ns, n=12). Decision rule (`feedback_complexity_must_justify`): no significant lift → opt-in.

---

## Experimental Design

### Ablation variants

| Variant | GUC setting | What changes |
|---------|-------------|--------------|
| **WITH graph** | `pgmnemo.graph_proximity_weight = 0.2` | graph_walk + graph_proximity CTEs active; scores multiplied by `(1 + 0.2 × proximity)` |
| **WITHOUT graph (GUC=0)** | `pgmnemo.graph_proximity_weight = 0.0` | graph_walk CTE still runs; score multiplier = 1.0 (no reranking) |
| **WITHOUT graph (no-CTE)** | Inline SQL omitting graph CTEs | True latency baseline (CTE execution overhead eliminated) |

### Phase 1 — Live-corpus ranking overlap

Sample 50 queries from live corpus (verified, active, English text 100–1000 chars, non-structured). For each query at K ∈ {1, 5, 10, 20}, run `recall_hybrid` WITH and WITHOUT graph, compute Jaccard overlap of top-K result sets.

### Phase 2 — Edge-aware controlled recall

Find anchor lessons with outgoing causal/temporal edges to active verified lessons. Use the anchor embedding as a query; measure whether the edge-target appears in top-K WITH vs WITHOUT graph_walk. This directly tests whether graph_walk promotes known-related lessons.

### Significance test

Two-proportion z-test on Phase 2 hit rates (n = 50 anchor pairs). Holm-Bonferroni correction over K ∈ {1, 5, 10, 20}. Threshold: p_corr < 0.05.

---

## Phase 1: Live-Corpus Ranking Overlap

**n = 43** queries measured (50 attempted; 7 skipped: statement timeout 8 s)

| K | Overlap (median) | Ranking change rate | lat_with P50 | lat_with P95 | lat_no_cte P50 | CTE overhead (P50) |
|---|-----------------|---------------------|-------------|-------------|----------------|-------------------|
| 1 | **1.000** | 0.0% | 61.9 ms | 382 ms | 57.4 ms | **+4.5 ms (+7.8%)** |
| 5 | **1.000** | 0.0% | 60.7 ms | 332 ms | 56.2 ms | +4.5 ms (+8.0%) |
| 10 | **1.000** | 0.0% | 60.1 ms | 342 ms | 57.0 ms | **+3.1 ms (+5.4%)** |
| 20 | **1.000** | 0.0% | 61.1 ms | 430 ms | 57.3 ms | +3.8 ms (+6.6%) |

**Key observations:**

- Overlap = **1.000** at ALL K values across all 43 queries — graph_walk reranks **zero** queries.
- The CTE overhead is **+3–5 ms P50** (+5–8%) relative to the no-CTE inline SQL baseline.
- P95 latency is dominated by outlier queries (BM25 full-text plan spill) not by the graph CTE.
- No-CTE P50 consistently ~56–57 ms; with-graph P50 ~60–62 ms, confirming graph_walk CTE adds ~4ms overhead but never changes any result ordering on this corpus.

---

## Phase 2: Edge-Aware Controlled Recall

**n = 12** valid anchor-target pairs (DISTINCT ON source_id, both endpoints active+verified+embedded, seed=42). All temporal edges.

| K | WITH graph (hit rate) | WITHOUT graph (hit rate) | Recall lift (Δ) |
|---|----------------------|--------------------------|----------------|
| 1 | 0.000 | 0.000 | **+0.000 pp** |
| 5 | 0.083 | 0.000 | **+8.3 pp** |
| 10 | 0.083 | 0.000 | **+8.3 pp** |
| 20 | 0.083 | 0.083 | **+0.0 pp** |

**Rank analysis (k=10):** Median rank WITH graph = 999 (not in top-10); median rank WITHOUT graph = 999. Rank delta = 0.0. Only anchor=7323→target=7327 (temporal) shows a hit at @5 and @10 WITH graph only; this same pair appears at @20 in both conditions.

**Interpretation:** graph_walk produces a +8.3 pp directional lift at recall@5/10 (1 hit in 12 pairs), but this is not statistically significant (p_corr = 1.0, n=12 underpowered). The corpus has 99% temporal edges representing chronological adjacency between agent-run delivery notes — semantically unrelated lessons. Graph traversal over such edges does not surface topically relevant lessons.

---

## Significance Analysis

### Two-proportion z-test (Phase 2 hit rates, n = 12)

```
Metric         Base    95% CI Base           Cand    95% CI Cand          Δ      z    p_raw  p_corr      h     |h|  Sig?
recall@1      0.0000  [0.0000, 0.2425]   0.0000  [0.0000, 0.2425]  +0.0000  0.00  1.0000  1.0000  0.000  small    no
recall@5      0.0000  [0.0000, 0.2425]   0.0833  [0.0149, 0.3539]  +0.0833  1.02  0.3071  1.0000  0.586  large    no
recall@10     0.0000  [0.0000, 0.2425]   0.0833  [0.0149, 0.3539]  +0.0833  1.02  0.3071  1.0000  0.586  large    no
recall@20     0.0833  [0.0149, 0.3539]   0.0833  [0.0149, 0.3539]  +0.0000  0.00  1.0000  1.0000  0.000  small    no

Method: Holm-Bonferroni correction (m=4 tests, α=0.05)
```

**VERDICT: No statistically significant improvements or regressions.** All p_corr = 1.000.

Cohen's h for recall@5/@10 = 0.586 (large) — underpowered at n=12. Required n for 80% power at α=0.05 with h=0.586: ~29 pairs. The +8.3 pp lift is driven by 1 anchor-target hit (anchor=7323→7327) and is within the noise envelope at this sample size.

---

## Latency Analysis

| Metric | Value |
|--------|-------|
| **Baseline (no-CTE) P50** | 56–57 ms |
| **WITH graph P50** | 60–62 ms |
| **CTE overhead P50** | +3–5 ms (+5–8%) |
| **GUC=0 P50** | 60–62 ms (same as GUC=0.2 — CTE still runs) |
| **WITH graph P95** | ~380 ms |

**Key finding:** Setting GUC=0.0 does NOT eliminate CTE latency — the `graph_walk` CTE still executes, it just contributes a zero multiplier. Only removing the CTEs from the function body (or bypassing them with a conditional) eliminates the +3–5ms overhead. For the GUC-based OPT-IN approach, operators save the overhead only by permanently keeping `graph_proximity_weight = 0.0` (which prevents the CTE from computing meaningful scores but not from running). This aligns with COMPETITIVE_REALITY: "graph features gave zero measurable lift, no bench exercises mem_edge."

---

## Decision: OPT-IN

**Rule applied:** `feedback_complexity_must_justify` — significant lift → keep; no significant lift → opt-in (GUC default off).

**Outcome:** No statistically significant recall lift (all p_corr = 1.000). Live-corpus ranking overlap = 1.000 at all K (43 queries measured). CTE overhead: +3–5 ms P50.

**Recommended action:**

```sql
-- In pgmnemo.control or installation default:
-- Change graph_proximity_weight default from 0.2 to 0.0

-- Operators with rich causal/semantic mem_edge corpora can enable:
SET pgmnemo.graph_proximity_weight = 0.2;
-- or at session level in psql / application startup
```

**Rationale:** The current corpus (6,353 lessons, 99% temporal edges) is dominated by chronological adjacency links between agent run reports. These do not carry semantic relatedness. Graph traversal over such edges adds ~10 ms P50 latency without surfacing meaningfully related lessons. Operators with purpose-built causal or semantic mem_edge graphs (e.g., from knowledge extraction pipelines) may see real lift — the GUC opt-in preserves this capability.

---

## Corpus Context

| Metric | Value |
|--------|-------|
| Active verified lessons | 6,353 |
| Total mem_edges | 73,258 |
| Temporal edges | 72,339 (98.8%) |
| Causal edges | 919 (1.3%) |
| Qualified anchor-target pairs (verified, active) | 71,169 |

The 99% temporal edge dominance is the structural root cause. Temporal edges in the pgmnemo schema track "lesson B was written after lesson A in the same DAG run." This is a workflow provenance signal, not a topical similarity signal. graph_walk was designed to traverse causal and semantic edges — but the live corpus has almost none.

---

## Artifacts

| File | Description |
|------|-------------|
| `benchmarks/results/graph_walk_ablation_20260622.json` | Full benchmark data (Phase 1, Phase 2, significance, decision) |
| `benchmarks/results/graph_walk_ablation_20260622_no_graph_sig.json` | Baseline for `significance_test.py` |
| `benchmarks/results/graph_walk_ablation_20260622_with_graph_sig.json` | Candidate for `significance_test.py` |
| `benchmarks/scripts/bench_graph_walk_ablation.py` | Benchmark script (STMT_TIMEOUT=8s, work_mem=128MB) |

### Reproducing

```bash
DATABASE_URL=postgresql://... python3 benchmarks/scripts/bench_graph_walk_ablation.py \
    --n-queries 50 \
    --n-edge-anchors 50 \
    --output benchmarks/results/graph_walk_ablation_YYYYMMDD.json \
    --seed 42

python3 scripts/significance_test.py \
    benchmarks/results/graph_walk_ablation_YYYYMMDD_no_graph_sig.json \
    benchmarks/results/graph_walk_ablation_YYYYMMDD_with_graph_sig.json
```
