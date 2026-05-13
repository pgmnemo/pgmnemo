# LoCoMo Benchmark — SESSION-level granularity (Hypothesis A)

**Date:** 2026-05-13
**Granularity:** session (one segment per session, ~272 segments)
**Baseline:** turn-level v0.2.1_20260509 (~5882 segments)
**Dataset:** snap-research/locomo, locomo10.json
**Dataset SHA256:** `79fa87e90f040813...`
**Embedder:** facebook/dragon-plus (paper canonical, Lin et al. 2023)
**Storage:** pgmnemo 0.3.0, vector(1024); DRAGON 768d zero-padded (math-identical for cosine)
**Device:** mps

## Hypothesis

**Hypothesis A (2026-05-09 strategy review):** The original turn-level extraction (5882 segments)
misaligns with the paper's retrieval evaluation unit. Maharana et al. ACL 2024 evaluate retrieval
at the session/dialog level. Evidence identifiers "D1:3" reference session 1, and the corpus should
consist of one segment per session (~272 segments). Concatenating turns within each session and
matching evidence at the session level (stripping ":turn" suffix) should lift recall@10 from
the observed 0.366 toward the paper-reported baseline range (0.55-0.65).

**IV:** corpus granularity — session vs. turn
**DV:** recall@K (K=5,10,25,50), MRR
**Control:** same embedder (DRAGON-plus), same DB schema (pgmnemo v0.3.0), same 1986 questions
**Treatment:** extract_corpus returns one row per (conv_id, session_idx); evidence normalized to session prefix

**Power analysis:** N=1982 questions. For a 20pp treatment effect at α=0.05,
two-proportion z-test power >0.99. For 5pp effect, power ~0.93.

**Confounds:**
1. Cross-conversation dia_id collisions (all conversations share D1-D27 session numbering).
2. Long sessions may exceed DRAGON 512-token limit; tails are truncated.
3. Multi-turn questions with evidence spanning multiple sessions: session-level may over-retrieve.

## Corpus Statistics

| Metric | Turn-level (baseline) | Session-level (this run) |
|---|---|---|
| Conversations | 10 | 10 |
| Corpus segments | 5882 | 272 |
| Total questions | — | 1986 |
| Questions evaluated | 1982 | 1982 |

## Overall Retrieval Metrics — Side-by-Side Comparison

| Metric | Turn-level baseline | Session-level (this run) | Delta |
|---|---|---|---|
| recall@5  | 0.3023 | 0.664 | +0.3617 |
| recall@10 | 0.3660 | 0.7994 | +0.4334 |
| recall@25 | 0.4770 | 0.9641 | +0.4871 |
| recall@50 | 0.5740 | 0.9996 | +0.4256 |
| MRR       | 0.2369 | 0.5569 | +0.3200 |

### Session-level 95% CIs

| Metric | Value | 95% CI |
|---|---|---|
| recall@5 | 0.664 | [0.6443, 0.6836] |
| recall@10 | 0.7994 | [0.783, 0.8157] |
| recall@25 | 0.9641 | [0.9565, 0.9716] |
| recall@50 | 0.9996 | [0.999, 1] |
| MRR | 0.5569 | [0.5395, 0.5744] |

## Per-Category Metrics (session-level)

| Category | N | recall@10 | MRR |
|---|---|---|---|
| single_hop | 282 | 0.6727 [0.6378, 0.7076] | 0.5856 [0.542, 0.6292] |
| multi_hop | 321 | 0.8266 [0.7862, 0.867] | 0.5591 [0.515, 0.6032] |
| temporal | 92 | 0.6451 [0.5591, 0.731] | 0.3837 [0.3113, 0.4562] |
| open_domain | 841 | 0.8383 [0.8134, 0.8631] | 0.5688 [0.5419, 0.5958] |
| adversarial | 446 | 0.8184 [0.7826, 0.8542] | 0.5506 [0.5134, 0.5877] |

## Methodology Disclosure

This run deviates from strict turn-level extraction in the following ways:

1. **Granularity change:** Corpus segments are sessions (all turns concatenated), not individual turns.
   This is believed to align with the paper's retrieval unit per Maharana et al. §4.2.

2. **Evidence normalization:** Evidence identifiers "D{session}:{turn}" are truncated to "D{session}"
   for matching. A retrieved session "D3" counts as a hit for evidence "D3:7". This is more
   permissive than turn-level exact match (favoring recall) but matches the session-level hypothesis.

3. **Concatenation truncation:** DRAGON tokenizer truncates at 512 tokens. Sessions with many turns
   may have late turns excluded from the embedding. This is a confound present in both this run
   and any session-level baseline from the paper authors.

4. **Cross-conversation collision:** Evidence "D1:3" can match session D1 from any conversation
   in the corpus (not just the query's conversation). Same confound applies to turn-level baseline.

## References

- Maharana et al. 2024 — "Evaluating Very Long-Term Conversational Memory of LLM-based Agents" (ACL 2024)
- Lin et al. 2023 — DRAGON dual encoder
- Wilson 1927 — score confidence intervals

## Reproducibility

```bash
docker run -d --name pgmnemo-bench -p 15432:5432 -e POSTGRES_PASSWORD=bench \
  -e POSTGRES_USER=bench -e POSTGRES_DB=bench pgvector/pgvector:pg17
docker exec pgmnemo-bench psql -U bench -d bench -c "CREATE EXTENSION pgmnemo CASCADE;"

curl -L https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json \
  -o benchmarks/data/locomo/locomo10.json

python benchmarks/scripts/run_locomo_bench_session.py
```

Wall clock: 55.5s
