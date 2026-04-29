# pgmnemo

> Multi-agent memory substrate for PostgreSQL — provenance-gated, zero-dependency, Apache-2.0.

`pgmnemo` is a PostgreSQL extension that gives multi-agent AI systems durable, auditable memory
without introducing a separate service, a SaaS dependency, or a vendor lock-in. Install it with one
SQL command and read/write agent memory directly from your existing database.

```sql
CREATE EXTENSION pgmnemo;
SELECT pgmnemo.recall_lessons(role := 'developer', topic := 'authentication');
```

## Status

🚧 **Pre-release.** Phase 1 (SQL-only schema + retrieval + provenance gate) under active development.
Targeting public release after ICSE-SEIP paper submission (~T+8w from 2026-04-29).

## Why pgmnemo

| | other memory layers | `pgmnemo` |
|---|---|---|
| Form factor | separate service, SaaS, MCP server | `CREATE EXTENSION pgmnemo;` |
| Data location | their cloud, their server | your existing PostgreSQL |
| Trust gate on writes | none | **provenance gate** — write requires verifiable commit SHA or artifact hash |
| Multi-agent role isolation | RLS or none | first-class — role + project + provenance composite keys |
| Vendor lock-in | yes (data egress, proprietary API) | none (Apache-2.0, plain SQL) |
| Embeddings | tied to one provider | bring your own (any LLM provider) |

The unique mechanism is the **provenance gate**: an agent observation is not promoted to long-term
memory until a verifiable artifact (commit SHA in repo, file hash on disk, or signed external claim)
is attached. This eliminates the "ghost lesson" failure mode common in multi-agent memory systems.

## Architecture

Phase 1 (current):
- Pure SQL + PL/pgSQL (no C, no Rust, no `pgrx`)
- Storage: standard PostgreSQL tables with `JSONB` metadata + `tsvector` full-text + GIN indexes
- Retrieval: PL/pgSQL functions, role-aware filtering, recursive CTE for lightweight graph traversal
- Provenance: BEFORE INSERT trigger checks artifact verifiability against external store

Phase 2 (future, if Phase 1 traction warrants):
- pgvector ANN integration for semantic search at scale
- Apache AGE for graph traversal beyond 3 hops
- Optional MCP server for IDE integration

## Quick start

```bash
# Requires PostgreSQL 14+
git clone https://github.com/pgmnemo/pgmnemo.git
cd pgmnemo
make
sudo make install

# In your psql session:
CREATE EXTENSION pgmnemo;
SELECT pgmnemo.version();
```

## Documentation

See `docs/`:
- `STRATEGY.md` — vision and roadmap
- `POSITIONING.md` — how `pgmnemo` differs from OpenBrain, Constructive AgenticDB, MAGMA, mem0, Zep
- `research/` — academic background (PAPER v0.2, ADRs, design notes)

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions are accepted under the DCO sign-off model.

## Citing

If you use `pgmnemo` in academic work, please cite:

```bibtex
@misc{gaydabura2026pgmnemo,
  author = {Gaydabura, Alex and pgmnemo contributors},
  title  = {pgmnemo: A Provenance-Gated Multi-Agent Memory Substrate for PostgreSQL},
  year   = {2026},
  note   = {ICSE-SEIP submission in preparation}
}
```

## Project status & support

This is an early-stage open-source project led by a small team. Issues and PRs are welcome.
For roadmap and ongoing decisions, see `docs/STRATEGY.md`.
