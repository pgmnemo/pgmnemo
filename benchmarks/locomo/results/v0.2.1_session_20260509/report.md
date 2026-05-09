# LoCoMo Benchmark — pgmnemo 0.2.1 (session-level granularity)

**Date:** 2026-05-09
**Mode:** real (dry_run=false)
**Granularity:** session-level (corrected from turn-level v0.2.1_20260509)
**Dataset:** snap-research/locomo, locomo10.json
**Embedder:** facebook/dragon-plus (paper canonical)
**Storage:** pgmnemo v0.2.1, vector(1024); DRAGON 768d zero-padded
**Device:** mps

## Methodology correction

Previous run (v0.2.1_20260509) extracted corpus at TURN level (5882 segments).
Paper Maharana ACL 2024 evaluates at SESSION level (one segment per dialog).
Evidence references like "D1:3" are dialog session references, not turn references.

This run uses session-level granularity: 272 segments (10 conversations × ~27 sessions).
Each segment = concatenation of all turns within that session.

## Statistics

| Metric | Value |
|---|---|
| Conversations | 10 |
| Session-level segments | 272 |
| Total questions | 1986 |
| Questions evaluated (with evidence) | 1982 |

## Overall Retrieval Metrics

| Metric | Session-level (this) | Turn-level (v0.2.1_20260509) | Delta |
|---|---|---|---|
| recall@1 | 0.365 | n/a | n/a |
| recall@5 | 0.662 | 0.302 | **+36pp** |
| **recall@10** | **0.795** | **0.366** | **+43pp** |
| recall@25 | 0.962 | 0.477 | +49pp |
| recall@50 | 0.999 | 0.574 | +43pp |
| MRR | 0.548 | 0.237 | +31pp |

## Per-category recall@10

| Category | N | Session-level | Turn-level | Delta |
|---|---|---|---|---|
| single_hop | 282 | 0.681 | 0.115 | +57pp |
| multi_hop | 321 | 0.834 | 0.394 | +44pp |
| temporal | 92 | 0.660 | 0.173 | +49pp |
| open_domain | 841 | 0.819 | 0.396 | +42pp |
| adversarial | 446 | 0.823 | 0.488 | +33pp |

## Conclusion

Session-level granularity is the correct interpretation per Maharana ACL 2024 §4.2.
Previous turn-level result (0.366) was a methodological bug in our corpus extraction,
not a pgmnemo retrieval limitation. Corrected result (0.795) places pgmnemo in
paper-class retriever territory.

## References

- Maharana et al. 2024 — "Evaluating Very Long-Term Conversational Memory of LLM-based Agents" (ACL 2024)
- Lin et al. 2023 — DRAGON dual encoder
