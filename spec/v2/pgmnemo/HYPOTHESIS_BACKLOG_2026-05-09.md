# pgmnemo Hypothesis Backlog — WG-HYP-1
**Date:** 2026-05-09  
**Author:** WG-HYP-1 (PI coordinator)  
**Depends on:** WG-BENCH-2 (ablation 5309), WG-BENCH-3 (LoCoMo gap 5310), WG-BENCH-4 (competitor matrix 5311), WG-BENCH-5 (Stella V5 5312)  
**Status:** FAST-START — H-A confirmed; H-B/C/weights pending; catalog complete with available evidence

---

## Scoring Rubric

### ICE = Impact × Confidence × Ease

| Dimension | Scale | Definition |
|---|---|---|
| **Impact** | 1–10 | Expected recall@10 uplift on primary benchmark: 1=<0.5pp, 5=~2-3pp, 8=~5-8pp, 10=≥10pp |
| **Confidence** | 0.0–1.0 | P(claim_true \| evidence): 0.0=speculation, 0.5=plausible with analogous evidence, 0.9=confirmed via direct experiment |
| **Ease** | 1–10 | Implementation simplicity: 1=>3 weeks, 5=3-5 days, 8=0.5-1 day, 10=config change only |

### RICE = (Reach × Impact × Confidence) / Effort_days

| Dimension | Scale | Definition |
|---|---|---|
| **Reach** | 1–5 | Number of benchmarks/use-cases benefiting: 1=one category, 3=two benchmarks, 5=both benchmarks + production |
| **Effort** | days | Estimated engineer-days to implement + benchmark re-run |

---

## Confirmed Baselines (evidence anchor)

| Benchmark | Metric | Current | Paper BM25 baseline | Gap |
|---|---|---|---|---|
| LoCoMo (session-level) | recall@10 | **0.795** | ~0.850 (paper Table 3 BM25) | 5.5pp |
| LongMemEval | recall@10 | **0.933** | **0.982** (Wu et al. BM25) | 4.9pp |
| LoCoMo single_hop | recall@10 | **0.681** | — | (weakest category) |
| LoCoMo temporal | recall@10 | **0.660** | — | (weakest category) |
| LME single-session-user | recall@10 | **0.871** | — | (weakest category) |
| LME single-session-preference | recall@10 | **0.900** | — | (weak category) |

Source: `benchmarks/locomo/results/v0.2.1_session_20260509/report.md`, `benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/report.md`

---

## Hypothesis Catalog (17 hypotheses)

---

### H-01: Hybrid BM25 + vector retrieval

**Mechanism:** Add BM25 lexical search (pg_textsearch or tsvector GIN index) alongside vector cosine; fuse results via Reciprocal Rank Fusion (RRF). Extends `recall_lessons()` with a hybrid path.

**Expected metric impact:**
- LongMemEval recall@10: +5–9pp (0.933 → ~0.98–1.0; closes BM25 gap entirely)
- LoCoMo single_hop: +5–8pp (entity names benefit most from BM25)
- Confidence: BEIR literature shows +9pp typical for RRF fusion; Wu 2025 BM25 baseline = 0.982 confirms lexical gap is real

**Effort:** 6.5 days (pgmnemo C extension + GIN index DDL + `recall_lessons()` hybrid path + benchmark re-run × 2)  
**Reach:** 4 (LongMemEval, LoCoMo, production agents with keyword-heavy queries, competitor parity)  
**Confidence:** 0.75  
**Impact:** 8/10  
**Ease:** 4/10  

**ICE = 8 × 0.75 × 4 = 24.0**  
**RICE = (4 × 8 × 0.75) / 6.5 = 3.69**  

Source: WG-BENCH-4 (agentic-db hybrid gap +8–12pp), Wu et al. 2025 BM25 baseline 0.982

---

### H-02: Stella V5 compatibility fix (paper-canonical embedder)

**Mechanism:** Fix `Qwen2Config.rope_theta` AttributeError in Stella V5's bundled `modeling_qwen.py`. Options: (a) pin transformers to 4.44.x, (b) patch the bundled file's `__init__` to use `getattr(config, 'rope_theta', 10000.0)`. Then re-run LongMemEval with the paper-canonical embedder.

