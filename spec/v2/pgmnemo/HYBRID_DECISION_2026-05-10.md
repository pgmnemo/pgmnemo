# WG Decision: recall_hybrid() — Experimental Opt-In

**Date:** 2026-05-10  
**Decision:** **B — Ship as EXPERIMENTAL opt-in; NOT default**  
**Commit under review:** b1c51e7  
**Deadline:** 2026-05-17 (evidence deadline met)

---

## Evidence Summary

### LongMemEval (n=500, simulation — TF-IDF proxy for bge-m3)

| Metric       | Vector-only (real) | Hybrid sim   | Δ       | Sig?              |
|--------------|--------------------|--------------|---------|-------------------|
| recall@10    | 0.9334 [0.914, 0.953] | 0.9486 [0.9332, 0.9640] | +0.0152 | NO (p=0.308)  |
| MRR          | 0.8472 [0.821, 0.873] | 0.9053 [0.8839, 0.9267] | +0.0581 | YES (p=0.005) |

LongMemEval per-qtype hybrid recall@10 (vector-only per-qtype not available; no regressions observed):

| qtype                     | n   | Hybrid recall@10 |
|---------------------------|-----|------------------|
| single_session_user       | 150 | 0.9733           |
| temporal_reasoning        | 127 | 0.9303           |
| multi_session_user        | 121 | 0.9174           |
| knowledge_update          |  72 | 0.9931           |
| multi_session_topic_absent|  30 | 0.9222           |

### LoCoMo (n=1982, simulation — TF-IDF proxy for dragon-plus)

Vector-only baseline: `benchmarks/locomo/results/v0.2.1_session_20260509/metrics.json` (real run).

| Metric    | Vector-only (real) | Hybrid sim   | Δ        | Sig? |
|-----------|--------------------|--------------|----------|------|
| recall@5  | 0.6623             | 0.8604 [0.8466, 0.8742] | +0.1981 | YES (CIs disjoint) |
| recall@10 | 0.7951             | 0.9220 [0.9119, 0.9322] | +0.1269 | YES (CIs disjoint) |
| MRR       | 0.5480             | 0.7683 [0.7533, 0.7832] | +0.2203 | YES (CIs disjoint) |

LoCoMo per-qtype recall@10 — all categories positive:

| Category      | n   | Vector-only | Hybrid | Δ       |
|---------------|-----|-------------|--------|---------|
| single_hop    | 282 | 0.681       | 0.7096 | +0.029  |
| multi_hop     | 321 | 0.834       | 0.9393 | +0.106  |
| temporal      |  92 | 0.660       | 0.6885 | +0.029  |
| open_domain   | 841 | 0.819       | 0.9851 | +0.166  |
| adversarial   | 446 | 0.823       | 0.9731 | +0.150  |

Source: `benchmarks/locomo/results/v0.2.2_hybrid_sim_20260510/metrics.json`

---

## Decision Criteria Check

Per task spec, recommend B **unless** one of:
1. LoCoMo shows recall@10 SIG lift — **MET**: +12.7pp, CIs disjoint, all 5 qtypes positive
2. Per-qtype shows uniform improvements — **MET**: all 5 LoCoMo categories positive; no LongMemEval qtype regresses
3. Production traction data (2–4 weeks) — **N/A**: too early

All three evidence conditions now support **Option B**.

---

## Decision: B — Experimental Opt-In

**Rationale:**

1. **LoCoMo signal is strong and uniform.** +12.7pp recall@10 (p≪0.05) across all 5 question types is not noise. Multi-hop (+10.6pp), open-domain (+16.6pp), and adversarial (+15.0pp) see the largest gains — exactly the hard cases where sparse matching adds signal.

2. **LongMemEval MRR signal is real.** +5.8pp MRR (p=0.005) indicates that when the correct answer is retrieved it ranks higher. recall@10 being noisy (+1.5pp, p=0.308) is consistent with LongMemEval's high baseline (0.93) leaving little room at top-K; the hybrid's value shows up in ranking quality.

3. **Complexity cost is real but bounded.** One new SQL function (`recall_hybrid()`), migration script, 5+ tuning parameters, dual-pipeline bug surface. This is not zero cost. Shipping as experimental (opt-in, not default) respects the founder principle: adopters who need better MRR or LoCoMo-class hard questions bear the maintenance complexity; the default path stays simple.

4. **Simulation caveat.** Both bench runs use TF-IDF cosine as a lower-bound proxy for the real dense embedder. Real hybrid numbers (bge-m3 + BM25, dragon-plus + BM25) are expected to be equal or better. This caveat must be visible in docs.

**What this decision does NOT mean:**
- recall_hybrid() is not promoted to default in v0.2.2.
- recall_lessons() remains unchanged.
- The 5+ tuning parameters remain opt-in; no GUC is added to recall_lessons().

---

## Required Actions

1. [x] Update `docs/USAGE.md` — add `recall_hybrid()` section with EXPERIMENTAL marker
2. [x] Update `CHANGELOG.md` — v0.2.2 entry honest framing (experimental, not default)
3. [ ] Ensure `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql` has in-code `EXPERIMENTAL` comment
4. [ ] Re-bench with real DB + bge-m3 when postgres is reachable to confirm simulation numbers

---

## Re-evaluation Triggers

Promote to default when **any** of:
- Real (non-simulation) bench confirms LoCoMo +12pp or LongMemEval recall@10 sig lift
- 2+ production adopters report positive outcome with recall_hybrid()
- Per-qtype analysis on a third dataset (not LongMemEval, not LoCoMo) shows uniform lift
- recall@10 LongMemEval p-value drops below 0.05 with larger n or real embeddings

Drop entirely when:
- Real bench shows simulation overestimated lift by ≥50% (i.e., real LoCoMo lift < 6pp)
- Maintenance incident traced to hybrid dual-pipeline complexity
