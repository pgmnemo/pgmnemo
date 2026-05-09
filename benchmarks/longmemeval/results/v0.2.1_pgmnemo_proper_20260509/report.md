# LongMemEval Benchmark — pgmnemo 0.2.1 (proper-config rerun)

**Date:** 2026-05-09
**Mode:** real
**Retrieval:** pgmnemo.recall_lessons() vector + 5-component scoring
**Embedder:** BAAI/bge-m3 (1024d), `max_seq_length=512` token-level cap, batch=8 on MPS
**Dataset:** xiaowu0162/longmemeval-cleaned, longmemeval_s_cleaned.json (full haystacks ~47.7 sessions/item, avg 10K chars/session)
**Storage:** pgmnemo v0.2.1, vector(1024) NATIVE
**Device:** mps

## Why this rerun

Previous run (v0.2.1_pgmnemo_20260509) used custom 500-char text truncation
that was claimed as MPS-hardware-forced. That claim was incorrect — the
real OOM cause was batch_size=32, not text length. This run uses proper
bge-m3 config: explicit `max_seq_length=512` token cap (not chars), batch=8.

## Results (n=500, retrieval-only)

| Metric | Value | 95% CI |
|---|---|---|
| recall@1 | (computed) | — |
| recall@5 | (computed) | — |
| **recall@10** | **0.9334** | **[0.914, 0.953]** |
| recall@20 | (computed) | — |
| **MRR** | **0.8472** | **[0.821, 0.873]** |

## Comparison vs previous (with char truncation)

| Metric | Truncated (500-char) | Token-level (proper) | Delta |
|---|---|---|---|
| recall@10 | 0.9326 | 0.9334 | +0.001 |
| MRR | 0.8554 | 0.8472 | -0.008 |

**Conclusion:** the 500-char truncation deviation had near-zero impact on
retrieval metrics. The methodology was confused (claimed hardware limit
that didn't exist), but the published numbers were not materially distorted.

## Cleanup

Per HISTORY.md update protocol, the LONGMEMEVAL_TRUNCATION_500.md addendum
should be removed since the underlying claim was a config-bug rather than
a real deviation. Tracked in cleanup task.

## References

- Wu et al. 2024 — "LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory" (ICLR 2025)
- BAAI/bge-m3 — multilingual MTEB-strong embedder (1024d, 8192-token max but capped at 512 here for MPS efficiency)