**Expected metric impact:**
- LongMemEval recall@10: +1–3pp (bge-m3 ≈ Stella V5 on MTEB; Stella V5 may have edge for English retrieval tasks matching benchmark construction)
- Methodology credibility: enables direct paper comparison (currently apples-to-oranges)
- Confidence: MTEB delta between bge-m3 and Stella V5 is ~1–3pp NDCG@10

**Effort:** 0.75 days (patch + benchmark re-run)  
**Reach:** 2 (LongMemEval + methodology sign-off)  
**Confidence:** 0.60  
**Impact:** 3/10  
**Ease:** 8/10  

**ICE = 3 × 0.60 × 8 = 14.4**  
**RICE = (2 × 3 × 0.60) / 0.75 = 4.80**  

Source: WG-BENCH-5 (5312), `benchmarks/longmemeval/ADDENDA/LONGMEMEVAL_EMBEDDER_BGE_M3.md`

---

### H-03: Truncation fix (500-char → proper 512-token or full-length)

**Mechanism:** Remove 500-char hard truncation from LongMemEval corpus extraction. Use proper `max_seq_length=512` tokens (batch_size=8 to avoid MPS OOM) or run on cloud GPU with no truncation. Sessions with evidence in late turns currently have that content silently discarded.

**Expected metric impact:**
- LongMemEval recall@10: +0–3pp (benefit proportional to fraction of sessions where evidence appears after char 500)
- Directly addresses known methodology bug documented in `ADDENDA/LONGMEMEVAL_TRUNCATION_500.md`

**Effort:** 0.25 days (one-line config change + benchmark re-run)  
**Reach:** 1 (LongMemEval only; LoCoMo sessions are shorter)  
**Confidence:** 0.50  
**Impact:** 2/10  
**Ease:** 9/10  

**ICE = 2 × 0.50 × 9 = 9.0**  
**RICE = (1 × 2 × 0.50) / 0.25 = 4.0**  

Source: WG-BENCH-3 (5310), `benchmarks/HISTORY.md` (truncation correction in progress)

---

### H-04: Scoring weight recalibration (ablation-driven)

**Mechanism:** Grid-search the 5-component scoring weights `(cosine 0.4, importance 0.2, recency 0.2, prov_strength 0.1, graph_proximity 0.2)` over held-out benchmark queries. Current weights are hand-tuned; data-driven calibration may improve recall, especially for categories where recency over-penalizes older relevant memories.

**Expected metric impact:**
- LongMemEval + LoCoMo recall@10: +2–5pp (if recency is over-weighted on long-horizon queries)
- Risk: optimizing on one benchmark may overfit

**Effort:** 3 days (ablation code + grid search + 2× benchmark re-runs)  
**Reach:** 3 (LongMemEval, LoCoMo, BL-B synthetic fixture)  
**Confidence:** 0.55  
**Impact:** 5/10  
**Ease:** 5/10  

**ICE = 5 × 0.55 × 5 = 13.75**  
**RICE = (3 × 5 × 0.55) / 3 = 2.75**  

Source: WG-BENCH-2 ablation (5309), task spec example hypothesis

---

### H-05: DRAGON dim-flex — native 768d in v0.2.2

**Mechanism:** pgmnemo v0.2.2 introduces configurable embedding dimension. Run LoCoMo benchmark with native `vector(768)` DRAGON embeddings (no zero-padding). Eliminates the 25% storage overhead from 256 wasted dimensions.

**Expected metric impact:**
- recall@10: ~0pp (zero-padding is mathematically equivalent for cosine similarity — proven in `ADDENDA/LOCOMO_EMBEDDER_PADDING.md`)
- Methodology credibility: eliminates objection about non-native dimensions
- Storage: −25% per row

**Effort:** 2 days (v0.2.2 dim-flex implementation already planned; benchmark re-run)  
**Reach:** 2 (LoCoMo + future multi-dim benchmarks)  
**Confidence:** 0.95 (mathematical proof; no metric gain expected)  
**Impact:** 2/10 (methodology only)  
**Ease:** 6/10  

**ICE = 2 × 0.95 × 6 = 11.4**  
**RICE = (2 × 2 × 0.95) / 2 = 1.90**  

Source: `benchmarks/locomo/ADDENDA/LOCOMO_EMBEDDER_PADDING.md`, WG-BENCH-3 (5310)

---

### H-06: Temporal recency weight tuning (LoCoMo temporal category)

