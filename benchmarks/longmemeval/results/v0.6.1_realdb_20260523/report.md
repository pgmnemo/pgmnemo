# pgmnemo v0.6.1 LongMemEval Benchmark

Date: 2026-05-23

## Results

| Metric | v0.6.1 | v0.4.0 baseline | Δ |
|--------|--------|-----------------|---|
| recall@1  | 0.2513 | — | — |
| recall@5  | 0.5187 | — | — |
| recall@10 | 0.7090 | 0.9334 | -0.2244 |
| recall@20 | 0.9526 | — | — |
| MRR       | 0.5708 | 0.8521 | -0.2813 |

## Gate

- recall@10 >= 0.9434: **FAIL** (0.7090)
- p_approx < 0.05: **INFO** (p=1.0000, t=-13.99)
- Overall: **GATE FAIL**
