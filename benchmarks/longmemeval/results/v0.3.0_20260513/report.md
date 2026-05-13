# LongMemEval Benchmark (pgmnemo vector, full sessions) — pgmnemo 0.3.0

**Date:** 2026-05-13
**Mode:** real (dry_run=false), retrieval-only
**Retrieval:** pgmnemo.recall_lessons() vector + 5-component scoring
**Embedder:** BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical
**Deviation rationale:** Stella V5 modeling_qwen.py incompat with transformers 5.8; bge-m3 same dim, MTEB-strong, matches production embedding setup
**Dataset:** xiaowu0162/longmemeval-cleaned, longmemeval_s_cleaned.json (full haystacks ~47.7 sessions/item)
**Storage:** pgmnemo v0.2.1, vector(1024) NATIVE
**Device:** mps (CPU — forced to eliminate MPS OOM)
**Truncation:** 8000 chars (bge-m3 ~8192 token ctx; effectively no truncation for avg session)

**Hypothesis C (2026-05-09):** Remove 500-char truncation from baseline → does recall improve?

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
| recall@1 | 0.4762 | [0.4459, 0.5066] |
| recall@5 | 0.8814 | [0.8567, 0.9061] |
| recall@10 | 0.9334 | [0.914, 0.9528] |
| recall@20 | 0.9853 | [0.9771, 0.9935] |
| MRR | 0.8472 | [0.821, 0.8733] |

## Delta vs Baseline (v0.2.1_pgmnemo_20260509, 500-char truncation, MPS)

| Metric | Baseline (500-char trunc) | Full (8000-char) | Delta |
|---|---|---|---|
| recall@10 | 0.9326 | 0.9334 | +0.0008 |
| MRR | 0.8554 | 0.8472 | -0.0082 |


## Per-Q-type recall@10 + MRR

| Q-type | N | recall@10 | MRR |
|---|---|---|---|
| knowledge-update | 78 | 0.9359 [0.8908, 0.981] | 0.8908 [0.8339, 0.9477] |
| multi-session | 133 | 0.9603 [0.9341, 0.9864] | 0.937 [0.9043, 0.9696] |
| single-session-assistant | 56 | 1.0 [1.0, 1] | 0.9911 [0.9736, 1] |
| single-session-preference | 30 | 0.9 [0.7908, 1] | 0.6467 [0.5056, 0.7878] |
| single-session-user | 70 | 0.8571 [0.7746, 0.9397] | 0.6092 [0.5168, 0.7016] |
| temporal-reasoning | 133 | 0.9248 [0.8884, 0.9612] | 0.8417 [0.7917, 0.8917] |


Wall clock: 3406.7s