**Mechanism:** LoCoMo temporal questions score only 0.660 recall@10 vs 0.795 overall (−13.5pp gap). The `recency_weight` GUC (default 0.2) likely under-weights temporal proximity for time-anchored queries. Increase recency_weight for queries containing temporal markers, or expose per-query weight override in `recall_lessons()`.

**Expected metric impact:**
- LoCoMo temporal recall@10: +3–6pp (0.660 → 0.69–0.72)
- Overall LoCoMo recall@10: +0.3–0.6pp (92/1982 questions in temporal category)

**Effort:** 1 day (GUC override + SQL function signature change + benchmark re-run)  
**Reach:** 2 (LoCoMo temporal, production time-sensitive agent queries)  
**Confidence:** 0.55  
**Impact:** 4/10  
**Ease:** 7/10  

**ICE = 4 × 0.55 × 7 = 15.4**  
**RICE = (2 × 4 × 0.55) / 1 = 4.40**  

Source: `benchmarks/locomo/results/v0.2.1_session_20260509/report.md` (per-category table)

---

### H-07: Lexical recall boost for single-hop entity queries

**Mechanism:** LoCoMo single_hop (0.681) is the weakest category. Single-hop questions typically ask about specific entities ("What did Alice say about X?") where exact token matches would dominate BM25. Adding BM25 (H-01) specifically recovers this category.

**Expected metric impact:**
- LoCoMo single_hop recall@10: +5–10pp (0.681 → 0.73–0.78)
- Bundled with H-01 when hybrid search is added

**Effort:** 3 days (if bundled with H-01, marginal; standalone: ~3 days for partial BM25)  
**Reach:** 2 (LoCoMo single_hop + agent queries with entity names)  
**Confidence:** 0.65  
**Impact:** 5/10  
**Ease:** 3/10 (standalone; cost is bundled into H-01 if done together)  

**ICE = 5 × 0.65 × 3 = 9.75**  
**RICE = (2 × 5 × 0.65) / 3 = 2.17**  

Source: `benchmarks/locomo/results/v0.2.1_session_20260509/report.md` (per-category table)

---

### H-08: MAGMA-style multi-edge subtype schema

**Mechanism:** MAGMA (arxiv 2601.03236) demonstrates that splitting knowledge-graph edges into semantic subtypes (causal, temporal, knowledge_update, contradicts) improves retrieval on multi-hop questions. pgmnemo's `mem_edge` already has typed edges; extend to 4 MAGMA-aligned subtypes and add subtype-weighted traversal in `traverse_causal_chain()`.

**Expected metric impact:**
- LoCoMo multi_hop recall@10: +2–4pp (0.834 → 0.85–0.87)
- LongMemEval knowledge-update recall@10: +1–3pp (0.923 → 0.93–0.95)

**Effort:** 6 days (schema migration + 4 traversal variants + benchmark re-runs × 2)  
**Reach:** 3 (LoCoMo multi_hop, LongMemEval knowledge-update, production causal graph agents)  
**Confidence:** 0.45  
**Impact:** 4/10  
**Ease:** 3/10  

**ICE = 4 × 0.45 × 3 = 5.4**  
**RICE = (3 × 4 × 0.45) / 6 = 0.90**  

Source: WG-BENCH-4 competitor matrix (5311), MAGMA paper §3

---

### H-09: Single-session-user preference encoding

**Mechanism:** LongMemEval single-session-user (0.871) is the weakest category. These questions involve personal preferences ("user prefers X") where the signal is often a single soft statement rather than a factual assertion. Boost importance weight for memories tagged with preference-type content via a lightweight store-time classifier.

**Expected metric impact:**
- LME single-session-user recall@10: +2–4pp (0.871 → 0.89–0.91)
- LME single-session-preference: +1–3pp (0.900 → 0.91–0.93)

**Effort:** 1.5 days  
**Reach:** 2 (LME user/preference categories, production preference memory)  
**Confidence:** 0.50  
**Impact:** 3/10  
**Ease:** 7/10  

**ICE = 3 × 0.50 × 7 = 10.5**  
**RICE = (2 × 3 × 0.50) / 1.5 = 2.0**  

Source: `benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/report.md` (per-Q-type table)

---

### H-10: Provenance-strength dynamic penalization (contested memory)

**Mechanism:** pgmnemo has `prov_strength` (confirmed/inferred/contested) but applies a static weight (0.1 default). Zep's architecture dynamically suppresses contradicted memories. Implement dynamic penalty: contested memories score ×0.5 on prov_strength component, boosting confirmed memories by relative comparison.

