# pgmnemo Benchmarks

**Status:** v0.3.0 — neutral vs v0.2.1 (schema-additive + bug-fix release).  
**Full per-release tracking:** [`benchmarks/METRICS_BY_VERSION.md`](../benchmarks/METRICS_BY_VERSION.md)

This document summarizes the public headline results. Per-version dynamics
across all (dataset × embedder × mode) combinations live in
`benchmarks/METRICS_BY_VERSION.md` — that file is the single source of truth.

---

## TL;DR — current release (v0.3.0)

| Benchmark | Headline metric (latest tag) | Δ vs v0.2.1 |
|---|---|---|
| **LoCoMo** session-level retrieval (DRAGON, n=1982) | recall@10 = **0.7994**, MRR = **0.5569** | neutral (+0.43pp, p_corr=1.0) |
| **LongMemEval-S** retrieval (bge-m3, n=500) | recall@10 = **0.9334**, MRR = **0.8472** | neutral (+0.08pp r@10, −0.82pp MRR, p_corr=1.0) |

> **Reading the headline number:** the LoCoMo recall@10 = 0.7994 figure is the
> **session-level** metric (paper-canonical, Maharana et al. Table 3). The
> segment-level retrieval primitive — used as the gate metric for
> `recall_lessons()` algorithmic changes — sits at recall@10 = 0.3660. The two
> are not comparable; see [METRICS_BY_VERSION.md](../benchmarks/METRICS_BY_VERSION.md)
> Table 1 vs Table 2 for the distinction.

Reports + raw_retrievals + reproduction commands:
- LoCoMo session, v0.3.0: [`benchmarks/locomo/results/v0.3.0_session_20260513/`](../benchmarks/locomo/results/v0.3.0_session_20260513/)
- LoCoMo session, v0.2.1 baseline: [`benchmarks/locomo/results/v0.2.1_session_20260509/`](../benchmarks/locomo/results/v0.2.1_session_20260509/)
- LoCoMo segment (gate metric), v0.3.0: [`benchmarks/locomo/results/v0.3.0_20260510/`](../benchmarks/locomo/results/v0.3.0_20260510/)
- LongMemEval-S, v0.2.1 baseline: [`benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/`](../benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/)
- LongMemEval-S, BM25 reference: [`benchmarks/longmemeval/results/v0.2.1_20260509/`](../benchmarks/longmemeval/results/v0.2.1_20260509/)

### Version progression (auto-generated)

Cross-version line charts + markdown tables for every (dataset × mode):

- LoCoMo session: [SVG](img/progression_locomo_session.svg) · [Markdown table](img/progression_locomo_session.md)
- LoCoMo segment: [SVG](img/progression_locomo_segment.svg) · [Markdown table](img/progression_locomo_segment.md)
- LongMemEval-S: regenerate after v0.3.0 LME run completes (see METRICS_BY_VERSION.md Table 3)

Each panel shows the metric line with CI95 band and Δpp annotation between
consecutive versions. Re-render via `python scripts/render_progression.py`
(see `docs/BENCHMARK_PROTOCOL.md §7a`).

### v0.3.0 monitor watchlist (per-category near-threshold cells)

The `scripts/significance_test_extended.py` per-category z-test surfaced
9 cells with |Δ|≥1pp vs v0.2.1 (not statistically significant; sample sizes
range from n=92 for `temporal` to n=841 for `open_domain`). These cells are
NOT regressions but are flagged for monitoring; if v0.3.1 shows the same
direction the next release CYCLE should treat them as significance candidates:

| Category | Direction | Cells affected |
|---|---|---|
| `temporal` | 📉 | recall@5 (-3.81pp), recall@10 (-1.49pp), MRR (-1.71pp) |
| `open_domain` | 📈 | recall@5 (+1.66pp), recall@10 (+1.96pp), MRR (+1.99pp) |
| `single_hop` | 📉 | recall@5 (-1.53pp) |
| `multi_hop` | mixed | recall@5 (-1.19pp), MRR (+1.57pp) |

The temporal drift correlates with the v0.3.0 `edge_kind` ENUM migration, which
touched the BFS path in `recall_lessons()`. Hypothesis H-06 (temporal weight
tuning, ROADMAP §H2) directly targets this category and may flip the sign.

---

## Methodology Conformance

### LoCoMo (Maharana et al., ACL 2024)

| Paper requirement | Our implementation | Status |
|---|---|---|
| Dataset | `snap-research/locomo10.json` (10 conversations, 1986 questions, 5 categories) | ✅ verbatim |
| Embedder | facebook/dragon-plus (context+query) | ✅ paper canonical |
| Retrieval k | k ∈ {5, 10, 25, 50} | ✅ all reported |
| Metric (primary retrieval) | recall@K | ✅ |
| MRR (secondary) | yes | ✅ |
| LLM-as-judge accuracy (downstream eval) | n/a — retrieval-only mode | ⚠️ deferred |
| Storage dim | 768d (DRAGON native) | ⚠️ **DEVIATION**: pgmnemo enforces vector(1024); we zero-pad 768→1024. Cosine similarity preserved (math-identical). See `ADDENDA/LOCOMO_EMBEDDER_PADDING.md`. |

