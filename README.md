# pgmnemo

> Multi-agent memory layer for PostgreSQL — provenance-gated, HNSW-accelerated, zero-dependency, Apache-2.0.

`pgmnemo` is a PostgreSQL extension that gives multi-agent AI systems durable, auditable memory
without a separate service, a SaaS dependency, or vendor lock-in. Install it with one SQL command
and read/write agent memory directly inside your existing database.

Built for indie AI builders and enterprise teams under data-sovereignty constraints who already run
PostgreSQL and want their agent memory in the same perimeter.

## Quick start

```bash
git clone https://github.com/pgmnemo/pgmnemo.git
cd pgmnemo/extension
make
sudo make install
```

```sql
-- In psql:
CREATE EXTENSION pgmnemo CASCADE;

-- Write a lesson (provenance gate fires on INSERT)
SELECT pgmnemo.ingest(
    p_role        := 'developer',
    p_project_id  := 1,
    p_topic       := 'authentication',
    p_lesson_text := 'Always rotate JWT secrets after a key-compromise incident.',
    p_commit_sha  := 'abc1234'
);

-- Read back with hybrid scoring
SELECT lesson_text, score
FROM pgmnemo.recall_lessons(
    query_embedding := <your_vector>,
    query_text      := 'JWT secret rotation',
    role            := 'developer'
);
```

## Features

- **HNSW vector search** — fast approximate nearest-neighbour recall via `pgvector` HNSW indexes
- **Provenance gate** — writes are blocked (or warned) unless a `commit_sha` or `artifact_hash` is supplied; eliminates ghost lessons from hallucinating agents
- **Recency-weighted scoring** — hybrid score combines cosine similarity + BM25 full-text + recency decay
- **Role scoping** — first-class `role + project_id` composite isolation; no hand-rolled RLS required

## Status

[![CI](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml/badge.svg)](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml)

v0.1.0 — HNSW + recency scoring + `ingest()` API. Pre-release; targeting public launch after ICSE-SEIP paper submission (~T+8w from 2026-04-29).

## Documentation

- [INSTALL.md](INSTALL.md) — build, install, configure, upgrade
- [docs/USAGE.md](docs/USAGE.md) — API reference and tuning guide
- [design/STRATEGY.md](design/STRATEGY.md) — vision and roadmap
- [design/POSITIONING.md](design/POSITIONING.md) — competitive landscape
- [design/](design/) — architecture and build plan

## Why pgmnemo

| | Other memory layers | `pgmnemo` |
|---|---|---|
| Form factor | separate service / SaaS / MCP server | `CREATE EXTENSION pgmnemo;` |
| Data location | their cloud / their server | your existing PostgreSQL |
| Trust gate on writes | none | **provenance gate** — requires commit SHA or artifact hash |
| Multi-agent role isolation | RLS or none | first-class `role + project_id` composite |
| Vendor lock-in | yes | none (Apache-2.0, plain SQL) |
| Embeddings | provider-coupled | bring your own |

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions accepted under the DCO sign-off model.

## v0.1.1 — recency_weight GUC

Per BENCHMARK_FEATURE_REQUIREMENTS.md item 4: `pgmnemo.recency_weight` (default 0.2)
controls the γ coefficient in `recall_lessons()` scoring. Used for paper §5 R1 ablation.
Range: 0.0–1.0.

```sql
-- Disable recency for R1 ablation (γ=0)
SET pgmnemo.recency_weight = '0.0';
SELECT * FROM pgmnemo.recall_lessons(query_embedding := $1);

-- Restore default
RESET pgmnemo.recency_weight;
```

Upgrade from v0.1.0: `ALTER EXTENSION pgmnemo UPDATE TO '0.1.1';`

## v0.1.2 — tri-state provenance + pooled recall

Per RESEARCH_PROVENANCE_GATE.md §5/§6: `prov_strength` is now tri-state (0.0/0.4/1.0).
The commit-only middle value changes from 0.5→0.4, aligning with CRAG "Ambiguous" semantics.
Backward compatible — rows with `(NULL, NULL)` or `(non-NULL, non-NULL)` are unaffected.

Per RESEARCH_RLS_PATTERNS.md §5 D4: `recall_lessons_pooled(query_embedding, k, app_id)` is
the canonical R3-ablation entrypoint — drops the role filter for cross-role recall comparison.

```sql
-- Pooled cross-role recall (R3 ablation)
SELECT * FROM pgmnemo.recall_lessons_pooled(query_embedding := $1, app_id := 42);
```

Upgrade from v0.1.1: `ALTER EXTENSION pgmnemo UPDATE TO '0.1.2';`

## Citing

```bibtex
@misc{gaydabura2026pgmnemo,
  author = {Gaydabura, Alex and pgmnemo contributors},
  title  = {pgmnemo: A Provenance-Gated Multi-Agent Memory Substrate for PostgreSQL},
  year   = {2026},
  note   = {ICSE-SEIP submission in preparation}
}
```