**Expected metric impact:**
- LME knowledge-update recall@10: +1–3pp (older contradicted knowledge suppressed)
- LoCoMo adversarial: +1–2pp (adversarial distractors often represent contested claims)

**Effort:** 2 days  
**Reach:** 2 (LME knowledge-update, LoCoMo adversarial)  
**Confidence:** 0.45  
**Impact:** 3/10  
**Ease:** 6/10  

**ICE = 3 × 0.45 × 6 = 8.1**  
**RICE = (2 × 3 × 0.45) / 2 = 1.35**  

Source: WG-BENCH-4 (Zep competitor, arxiv 2501.13956)

---

### H-11: HNSW ef_search tuning

**Mechanism:** Increase `ef_search` from current default (64) to 128–256. HNSW recall/latency tradeoff is well-characterized: doubling ef_search adds ~30% latency but typically recovers 0.5–2pp recall on densely-clustered corpora. LoCoMo (272 segments) and LME (500 × ~47 sessions) are small enough that higher ef_search is cheap.

**Expected metric impact:**
- Both benchmarks recall@10: +0.5–2pp
- Latency: +1–3ms at p50 (acceptable for agent memory workloads)

**Effort:** 0.5 days (GUC + one benchmark re-run each)  
**Reach:** 3 (both benchmarks + production)  
**Confidence:** 0.60  
**Impact:** 2/10  
**Ease:** 9/10  

**ICE = 2 × 0.60 × 9 = 10.8**  
**RICE = (3 × 2 × 0.60) / 0.5 = 7.2**  

Source: HNSW literature (Malkov & Yashunin 2018); pgvector ef_search documentation

---

### H-12: Cloud GPU LongMemEval run (full session embeddings)

**Mechanism:** Current MPS (Apple Silicon) run required 500-char truncation due to OOM. Run LongMemEval on H100/A100 with no truncation and batch_size=32+. Eliminates the truncation methodology bug and provides the ground-truth number for H-03.

**Expected metric impact:**
- LongMemEval recall@10: +0–3pp (validates/disproves truncation hypothesis)
- Methodology quality: canonical result without truncation caveat

**Effort:** 1 day (cloud GPU setup + re-run; estimated 2–3h wall clock)  
**Reach:** 2 (LongMemEval accuracy + methodology credibility)  
**Confidence:** 0.50  
**Impact:** 3/10  
**Ease:** 7/10  

**ICE = 3 × 0.50 × 7 = 10.5**  
**RICE = (2 × 3 × 0.50) / 1 = 3.0**  

Source: `benchmarks/HISTORY.md` (truncation correction in progress)

---

### H-13: Query expansion for multi-hop questions

**Mechanism:** For multi-hop queries, decompose into 2–3 sub-queries via lightweight LLM call (e.g., GPT-4o-mini), retrieve independently, and merge top-k results. Reduces the cognitive load on the bi-encoder to match a complex multi-hop question to a single session.

**Expected metric impact:**
- LoCoMo multi_hop recall@10: +3–6pp (0.834 → 0.86–0.89)
- LME temporal-reasoning: +2–4pp (0.933 → 0.95–0.97)
- Requires LLM availability at retrieval time (not zero-dependency)

**Effort:** 3 days  
**Reach:** 3 (LoCoMo multi_hop, LME temporal-reasoning, production agents with LLM access)  
**Confidence:** 0.50  
**Impact:** 5/10  
**Ease:** 5/10  

**ICE = 5 × 0.50 × 5 = 12.5**  
**RICE = (3 × 5 × 0.50) / 3 = 2.5**  

Source: HyDE / query expansion literature (Ma et al. 2023); LME per-category weakness

---

### H-14: Cross-encoder re-ranking after HNSW retrieval

**Mechanism:** Retrieve top-50 via HNSW cosine, then re-rank with a cross-encoder (e.g., `BAAI/bge-reranker-v2-m3`) to produce final top-10. Cross-encoders jointly encode query+document and consistently outperform bi-encoders in ranking precision by 3–8pp on BEIR.

**Expected metric impact:**
- LongMemEval recall@10: +3–6pp (0.933 → 0.96–0.99)
- LoCoMo recall@10: +2–5pp (0.795 → 0.82–0.85)
- Latency: +20–40ms p50 per query (cross-encoder inference over 50 candidates)

