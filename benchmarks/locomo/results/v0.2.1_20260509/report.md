# LoCoMo Benchmark — pgmnemo 0.2.1

**Date:** 2026-05-09
**Mode:** real (dry_run=false)
**Dataset:** snap-research/locomo, locomo10.json
**Dataset SHA256:** `79fa87e90f040813...`
**Embedder:** facebook/dragon-plus (paper canonical, Lin et al. 2023)
**Storage:** pgmnemo v0.2.1, vector(1024); DRAGON 768d zero-padded (math-identical for cosine)
**Device:** mps

## Methodology

Conforms to Maharana et al. ACL 2024 §4.2 retrieval evaluation. See:
- [arxiv 2402.17753](https://arxiv.org/abs/2402.17753)
- [github snap-research/locomo](https://github.com/snap-research/locomo)
- ADDENDA/LOCOMO_EMBEDDER_PADDING.md (zero-pad rationale)

## Corpus Statistics

| Metric | Value |
|---|---|
| Conversations | 10 |
| Corpus segments (turns) | 5882 |
| Total questions | 1986 |
| Questions with evidence (evaluated) | 1982 |

### Category distribution

| Category | Name | N |
|---|---|---|
| 1 | single_hop | 282 |
| 2 | multi_hop | 321 |
| 3 | temporal | 96 |
| 4 | open_domain | 841 |
| 5 | adversarial | 446 |


## Overall Retrieval Metrics

| Metric | Value | 95% CI |
|---|---|---|
| recall@5 | 0.3023 | [0.2826, 0.322] |
| recall@10 | 0.366 | [0.3455, 0.3866] |
| recall@25 | 0.477 | [0.4558, 0.4981] |
| recall@50 | 0.574 | [0.5532, 0.5947] |
| MRR | 0.2369 | [0.2214, 0.2525] |

## Per-Category Metrics

| Category | N | recall@10 | MRR |
|---|---|---|---|
| single_hop | 282 | 0.1153 [0.0879, 0.1426] | 0.1066 [0.0794, 0.1338] |
| multi_hop | 321 | 0.3938 [0.342, 0.4457] | 0.2418 [0.204, 0.2797] |
| temporal | 92 | 0.1727 [0.1013, 0.2442] | 0.1065 [0.0561, 0.1569] |
| open_domain | 841 | 0.3962 [0.3635, 0.4288] | 0.2489 [0.2246, 0.2732] |
| adversarial | 446 | 0.4877 [0.4417, 0.5336] | 0.3201 [0.2833, 0.3568] |


## References

- Maharana et al. 2024 — "Evaluating Very Long-Term Conversational Memory of LLM-based Agents" (ACL 2024)
- Lin et al. 2023 — DRAGON dual encoder
- Wilson 1927 — score CIs

## Reproducibility

```bash
docker run -d --name pgmnemo-bench -p 15432:5432 -e POSTGRES_PASSWORD=bench \
  -e POSTGRES_USER=bench -e POSTGRES_DB=bench pgvector/pgvector:pg17
docker exec pgmnemo-bench psql -U bench -d bench -c "CREATE EXTENSION pgmnemo CASCADE;"

curl -L https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json \
  -o benchmarks/data/locomo/locomo10.json

python benchmarks/scripts/run_locomo_bench.py
```

Wall clock: 111.0s
