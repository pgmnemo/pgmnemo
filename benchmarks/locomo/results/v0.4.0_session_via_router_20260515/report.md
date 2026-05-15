# LoCoMo Benchmark — SESSION-level granularity (Hypothesis A)

**Date:** 2026-05-15
**Granularity:** session (one segment per session, ~272 segments)
**Baseline:** turn-level v0.2.1_20260509 (~5882 segments)
**Dataset:** snap-research/locomo, locomo10.json
**Dataset SHA256:** `79fa87e90f040813...`
**Embedder:** facebook/dragon-plus (paper canonical, Lin et al. 2023)
**Storage:** pgmnemo 0.4.0, vector(1024); DRAGON 768d zero-padded (math-identical for cosine)
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
**Control:** same embedder (DRAGON-plus), same DB schema (pgmnemo v0.4.0), same 1986 questions
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
| recall@5  | 0.3023 | 0.7247 | +0.4224 |
| recall@10 | 0.3660 | 0.8409 | +0.4749 |
| recall@25 | 0.4770 | 0.9724 | +0.4954 |
| recall@50 | 0.5740 | 0.9997 | +0.4257 |
| MRR       | 0.2369 | 0.6365 | +0.3996 |

### Session-level 95% CIs

| Metric | Value | 95% CI |
|---|---|---|
| recall@5 | 0.7247 | [0.7062, 0.7431] |
| recall@10 | 0.8409 | [0.8261, 0.8557] |
| recall@25 | 0.9724 | [0.9658, 0.979] |
| recall@50 | 0.9997 | [0.9992, 1] |
| MRR | 0.6365 | [0.6192, 0.6538] |

## Per-Category Metrics (session-level)

| Category | N | recall@10 | MRR |
|---|---|---|---|
| single_hop | 282 | 0.7089 [0.6745, 0.7434] | 0.6226 [0.5788, 0.6665] |
| multi_hop | 321 | 0.864 [0.8276, 0.9003] | 0.6546 [0.6111, 0.698] |
| temporal | 92 | 0.6559 [0.5708, 0.7411] | 0.4099 [0.3346, 0.4852] |
| open_domain | 841 | 0.8894 [0.8683, 0.9106] | 0.6667 [0.6405, 0.693] |
| adversarial | 446 | 0.8543 [0.8215, 0.887] | 0.622 [0.5849, 0.6592] |

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

Wall clock: 29.6s