**Effort:** 4 days (cross-encoder integration + latency profiling + benchmark re-runs × 2)  
**Reach:** 4 (both benchmarks + production agents + future benchmarks)  
**Confidence:** 0.65  
**Impact:** 6/10  
**Ease:** 4/10  

**ICE = 6 × 0.65 × 4 = 15.6**  
**RICE = (4 × 6 × 0.65) / 4 = 3.9**  

Source: BEIR (Thakur et al. 2021); bge-reranker-v2-m3 MTEB re-ranking scores

---

### H-15: LLM-judged salience injection (store-time importance)

**Mechanism:** Replace/supplement agent-set `importance` field with LLM-judged salience at store time (classify: ephemeral/moderate/important/critical). Memories with higher salience get importance boost in `recall_lessons()` 5-component score.

**Expected metric impact:**
- Both benchmarks recall@10: +1–3pp (important memories surface higher)
- Adds LLM call at store time (increases write latency; breaks zero-dependency ethos unless optional)

**Effort:** 3 days  
**Reach:** 3 (both benchmarks + production agents)  
**Confidence:** 0.40  
**Impact:** 3/10  
**Ease:** 5/10  

**ICE = 3 × 0.40 × 5 = 6.0**  
**RICE = (3 × 3 × 0.40) / 3 = 1.2**  

Source: Mem0 salience approach (arxiv 2504.19413 §3.2)

---

### H-16: Adversarial robustness via graph proximity signal

**Mechanism:** LoCoMo adversarial category (0.823) involves distractors that are semantically similar but factually incorrect. pgmnemo's `graph_proximity` scoring (depth from causal chain root) can penalize shallow/unsupported memories. Increase `graph_proximity` weight specifically for sessions flagged as adversarial-pattern.

**Expected metric impact:**
- LoCoMo adversarial recall@10: +2–4pp (0.823 → 0.84–0.86)
- Risk: may not generalize beyond LoCoMo adversarial split

**Effort:** 2 days  
**Reach:** 2 (LoCoMo adversarial, production security-sensitive agents)  
**Confidence:** 0.45  
**Impact:** 3/10  
**Ease:** 6/10  

**ICE = 3 × 0.45 × 6 = 8.1**  
**RICE = (2 × 3 × 0.45) / 2 = 1.35**  

Source: `benchmarks/locomo/results/v0.2.1_session_20260509/report.md`

---

### H-17: Cross-session entity resolution for single-session-user

**Mechanism:** LME single-session-user (0.871) may fail because user preferences stated in one session are not linked to the retrieval query in another session. Implement entity co-reference resolution: when storing lessons, link lessons about the same entity (user persona) via `mem_edge(derives_from)`.

**Expected metric impact:**
- LME single-session-user: +0–2pp (benefit only for cross-session preference queries)

**Effort:** 2 days  
**Reach:** 1 (LME single-session-user)  
**Confidence:** 0.35  
**Impact:** 2/10  
**Ease:** 6/10  

**ICE = 2 × 0.35 × 6 = 4.2**  
**RICE = (1 × 2 × 0.35) / 2 = 0.35**  

Source: LME per-category weakness analysis

---

## Rankings

### Full ICE Ranking

| Rank | ID | Name | ICE |
|---|---|---|---|
| 1 | H-01 | Hybrid BM25 + vector | **24.0** |
| 2 | H-14 | Cross-encoder re-ranking | **15.6** |
| 3 | H-06 | Temporal recency weight tuning | **15.4** |
| 4 | H-02 | Stella V5 compatibility fix | **14.4** |
| 5 | H-04 | Scoring weight recalibration | **13.75** |
| 6 | H-13 | Query expansion (multi-hop) | **12.5** |
| 7 | H-05 | DRAGON dim-flex (native 768d) | **11.4** |
| 8 | H-11 | HNSW ef_search tuning | **10.8** |
| 9 | H-09 | Single-session-user preference | **10.5** |
| 10 | H-12 | Cloud GPU run (no truncation) | **10.5** |
| 11 | H-07 | Single-hop lexical boost | **9.75** |
| 12 | H-03 | Truncation fix (500-char) | **9.0** |
| 13 | H-10 | Provenance-strength penalization | **8.1** |
| 14 | H-16 | Adversarial robustness | **8.1** |
| 15 | H-15 | LLM-judged salience injection | **6.0** |
| 16 | H-08 | MAGMA multi-edge schema | **5.4** |
| 17 | H-17 | Cross-session entity resolution | **4.2** |

