# pgmnemo

**Multi-agent memory substrate for PostgreSQL — provenance-gated, vector-hybrid recall.**

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.4.0-green.svg)](CHANGELOG.md)
[![PGXN](https://badge.pgxn.org/stable/pgmnemo.svg)](https://pgxn.org/dist/pgmnemo/)
[![CI](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml/badge.svg)](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1.svg)](https://www.postgresql.org/)
[![LoCoMo recall@10](https://img.shields.io/badge/LoCoMo_recall%4010-0.8409-success.svg)](docs/img/all_metrics_history.md)
[![LongMemEval recall@10](https://img.shields.io/badge/LongMemEval_recall%4010-0.9334-yellow.svg)](docs/img/all_metrics_history.md)

> **v0.4.0 (2026-05-15):** hybrid retrieval promoted to default. LoCoMo session recall@10 **+4.15pp** (0.7951 → 0.8409, p_corr=0.0156), MRR **+7.96pp** (p_corr<0.0001). 5 significant improvements, 0 regressions across 24 LoCoMo cells. **LongMemEval remains neutral** — hybrid does NOT close the BM25 gap (BM25 = 0.982; pgmnemo dense = 0.933). See [release scorecard](docs/img/scorecard_v0.4.0.md) and [honest competitive reality](docs/COMPETITIVE_REALITY.md).
>
> **Opt-out:** `SET pgmnemo.disable_hybrid = 'true'` restores strict v0.3.0 vector-only behaviour.
>
> **What's next:** v0.4.1 (target 2026-06-01) — deprecate dead graph machinery from default `recall_lessons()` path. Full plan: [ROADMAP.md](ROADMAP.md).

## Benchmarks (v0.3.0, retrieval-only)

> **Read this before the numbers below:** [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md)
> explains exactly what these recall@K figures mean, what they don't, and where
> our methodology has asymmetries vs paper baselines and competitor positioning.

Real numbers vs published academic benchmarks. **Canonical protocol:** [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md) (v1, frozen 2026-05-13). Full per-version history: [benchmarks/METRICS_BY_VERSION.md](benchmarks/METRICS_BY_VERSION.md). Reproduction commands in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

| Benchmark | Methodology | Embedder | recall@10 / MRR | Honest comparison |
|---|---|---|---|---|
| **LoCoMo** ([Maharana ACL 2024](https://arxiv.org/abs/2402.17753)) | **session-level** (paper-canonical headline) | DRAGON | **0.7994** / **0.5569** | Easier task than paper Table 3 (272 sessions vs 5882 turns search space) |
| **LoCoMo** same paper, turn-level (apples-to-apples with paper baseline) | **turn-level** (retrieval primitive) | DRAGON | recall@5 = **0.302** / MRR = **0.237** | Paper DRAGON dense recall@5 ≈ 0.225 → pgmnemo +7.7pp |
| **LongMemEval-S** ([Wu ICLR 2025](https://arxiv.org/abs/2410.10813)) | retrieval-only, full session | bge-m3 (subst. for Stella V5)¹ | **0.9334** / **0.8472** | **Loses to BM25 baseline² 0.982** by ~5pp |

¹ Stella V5 paper-canonical incompatible with transformers 5.8 — substituted bge-m3 (1024d, MTEB-strong).
² Pure-Python BM25 baseline included for reference: [run_nollm.py](benchmarks/longmemeval/run_nollm.py). On the keyword-heavy LongMemEval workload it currently outperforms our dense vector path. **Fixing this is the explicit gate for v0.4.0** — see [ROADMAP.md](ROADMAP.md).

> **The "we beat everyone" framing is wrong.** Our headline session-level
> LoCoMo number compares to a 22× smaller search space than the paper baseline.
> Our LongMemEval number is below a 50-LOC BM25 script. Comparisons with Mem0 /
> Zep / MAGMA on these datasets are apples-to-oranges — they optimise different
> objectives. The honest competitive position is detailed in
> [COMPETITIVE_REALITY.md §3-§5](docs/COMPETITIVE_REALITY.md).

**Reproduce in 3 commands:** see [docs/BENCHMARKS.md#reproducibility](docs/BENCHMARKS.md#reproducibility).

**What pgmnemo's bench does NOT measure** ([§2 of COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md#2-what-we-dont-measure-and-why-it-matters)): insertion throughput, concurrent read/write, retrieval latency p50/p95/p99, multi-tenant RLS correctness, scale beyond ~5k rows, end-to-end agent task completion, provenance gate correctness, state-machine transitions.

## Why this exists

- **One differentiator none of Pinecone, Letta, Mem0, or Zep have:** a write-time provenance gate. Every `ingest()` call must carry a `commit_sha` or `artifact_hash`; rows without provenance are blocked (or warned) by default. Hallucinated agent memories cannot silently accumulate.
- **No new service.** `CREATE EXTENSION pgmnemo;` in your existing PostgreSQL — no separate API server, no SaaS endpoint, no vendor lock-in.
- **Hybrid recall in-database.** Cosine similarity (HNSW) + BM25 full-text + recency decay + importance weighting, scored in one SQL call.
- **Role isolation built in.** First-class `role + project_id` composite scoping; no hand-rolled RLS.

| Aspect | pgmnemo | Generic Vector DB | Cloud Memory API |
|---|---|---|---|
| Provenance enforcement | ✅ Mandatory | ❌ | ❌ |
| Zero data egress | ✅ In-database | ❌ | ❌ |
| Install model | `CREATE EXTENSION` | External service | SaaS API |
| Self-hosted price | Free (Apache 2.0) | $$$$ | $$$$$ |

## 30-second quickstart

> 📘 **Full installation guide:** [docs/INSTALL.md](docs/INSTALL.md) — 4 paths
> with Docker production setup, GitHub-zip install (no compiler needed), and
> gotcha table. The quickstart below is for laptop evaluation only.

**PGXN install (if `pgxnclient` is available):**

```bash
pgxn install pgmnemo==0.4.0
```

**Docker (production):** pgmnemo is **pure SQL** — no compilation. Bake files
into your image with a 3-line Dockerfile:

```dockerfile
FROM pgvector/pgvector:pg17
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.4.0/pgmnemo-0.4.0.zip /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.4.0.zip -d /tmp/ \
    && cp /tmp/pgmnemo-0.4.0/extension/pgmnemo.control \
          /tmp/pgmnemo-0.4.0/extension/pgmnemo--*.sql \
          /usr/share/postgresql/17/extension/ \
    && apt-get remove -y unzip && rm -rf /tmp/pgmnemo-0.4.0* /var/lib/apt/lists/*
```

**Dev / laptop one-liner (NOT for production — state lost on container rebuild):**

```bash
docker run --name pgmnemo-dev -e POSTGRES_PASSWORD=pass -p 5432:5432 -d pgvector/pgvector:pg17
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.4.0/pgmnemo-0.4.0.zip -o /tmp/pg.zip
docker cp /tmp/pg.zip pgmnemo-dev:/tmp/
docker exec pgmnemo-dev bash -c "cd /tmp && unzip -q pg.zip && cp pgmnemo-0.4.0/extension/pgmnemo.control pgmnemo-0.4.0/extension/pgmnemo--*.sql /usr/share/postgresql/17/extension/"
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
- **MAGMA edge taxonomy** (v0.3.0, **EXPERIMENTAL**) — `edge_kind` ENUM (`semantic | temporal | causal | entity`) with per-kind partial indexes; `recall_lessons()` BFS graph-proximity now correctly uses `edge_kind` instead of the broken v0.2.x `relation_type` string matching. MAGMA §4 (adaptive traversal policy) and §5 (dual-stream consolidation) are not yet implemented.

## Compatibility

| PostgreSQL | Status | pgvector | Platform |
|---|---|---|---|
| 17 | Fully tested | ≥ 0.7.0 required | amd64 (Docker + native) |
| 14–16 | Best-effort | ≥ 0.7.0 required | amd64 (Docker + native) |
| < 14 | Not supported | — | — |
| arm64 | Source-build only | ≥ 0.7.0 required | No pre-built images |

## Documentation

- [INSTALL.md](INSTALL.md) — build, install, configure, upgrade
- [docs/USAGE.md](docs/USAGE.md) — API reference and tuning guide
- [CHANGELOG.md](CHANGELOG.md) — version history
- [docs/MIGRATION.md](docs/MIGRATION.md) — upgrade path and migration notes
- [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) — production deployment checklist
- [examples/](examples/) — annotated runnable examples (init, ingestion, recall)
- [integrations/langchain/](integrations/langchain/) — LangChain retriever integration (`pgmnemo_langchain`)

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

