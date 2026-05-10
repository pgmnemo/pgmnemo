# LongMemEval Benchmark (pgmnemo vector) — pgmnemo 0.2.1

**Date:** 2026-05-09
**Mode:** real (dry_run=false), retrieval-only
**Retrieval:** pgmnemo.recall_lessons() vector + 5-component scoring
**Embedder:** BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical
**Deviation rationale:** Stella V5 modeling_qwen.py incompat with transformers 5.8; bge-m3 same dim, MTEB-strong, matches production embedding setup
**Dataset:** xiaowu0162/longmemeval-cleaned, **longmemeval_s_cleaned.json** (full haystacks ~47.7 sessions/item)
**Storage:** pgmnemo v0.2.1, vector(1024) NATIVE
**Device:** mps

Companion: `run_nollm.py` provides pure-Python BM25 baseline on same dataset.

## Methodology

Conforms to Wu et al. ICLR 2025 retrieval-only evaluation. See:
- [arxiv 2410.10813](https://arxiv.org/abs/2410.10813)
- [github xiaowu0162/LongMemEval](https://github.com/xiaowu0162/LongMemEval)

## Statistics

| Metric | Value |
|---|---|
| Total items | 500 |
| Items evaluated | 500 |

## Overall Retrieval Metrics

| Metric | Value | 95% CI |
|---|---|---|
| recall@1 | 0.4856 | [0.4557, 0.5154] |
| recall@5 | 0.8692 | [0.8433, 0.8951] |
| recall@10 | 0.9326 | [0.9135, 0.9517] |
| recall@20 | 0.9773 | [0.9661, 0.9886] |
| MRR | 0.8554 | [0.8292, 0.8816] |

## Per-Q-type recall@10 + MRR

| Q-type | N | recall@10 | MRR |
|---|---|---|---|
| knowledge-update | 78 | 0.9231 [0.879, 0.9672] | 0.8558 [0.79, 0.9216] |
| multi-session | 133 | 0.9565 [0.9327, 0.9803] | 0.9528 [0.9239, 0.9818] |
| single-session-assistant | 56 | 0.9821 [0.9471, 1] | 0.9537 [0.9078, 0.9995] |
| single-session-preference | 30 | 0.9 [0.7908, 1] | 0.6553 [0.5147, 0.796] |
| single-session-user | 70 | 0.8714 [0.7924, 0.9504] | 0.6024 [0.5067, 0.6982] |
| temporal-reasoning | 133 | 0.933 [0.897, 0.9689] | 0.8946 [0.8513, 0.9379] |


Wall clock: 944.1s