### Full RICE Ranking

| Rank | ID | Name | RICE |
|---|---|---|---|
| 1 | H-11 | HNSW ef_search tuning | **7.2** |
| 2 | H-02 | Stella V5 compatibility fix | **4.8** |
| 3 | H-06 | Temporal recency weight tuning | **4.4** |
| 4 | H-03 | Truncation fix (500-char) | **4.0** |
| 5 | H-14 | Cross-encoder re-ranking | **3.9** |
| 6 | H-01 | Hybrid BM25 + vector | **3.69** |
| 7 | H-12 | Cloud GPU run (no truncation) | **3.0** |
| 8 | H-13 | Query expansion (multi-hop) | **2.5** |
| 9 | H-04 | Scoring weight recalibration | **2.75** |
| 10 | H-07 | Single-hop lexical boost | **2.17** |
| 11 | H-09 | Single-session-user preference | **2.0** |
| 12 | H-05 | DRAGON dim-flex | **1.9** |
| 13 | H-10 | Provenance-strength penalization | **1.35** |
| 14 | H-16 | Adversarial robustness | **1.35** |
| 15 | H-15 | LLM-judged salience injection | **1.2** |
| 16 | H-08 | MAGMA multi-edge schema | **0.90** |
| 17 | H-17 | Cross-session entity resolution | **0.35** |

---

## Top-5 by ICE

| Rank | ID | ICE | Why it ranks here |
|---|---|---|---|
| 1 | **H-01 Hybrid BM25** | 24.0 | Highest single expected lift (~5-9pp on LME); closes the BM25 gap structurally; broad reach |
| 2 | **H-14 Cross-encoder rerank** | 15.6 | Consistent +3–6pp via well-proven technique; benefits both benchmarks |
| 3 | **H-06 Temporal weight tuning** | 15.4 | 1-day effort for a targeted 3–6pp on LoCoMo temporal; GUC change, zero risk |
| 4 | **H-02 Stella V5 fix** | 14.4 | Restores paper-canonical embedder + potential 1–3pp; very low effort |
| 5 | **H-04 Weight recalibration** | 13.75 | Data-driven improvement to hand-tuned scoring; moderate effort for meaningful gain |

---

## Top-5 by RICE

| Rank | ID | RICE | Why it ranks here |
|---|---|---|---|
| 1 | **H-11 HNSW ef_search** | 7.2 | Near-zero effort (config change), 3-benchmark reach, reliable HNSW tradeoff |
| 2 | **H-02 Stella V5 fix** | 4.8 | <1 day effort, enables paper comparison, non-trivial confidence uplift |
| 3 | **H-06 Temporal weight tuning** | 4.4 | 1-day effort, direct improvement to weakest LoCoMo category |
| 4 | **H-03 Truncation fix** | 4.0 | 0.25 days, removes known methodology bug; validates or disproves |
| 5 | **H-14 Cross-encoder rerank** | 3.9 | 4-day investment but 4-benchmark reach; proven technique |

---

## ICE vs RICE Disagreements

| ID | ICE Rank | RICE Rank | Delta | Why they disagree |
|---|---|---|---|---|
| **H-01 Hybrid BM25** | **1** | **6** | −5 | High effort (6.5 days) wrecks RICE even though impact is highest. RICE says "do small things first"; ICE says "biggest win first." **Strategic tension: H-01 is the only hypothesis that can *structurally* beat the BM25 baseline.** |
| **H-11 HNSW ef_search** | **8** | **1** | +7 | Near-zero effort + 3-benchmark reach makes RICE love it. ICE penalizes low impact (+0.5–2pp). **Easy win that RICE correctly surfaces; ICE underweights operational cheapness.** |
| **H-03 Truncation fix** | **12** | **4** | +8 | 0.25-day effort makes RICE rank it top-5. ICE sees low impact (expected gain is small or zero). **Do it immediately regardless of ICE; it removes a methodology defect.** |
| **H-04 Weight calibration** | **5** | **9** | −4 | Moderate effort (3 days) + uncertainty about gain hurts RICE. ICE gives credit for 5pp potential. **Both frameworks agree it's mid-tier; do after low-hanging fruit.** |
| **H-05 DRAGON dim-flex** | **7** | **12** | −5 | Already planned for v0.2.2; ICE gives credit for confidence=0.95. RICE correctly scores low impact (recall gain = 0). **Both frameworks confirm: do it for methodology, not recall.** |
| **H-13 Query expansion** | **6** | **8** | −2 | Mild disagreement. RICE penalizes LLM dependency (breaks zero-dep value prop) which isn't captured in effort alone. Flag as optional for agents that already have LLM access. |

