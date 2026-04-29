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

## Citing

```bibtex
@misc{gaydabura2026pgmnemo,
  author = {Gaydabura, Alex and pgmnemo contributors},
  title  = {pgmnemo: A Provenance-Gated Multi-Agent Memory Substrate for PostgreSQL},
  year   = {2026},
  note   = {ICSE-SEIP submission in preparation}
}
```
