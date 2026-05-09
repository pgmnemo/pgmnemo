# DEPRECATED — methodology bug

This run extracted corpus at TURN level (5882 segments). Paper Maharana ACL 2024
evaluates at SESSION level. Numbers in this directory underestimate pgmnemo
retrieval by ~43pp.

**Canonical result for v0.2.1:** [v0.2.1_session_20260509/](../v0.2.1_session_20260509/)

| Metric | This (turn, deprecated) | Canonical (session) |
|---|---|---|
| recall@10 | 0.366 | **0.795** |
| recall@25 | 0.477 | 0.962 |
| recall@50 | 0.574 | 0.999 |
| MRR | 0.237 | 0.548 |

See [benchmarks/HISTORY.md](../../HISTORY.md) for full methodology change log.
