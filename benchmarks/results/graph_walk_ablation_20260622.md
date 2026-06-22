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

graph_walk adds **~10 ms P50 latency overhead** (+16%) with **zero statistically significant recall lift** on this corpus. Live-corpus ranking overlap = 1.000 at k=10 — the graph BFS reranks no queries. Edge-aware controlled recall shows a +6 pp directional lift at recall@5 (p_corr = 0.31, ns). Decision rule (`feedback_complexity_must_justify`): no significant lift → opt-in.

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

**n = 46** queries measured (50 attempted; 4 skipped: statement timeout 8 s)

| K | Overlap (median) | Ranking change rate | lat_with P50 | lat_with P95 | lat_no_cte P50 | CTE overhead (P50) |
|---|-----------------|---------------------|-------------|-------------|----------------|-------------------|
| 1 | **1.000** | 0.0% | 73.8 ms | 286.6 ms | 61.2 ms | **+12.6 ms** |
| 5 | 0.800 | 20.0% | 69.0 ms | 156.8 ms | 60.3 ms | +8.6 ms |
| 10 | **1.000** | 0.0% | 71.6 ms | 164.7 ms | 61.9 ms | **+9.7 ms** |
| 20 | 0.975 | 2.5% | 69.9 ms | 202.0 ms | 61.4 ms | +8.5 ms |

**Key observations:**

- At k=1 and k=10, graph_walk changes **zero** rankings (overlap = 1.000). The top returned lesson and the top-10 set are identical WITH vs WITHOUT graph.
- At k=5, the median overlap is 0.800 (1 lesson in 5 differs). This occurs for ~20% of queries — graph_walk reorders within the top-5 for some queries, but usually the #5 item changes while items 1–4 are stable.
- The CTE overhead is **+9–13 ms at P50** (15–21% relative to no-CTE baseline). At P95, overhead can reach 80–225 ms (graph BFS expanding over temporal edge chains).
- No-CTE P50 latency is consistently ~60–62 ms regardless of K, confirming the graph_walk CTE is responsible for the overhead variance.

---

## Phase 2: Edge-Aware Controlled Recall

**n = 50** anchor-target pairs, all temporal edges (causal edge qualified pairs were included in the sample but the 50 drawn were all temporal).

| K | WITH graph (hit rate) | WITHOUT graph (hit rate) | Recall lift (Δ) |
|---|----------------------|--------------------------|----------------|
| 1 | 0.000 | 0.000 | **+0.000 pp** |
| 5 | 0.060 | 0.000 | **+6.0 pp** |
| 10 | 0.060 | 0.020 | **+4.0 pp** |
| 20 | 0.080 | 0.060 | **+2.0 pp** |

**Rank analysis (k=10):** Median rank WITH graph = 999 (not in top-10); median rank WITHOUT graph = 999. Rank delta = 0.0. In most cases, the edge-target lesson does not appear in top-10 under either condition.

**Interpretation:** graph_walk produces a small directional recall lift (+2–6 pp), but absolute hit rates are very low (0–8%). This reflects the corpus structure: 99% of edges (72,339 / 73,258) are temporal "happened-after" edges between chronologically adjacent agent run reports. These lessons are not semantically related — they are records of different tasks. Graph traversal over temporal chains does not surface semantically relevant lessons.

---

## Significance Analysis

### Two-proportion z-test (Phase 2 hit rates, n = 50)

```
Metric         Base    95% CI Base           Cand    95% CI Cand          Δ      z    p_raw  p_corr      h     |h|  Sig?
recall@1      0.0000  [0.0000, 0.0714]   0.0000  [0.0000, 0.0714]  +0.0000  0.00  1.0000  1.0000  0.000  small    no
recall@5      0.0000  [0.0000, 0.0714]   0.0600  [0.0206, 0.1622]  +0.0600  1.76  0.0786  0.3144  0.495 medium    no
recall@10     0.0200  [0.0035, 0.1050]   0.0600  [0.0206, 0.1622]  +0.0400  1.02  0.3074  0.9222  0.211 medium    no
recall@20     0.0600  [0.0206, 0.1622]   0.0800  [0.0315, 0.1884]  +0.0200  0.39  0.6951  1.0000  0.079  small    no

Method: Holm-Bonferroni correction (m=4 tests, α=0.05)
```

**VERDICT: No statistically significant improvements or regressions.** All p_corr ≥ 0.31. The best raw p-value (recall@5, p_raw = 0.079) does not survive Holm-Bonferroni correction (p_corr = 0.314).

Cohen's h for recall@5 = 0.495 (medium effect size), but confidence intervals are wide due to very low baseline rates. The +6 pp lift at recall@5 is within the noise envelope for n=50.

---

## Latency Analysis

| Metric | Value |
|--------|-------|
| **Baseline (no-CTE) P50** | 60–62 ms |
| **WITH graph P50** | 69–74 ms |
| **CTE overhead P50** | +9–13 ms (+15–21%) |
| **WITH graph P95** | 157–287 ms |
| **CTE overhead P95** | estimated +70–220 ms |

The latency overhead is meaningful at P95: the graph BFS over 73K temporal edges can trigger long chains, adding 70–220 ms on 5% of queries. This aligns with the COMPETITIVE_REALITY observation: "graph features gave zero measurable lift, no bench exercises mem_edge."

---

## Decision: OPT-IN

**Rule applied:** `feedback_complexity_must_justify` — significant lift → keep; no significant lift → opt-in (GUC default off).

**Outcome:** No statistically significant recall lift (all p_corr ≥ 0.31). Live-corpus ranking overlap = 1.000 at k=10.

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
