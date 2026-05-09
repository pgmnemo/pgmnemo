# pgmnemo

**Multi-agent memory substrate for PostgreSQL — provenance-gated, vector-hybrid recall.**

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.2.1-green.svg)](CHANGELOG.md)
[![CI](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml/badge.svg)](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1.svg)](https://www.postgresql.org/)
[![LoCoMo recall@10](https://img.shields.io/badge/LoCoMo_recall%4010-0.795-success.svg)](benchmarks/locomo/results/v0.2.1_session_20260509/report.md)
[![LongMemEval recall@10](https://img.shields.io/badge/LongMemEval_recall%4010-0.933-success.svg)](benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/report.md)

## Benchmarks (v0.2.1, retrieval-only)

Real numbers vs published academic benchmarks. Full methodology + reproduction commands in [docs/BENCHMARKS.md](docs/BENCHMARKS.md). Methodology change log in [benchmarks/HISTORY.md](benchmarks/HISTORY.md).

| Benchmark | Embedder | Metric | pgmnemo | Comparison |
|---|---|---|---|---|
| **LoCoMo** ([Maharana ACL 2024](https://arxiv.org/abs/2402.17753)) | DRAGON (paper canonical) | recall@10 / MRR | **0.795** / **0.548** | session-level granularity, paper-class range |
| **LongMemEval** ([Wu ICLR 2025](https://arxiv.org/abs/2410.10813)) | bge-m3 (subst. for Stella V5)¹ | recall@10 / MRR | **0.933** / **0.855** | BM25 baseline² 0.982 |

¹ Stella V5 paper canonical incompatible with transformers 5.8 — substituted bge-m3 (1024d, MTEB-strong). [Addendum](benchmarks/longmemeval/ADDENDA/LONGMEMEVAL_EMBEDDER_BGE_M3.md).
² Pure-Python BM25 baseline included for reference: [run_nollm.py](benchmarks/longmemeval/run_nollm.py).

**Reproduce in 3 commands:** see [docs/BENCHMARKS.md#reproducibility](docs/BENCHMARKS.md#reproducibility).

**Honest caveats:** BM25 outperforms pgmnemo vector retrieval on LongMemEval (keyword-friendly task). [Hybrid retrieval (vector + BM25 RRF)](benchmarks/scripts/run_longmemeval_pgmnemo.py) is on the v0.2.2 roadmap.

## Why this exists

- **One differentiator none of Pinecone, Letta, Mem0, or Zep have:** a write-time provenance gate. Every `ingest()` call must carry a `commit_sha` or `artifact_hash`; rows without provenance are blocked (or warned) by default. Hallucinated agent memories cannot silently accumulate.
- **No new service.** `CREATE EXTENSION pgmnemo;` in your existing PostgreSQL — no separate API server, no SaaS endpoint, no vendor lock-in.
- **Hybrid recall in-database.** Cosine similarity (HNSW) + BM25 full-text + recency decay + importance weighting, scored in one SQL call.
- **Role isolation built in.** First-class `role + project_id` composite scoping; no hand-rolled RLS.

## 30-second quickstart

```bash
# 1. Start PG 17 + pgvector
docker run --name pgmnemo-dev -e POSTGRES_PASSWORD=pass -p 5432:5432 -d pgvector/pgvector:pg17

# 2. Build and install the extension (requires make, gcc, pg_config on PATH)
git clone https://github.com/pgmnemo/pgmnemo.git
docker exec pgmnemo-dev bash -c "apt-get install -y postgresql-server-dev-17 make gcc 2>/dev/null; true"
docker cp pgmnemo/extension pgmnemo-dev:/tmp/pgmnemo
docker exec pgmnemo-dev bash -c "cd /tmp/pgmnemo && make && make install"
```

```sql
-- psql -h localhost -U postgres

CREATE EXTENSION pgmnemo CASCADE;

SELECT pgmnemo.ingest(
    p_role        := 'developer',
    p_project_id  := 1,
    p_topic       := 'auth',
    p_lesson_text := 'Rotate JWT secrets after any key-compromise incident.',
    p_commit_sha  := 'abc1234'
);

SELECT lesson_text, score
FROM pgmnemo.recall_lessons(
    query_embedding := array_fill(0, ARRAY[1024])::vector(1024),
    query_text      := 'JWT secret rotation',
    role_filter     := 'developer'
);
```

> For a native install (no Docker), see [INSTALL.md](INSTALL.md).

## Features

- **HNSW vector search** — fast approximate nearest-neighbour recall via `pgvector` HNSW indexes
- **Provenance gate** — `enforce` / `warn` / `off` modes; controlled by `pgmnemo.gate_strict` GUC
- **Recency-weighted scoring** — `0.5×cosine + 0.2×importance + γ×recency(90d) + 0.1×prov_strength`; γ tunable via `pgmnemo.recency_weight`
- **Role scoping** — `role + project_id` composite isolation; `role_filter=NULL` pools across roles
- **Graph traversal** — `traverse_causal_chain()` and `traverse_temporal_window()` walk typed `mem_edge` relationships between lessons

## Documentation

- [INSTALL.md](INSTALL.md) — build, install, configure, upgrade
- [docs/USAGE.md](docs/USAGE.md) — API reference and tuning guide
- [CHANGELOG.md](CHANGELOG.md) — version history

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions accepted under the DCO sign-off model.

## Citing

```bibtex
@misc{gaydabura2026pgmnemo,
  author = {Gaydabura, Alex and pgmnemo contributors},
  title  = {pgmnemo: A Provenance-Gated Multi-Agent Memory Substrate for PostgreSQL},
  year   = {2026},
  note   = {ICSE-SEIP submission in preparation}
}
```