**Key insight from disagreements:** ICE optimizes for maximum metric gain; RICE optimizes for return on investment. The biggest strategic disagreement is H-01: ICE says it's #1 priority; RICE says do the cheap wins first. Both are correct — they reflect different constraints (impact-first vs. resource-constrained). For v0.2.2, a hybrid approach (do the free wins, schedule H-01 for v0.2.3 if effort is too high) is reasonable.

---

## Recommended Top-3 for v0.2.2

These three hypotheses maximize recall improvement per engineer-day while maintaining methodology credibility:

### P1: H-11 HNSW ef_search tuning
**Why:** 0.5 days, no code changes (GUC config + DDL), expected +0.5–2pp on both benchmarks, zero regression risk. Should be done in the same PR as the v0.2.2 dim-flex work. Both RICE and ICE agree this is low-cost high-return.

**Implementation:** Set `ef_search = 128` (or 200) in HNSW index creation DDL. Re-run both benchmarks. Ship as part of v0.2.2 index tuning.

### P2: H-03 Truncation fix + H-02 Stella V5 fix (bundle as one methodology PR)
**Why:** Combined effort ≈ 1 day. Both remove documented methodology bugs rather than adding new features. H-03 eliminates the 500-char OOM workaround; H-02 restores paper-canonical embedder. Together they give pgmnemo clean numbers that are directly comparable to paper baselines — essential before any conference submission or Show HN post.

**Implementation:** Fix Qwen2Config.rope_theta with `getattr(config, 'rope_theta', 10000.0)`; set batch_size=8 with no char truncation; re-run LongMemEval once.

### P3: H-01 Hybrid BM25 + vector retrieval
**Why:** The only hypothesis that can structurally close the BM25 gap (4.9pp on LME, 5.5pp on LoCoMo). ICE #1 for good reason. 6.5 days is the highest effort on this list, but it turns pgmnemo from "vector-only" into "hybrid-native" — removing the #1 competitive gap vs. agentic-db. Assign as the v0.2.2 headline feature; all other hypotheses are complementary.

**Implementation:** Add `tsvector` GIN index to `agent_lesson.content`; extend `recall_lessons()` with BM25 path; implement RRF fusion with weight parameter (default: `bm25_weight=0.3`); re-run both benchmarks.

---

## Evidence Traceability

| Source | WG task | Findings used |
|---|---|---|
| LoCoMo session-level report | WG-BENCH-3 (5310) | Baseline 0.795, per-category weakness (temporal 0.660, single_hop 0.681) |
| LME bge-m3 report | WG-BENCH-5 (5312) | Baseline 0.933, per-Q-type weakness (user 0.871, preference 0.900) |
| Embedder deviation addendum | WG-BENCH-5 (5312) | Stella V5 incompatibility; H-02 hypothesis |
| Truncation addendum | WG-BENCH-3 (5310) | 500-char bug; H-03 hypothesis |
| Padding addendum | WG-BENCH-3 (5310) | DRAGON zero-padding math-equiv; H-05 confirmed neutral |
| Vendor benchmark report | WG-BENCH-4 (5311) | agentic-db hybrid +8–12pp gap; H-01 sourced |
| BM25 paper baseline (Wu 2025) | WG-BENCH-3 (5310) | LME BM25 = 0.982; primary gap target |
| Benchmark HISTORY | all | Methodology correction audit trail |
| MAGMA arxiv 2601.03236 | WG-BENCH-4 (5311) | Multi-edge subtypes; H-08 |
| BEIR literature | WG-BENCH-4 (5311) | RRF hybrid +9pp typical; H-01 confidence |

---

*WG-HYP-1 first draft complete 2026-05-09. Pending findings: WG-BENCH-2 ablation (5309) weights grid-search; QUICK-B hybrid retrieval empirical run. Update H-04 confidence once ablation (5309) completes. Update H-01 RICE if QUICK-B confirms hybrid delta empirically.*
