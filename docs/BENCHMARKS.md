# pgmnemo Benchmarks

**Status:** v0.2.1 first honest results, retrieval-only mode

This document summarizes our public benchmark results, methodology, and the
honest comparison vs published baselines.

---

## TL;DR

| Benchmark | pgmnemo v0.2.1 | Notable comparison |
|---|---|---|
| **LoCoMo** retrieval (DRAGON, n=1982) | recall@10 = **0.795**, MRR = **0.548** (session-level, paper-class) | paper-class range (DRAGON canonical, session granularity) |
| **LongMemEval** retrieval (bge-m3, n=500, s_cleaned) | recall@10 = **0.933**, MRR = **0.855** | Below in-repo BM25 baseline (0.982) |

Reports + raw_retrievals + reproduction commands:
- [`benchmarks/locomo/results/v0.2.1_20260509/`](../benchmarks/locomo/results/v0.2.1_20260509/)
- [`benchmarks/longmemeval/results/v0.2.1_20260509/`](../benchmarks/longmemeval/results/v0.2.1_20260509/) — BM25 baseline (run_nollm.py)
- [`benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/`](../benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/) — pgmnemo vector (run_longmemeval_pgmnemo.py)

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
| Session truncation | 500 chars per session for MPS memory | ⚠️ **DEVIATION**: paper does not truncate. May affect recall on long sessions. See `ADDENDA/LONGMEMEVAL_TRUNCATION_500.md`. |

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
- 500-char session truncation may discard critical context

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