### LongMemEval (Wu et al., ICLR 2025)

| Paper requirement | Our implementation | Status |
|---|---|---|
| Dataset | `xiaowu0162/longmemeval-cleaned` (longmemeval_s_cleaned.json, 500 questions × ~47.7 sessions/haystack) | ✅ |
| Embedder | NovaSearch/stella_en_1.5B_v5 1024d | ⚠️ **DEVIATION**: bundled `modeling_qwen.py` incompatible with transformers 5.8 (`Qwen2Config.rope_theta` AttributeError); substituted **BAAI/bge-m3** (1024d, MTEB-strong, matches common production). See `ADDENDA/LONGMEMEVAL_EMBEDDER_BGE_M3.md`. |
| Retrieval (recall@K, NDCG@K, MRR) | recall@{1,5,10,20} + MRR | ✅ |
| Question types | 5 (single-session-{user,assistant,preference}, multi-session, temporal-reasoning, knowledge-update + abstention variant) | ✅ |
| LLM-as-judge accuracy via `evaluate_qa.py` | n/a — retrieval-only mode | ⚠️ deferred (no API key; paper supports retrieval-only) |
| Session truncation | 500 chars per session (config bug, not hardware limit) | ✅ **no significant impact**: QUICK-C re-run (v0.2.1_pgmnemo_20260509) recall@10 delta = 0.0008; addendum withdrawn. |

---

## Honest Findings

### 1. BM25 baseline outperforms pgmnemo vector on LongMemEval

```
recall@10:  pgmnemo vector (bge-m3) = 0.933  |  BM25 baseline = 0.982
recall@20:  pgmnemo vector (bge-m3) = 0.977  |  BM25 baseline = 0.996
```

Both metrics on the same dataset (longmemeval_s_cleaned, n=500). BM25 wins.

Hypothesized causes (under WG investigation):
- LongMemEval questions have high keyword overlap with relevant sessions — BM25-friendly task
- pgmnemo's 5-component scoring may over-penalize on short queries
- bge-m3 substitution (vs paper canonical Stella V5) may explain part of the gap
- session truncation had near-zero impact (QUICK-C delta = 0.0008)

### 2. pgmnemo wins on certain question types

| Q-type | pgmnemo recall@10 | Notes |
|---|---|---|
| single-session-assistant | 0.982 | tied with BM25 |
| multi-session | 0.957 | strong vs BM25-only baselines |
| temporal-reasoning | 0.933 | competitive |
| knowledge-update | 0.923 | competitive |
| single-session-preference | 0.900 | competitive |
| single-session-user | 0.871 | weakest |

### 3. LoCoMo recall@10 = 0.366 below paper-reported retrievers

Likely causes (under WG investigation):
- We index turn-level segments; paper may use session-level
- 5-component scoring weights need calibration on this dataset
- DRAGON 768d zero-padded → 1024d may have second-order HNSW effects (theoretically not, but worth verifying)

---

## Reproducibility

```bash
# Full reproduction in 3 commands:
docker run -d --name pgmnemo-bench -p 15432:5432 \
  -e POSTGRES_PASSWORD=bench -e POSTGRES_USER=bench -e POSTGRES_DB=bench \
  pgvector/pgvector:pg17

docker exec pgmnemo-bench bash -c "apt-get update -qq && \
  apt-get install -y -qq postgresql-server-dev-17 build-essential && \
  cd /tmp/pgmnemo && make && make install"
docker exec pgmnemo-bench psql -U bench -d bench -c "CREATE EXTENSION pgmnemo CASCADE;"

# LoCoMo (DRAGON, ~2 min on Apple Silicon MPS)
python benchmarks/scripts/run_locomo_bench.py

# LongMemEval (bge-m3, ~16 min on Apple Silicon MPS)
python benchmarks/scripts/run_longmemeval_pgmnemo.py
```

Hardware used for published numbers:
- Apple M-series Silicon (MPS GPU acceleration)
- Python 3.11.14, torch 2.11, transformers 5.8, sentence-transformers 5.4
- Wall clock: LoCoMo 111s; LongMemEval 944s

---

## What's Next (WG-in-progress)

WG goals:
1. Investigate why BM25 beats vector retrieval on LongMemEval
2. Identify scoring formula tuning paths to close the gap
3. Reproduce paper-canonical Stella V5 (transformers downgrade or API-compat shim)
4. Compare against MAGMA (arxiv 2601.03236), Mem0, Zep, HippoRAG on same benchmarks
5. Roadmap pgmnemo v0.2.2 (calibration) → v0.3.0 (multi-graph + dim-flex)

---

## References

- Maharana, A. et al. (2024). "Evaluating Very Long-Term Conversational Memory of LLM-based Agents." ACL 2024. [arxiv 2402.17753](https://arxiv.org/abs/2402.17753)
- Wu, Z. et al. (2024). "LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory." ICLR 2025. [arxiv 2410.10813](https://arxiv.org/abs/2410.10813)
- Lin, S.-C. et al. (2023). "DRAGON+." [HF facebook/dragon-plus](https://huggingface.co/facebook/dragon-plus-context-encoder)
- BAAI/bge-m3 multilingual MTEB-strong embedder (1024d)
- Wilson 1927 — score CIs

