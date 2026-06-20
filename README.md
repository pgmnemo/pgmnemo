<div align="center">

<img src="assets/logo.svg" alt="pgmnemo" width="220">

### Agent memory that learns which lessons worked — inspectable in plain SQL, in your Postgres

<!-- GIF: assets/demo.gif (rendered on host via vhs) -->

[![Release](https://img.shields.io/github/v/release/pgmnemo/pgmnemo?label=release&color=brightgreen)](https://github.com/pgmnemo/pgmnemo/releases/latest)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![PyPI](https://img.shields.io/pypi/v/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
[![PyPI Downloads](https://img.shields.io/pypi/dm/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
[![PGXN](https://badge.pgxn.org/stable/pgmnemo.svg)](https://pgxn.org/dist/pgmnemo/)
[![CI](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml/badge.svg)](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1.svg)](https://www.postgresql.org/)
[![Version](https://img.shields.io/badge/version-0.10.0-blue.svg)](https://github.com/pgmnemo/pgmnemo/releases/tag/v0.10.0)
[![LoCoMo recall@10](https://img.shields.io/badge/LoCoMo_recall%4010-0.8409-success.svg)](docs/img/all_metrics_history.md)
[![LongMemEval recall@10](https://img.shields.io/badge/LongMemEval_recall%4010-0.9604-brightgreen.svg)](docs/img/all_metrics_history.md)
<!-- [![GitHub Stars](https://img.shields.io/github/stars/pgmnemo/pgmnemo.svg?style=social)](https://github.com/pgmnemo/pgmnemo) -->

[Docs](docs/USAGE.md) · [Quickstart](#30-second-quickstart) · [Discussions](https://github.com/pgmnemo/pgmnemo/discussions) · [PyPI](https://pypi.org/project/pgmnemo-mcp/)

</div>

⭐ *If pgmnemo is useful to you, star this repo — it helps other developers find it.*

> [!TIP]
> **Try the MCP server in 60 seconds:** `pip install pgmnemo-mcp && pgmnemo-mcp`
> — connects to your existing Postgres and exposes ingest/recall as MCP tools for Claude Desktop, Cursor, and other MCP clients.
> Or run [`examples/01_reinforce_ranking_flip.py`](examples/01_reinforce_ranking_flip.py) to see outcome-learning live (rank flip after 3× reinforce).

**recall@10 = 0.9604 on LongMemEval-S · $0 LLM ingestion cost · `CREATE EXTENSION` install · fully `EXPLAIN`-able**  
In production at [Agency](docs/case_studies/agency.md): agents used **−68% fewer turns** on runs where memory fired a relevant hit.

<details>
<summary>Recent releases (v0.9.5, v0.9.4, v0.9.3) · <a href="CHANGELOG.md">full CHANGELOG</a></summary>

> **v0.9.3 (2026-06-17):** **`reinforce()` delta re-tune + GUC control.** Default success delta `+0.10` → `+0.02`, failure delta `−0.15` → `−0.12` (base-rate-adjusted). Both overridable via `pgmnemo.reinforce_success_delta` / `pgmnemo.reinforce_fail_delta` GUCs per-session or at DB/role level. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.9.2 (2026-06-17):** **Opt-in confidence-weighted ranking GUC.** `pgmnemo.confidence_boost_weight` (default `0.0`, off) adds `w × (confidence − 0.5)` to the `recall_hybrid` score. Activate with `SET pgmnemo.confidence_boost_weight = '0.003';`. Off by default — byte-identical to 0.9.1 without the SET. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.9.1 (2026-06-14):** **P0 graph traversal fix.** `navigate_expand` + `navigate_locate` now traverse all edge kinds — was hardcoded to causal+temporal only, making 100% of production edges invisible. Bidirectional BFS, `relation_types` filter param, threshold 0.7→0.5. See [CHANGELOG.md](CHANGELOG.md).

</details>

## Benchmarks (v0.9.0, retrieval-only)

| Benchmark | Methodology | Embedder | recall@10 / MRR | Honest comparison |
|---|---|---|---|---|
| **LoCoMo** ([Maharana ACL 2024](https://arxiv.org/abs/2402.17753)) | **session-level** (paper-canonical headline) | DRAGON | **0.7994** / **0.5569** | 272-session search space vs paper's 5882-turn space (22× smaller) |
| **LoCoMo** turn-level (apples-to-apples with paper) | **turn-level** (retrieval primitive) | DRAGON | recall@5 = **0.302** / MRR = **0.237** | Paper DRAGON dense recall@5 ≈ 0.225 → +7.7pp |
| **LongMemEval-S** ([Wu ICLR 2025](https://arxiv.org/abs/2410.10813)) | retrieval-only, full session | bge-m3 | **0.9604** / **0.8472** | BM25 baseline = 0.982; gap closed to −2.2pp (v0.6.2 RRF Fix-A) |

Full per-version history: [benchmarks/METRICS_BY_VERSION.md](benchmarks/METRICS_BY_VERSION.md) · **Reproduce:** [docs/BENCHMARKS.md#reproducibility](docs/BENCHMARKS.md#reproducibility)

> ⚠️ **Methodology and caveats:** [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md) — search-space asymmetries, BM25 baseline comparison, and what these numbers do and don't measure.

## Why this exists

**Single-plan multimodal fusion inside your existing Postgres.** pgmnemo ranks across four retrieval channels — HNSW vector (pgvector), graph-edge proximity (`mem_edge` BFS), JSONB metadata predicate pushdown (GIN index), and relational filters (`role`, `project_id`, `state`) — inside a **single SQL query plan**. The PostgreSQL optimizer manages the join, filter, and sort. You call one function; the database handles everything else.

- **No new service.** `CREATE EXTENSION pgmnemo CASCADE` in your existing PostgreSQL — no sidecar, no API server, no vendor lock-in. `pg_dump` backs it up. Logical replication replicates it.
- **Zero data egress.** Embeddings, graph edges, metadata, and scoring never leave your database at retrieval or ingestion time.
- **$0 LLM cost per write.** `ingest()` is a SQL constraint check + indexed INSERT. No model API call on the write path.
- **EXPLAIN-able ranking.** Run `EXPLAIN (ANALYZE, BUFFERS)` on any recall query and see the full plan — impossible with any external RAG service.
- **Provenance-gated writes.** `gate_strict = 'enforce'` blocks writes without a `commit_sha` or `artifact_hash` at the Postgres constraint layer. Hallucinated memories cannot silently accumulate.
- **Token-economy navigation.** `navigate_locate()` returns ranked IDs within a character budget. `navigate_expand()` fetches content + graph neighbors for the IDs you choose. Locate cheaply — expand only what you need.
- **Outcome-learning.** `reinforce(lesson_id, 'success')` or `reinforce(lesson_id, 'failure')` adjusts per-lesson confidence. `recall_hybrid()` returns `match_confidence [0,1]` as an interpretable quality signal.
- **Role isolation built in.** First-class `role + project_id` composite scoping with optional RLS enforcement via `pgmnemo.tenant_id` GUC.

| Aspect | pgmnemo | Generic Vector DB | Cloud Memory API |
|---|---|---|---|
| Single-plan multimodal recall | ✅ Vector + BM25 + graph + JSONB in one SQL plan | ❌ Vector only | ❌ Opaque service |
| Zero data egress | ✅ In-database | ❌ | ❌ |
| EXPLAIN-able ranking | ✅ Full query plan visible | ❌ | ❌ |
| $0 LLM write cost | ✅ Pure SQL | Varies | ❌ ~$0.17–$0.36 / 1K writes |
| Provenance enforcement | ✅ DB-layer constraint | ❌ | ❌ |
| Install model | `CREATE EXTENSION` | External service | SaaS API |
| Self-hosted price | Free (Apache 2.0) | $$$$ | $$$$$ |

In production at [Agency](docs/case_studies/agency.md) (~100k agent runs/week).

## Compatibility matrix

| pgmnemo | PostgreSQL | pgvector | CI status |
|---|---|---|---|
| **0.8.x** (current) | 14 – 17 | ≥ 0.7.0 | 17 ✅ blocking · 14/15/16 ⚠️ aspirational (see below) |
| 0.7.x | 14 – 17 | ≥ 0.7.0 | 17 ✅ blocking · 14/15/16 ⚠️ aspirational |
| 0.6.x | 14 – 17 | ≥ 0.7.0 | 17 ✅ blocking · 14/15/16 ⚠️ aspirational |
| 0.2.x | 14 – 17 | ≥ 0.7.0 | 17 ✅ (legacy CI) |
| ≤ 0.1.x | end-of-life | — | — |

**CI status legend:**

- **17 ✅ blocking** — every release runs `installcheck` + `smoke-recall-hybrid` +
  `bench-gate` on PG 17. A failure here blocks the tag.
- **14/15/16 ⚠️ aspirational** — every CI run also fires a `compat-matrix` job
  against PG 14/15/16 with `continue-on-error: true`. This is **visibility, not
  enforcement** as of v0.8.x; we haven't yet validated every release on
  every PG version. If you run pgmnemo on PG < 17 and hit a bug, file an
  issue — we'll prioritise fixing or downgrading the support claim honestly.
- **0.1.x EOL** — no security fixes, no compatibility commitment.

**Adopters on PG < 17:** the `compat-matrix` job result is visible in every
[CI run](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml). Click
into a recent green run to see which PG versions the latest build passed on.

## 30-second quickstart

> 📘 **For maintainers:** [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md) (bench methodology). Release workflow and internal process docs are maintained privately by the core team.
>
> 📘 **Full installation guide:** [docs/INSTALL.md](docs/INSTALL.md) — 4 paths
> with Docker production setup, GitHub-zip install (no compiler needed), and
> gotcha table. The quickstart below is for laptop evaluation only.

**PGXN install (if `pgxnclient` is available):**

```bash
pgxn install pgmnemo==0.9.5
```

**Docker (production):** pgmnemo is **pure SQL** — no compilation. Bake files
into your image with a 3-line Dockerfile:

```dockerfile
FROM pgvector/pgvector:pg17
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.9.5/pgmnemo-0.9.5.zip /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.9.5.zip -d /tmp/ \
    && cp -r /tmp/pgmnemo-0.9.5/extension/* \
          /usr/share/postgresql/17/extension/ \
    && apt-get remove -y unzip && rm -rf /tmp/pgmnemo-0.9.5* /var/lib/apt/lists/*
```

**Dev / laptop one-liner (NOT for production — state lost on container rebuild):**

```bash
docker run --name pgmnemo-dev -e POSTGRES_PASSWORD=pass -p 5432:5432 -d pgvector/pgvector:pg17
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.9.5/pgmnemo-0.9.5.zip -o /tmp/pg.zip
docker cp /tmp/pg.zip pgmnemo-dev:/tmp/
docker exec pgmnemo-dev bash -c "cd /tmp && unzip -q pg.zip && cp -r pgmnemo-0.9.5/extension/* /usr/share/postgresql/17/extension/"
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

- **Single-plan multimodal recall** — HNSW vector + BM25 full-text + graph-edge proximity + JSONB metadata pushdown, all ranked in one SQL query plan. `EXPLAIN (ANALYZE)` the full execution plan at any time.
- **Token-economy navigation** — `navigate_locate()` returns ranked IDs within a configurable character budget; `navigate_expand()` fetches full content + graph neighbors on demand. Locate cheaply; expand only what you need.
- **Provenance gate** — `enforce` / `warn` / `off` modes via `pgmnemo.gate_strict` GUC. `enforce` (default) rejects writes at the Postgres constraint layer when `commit_sha` and `artifact_hash` are both absent.
- **Outcome-learning** — `reinforce(lesson_id, 'success' | 'failure' | 'neutral')` adjusts per-lesson confidence. `recall_hybrid()` returns `confidence` in scoring and `match_confidence [0,1]` as an interpretable quality signal.
- **Hybrid RRF scoring** (Fix-A, v0.6.2) — sparse-safe Reciprocal Rank Fusion over vector + BM25; plus aux terms for importance, recency decay, and provenance strength.
- **Bitemporal point-in-time recall** — `recall_lessons(..., as_of_ts)` restricts to the validity window `t_valid_from ≤ as_of_ts < t_valid_to`. Time-travel your agent's memory.
- **In-place maintenance** — `reembed()` / `reembed_batch()` refresh embeddings without new bitemporal rows; `recompute_content()` updates lesson text in-place with automatic `content_hash` + TSV cascade.
- **Graph traversal** — `traverse_causal_chain()` and `traverse_temporal_window()` walk typed `mem_edge` relationships (edge_kind: `semantic | temporal | causal | entity`).
- **Role scoping** — `role + project_id` composite isolation; `role_filter=NULL` pools across roles; optional RLS enforcement via `pgmnemo.tenant_id` GUC.
- **Diagnostic observability** — `pgmnemo.stats()` (19 columns including confidence distribution); `pgmnemo.recall_stats` view for call-count tracking.

## Compatibility

| PostgreSQL | Status | pgvector | Platform |
|---|---|---|---|
| 17 | Fully tested | ≥ 0.7.0 required | amd64 (Docker + native) |
| 14–16 | Best-effort | ≥ 0.7.0 required | amd64 (Docker + native) |
| < 14 | Not supported | — | — |
| arm64 | Source-build only | ≥ 0.7.0 required | No pre-built images |

## MCP Wrapper

`pgmnemo-mcp` is an [MCP](https://modelcontextprotocol.io/) server that exposes
pgmnemo's ingest and recall capabilities as tool calls for AI agents and LLM hosts.

### Install

```bash
pip install pgmnemo-mcp          # from PyPI (once published)
# or from source:
pip install -e pgmnemo_mcp/
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql://localhost/pgmnemo` | libpq connection string |
| `MCP_PORT` | `8765` | Port for HTTP/SSE transport |
| `EMBEDDING_SERVER` | _(unset)_ | OpenAI-compatible embeddings endpoint (e.g. `http://server:1234/v1/embeddings`). When set, `ingest`/`recall` embed text themselves for vector+BM25 hybrid recall. Unset → text-only (BM25) fallback. (v0.8.2) |
| `EMBEDDING_MODEL` | _(unset)_ | Optional model name sent in the embeddings request. |
| `EMBEDDING_DIM` | `1024` | Expected embedding dimension; mismatched dims are ignored (text-only fallback). Must match the extension's `vector(1024)` (e.g. bge-m3). |

### Usage

```bash
# Start the MCP server (stdio transport — works with Claude Desktop, Cursor, etc.)
pgmnemo-mcp

# Smoke test: verify DB connectivity
DATABASE_URL=postgresql://user:pass@host/db python -m pgmnemo_mcp --smoke
```

### Run via Docker (Linux / dependency isolation)

If `pip install pgmnemo-mcp` conflicts with other libraries in your agent
environment (common on Linux agent workflows), run the MCP in a container so its
`psycopg2`/`mcp` deps stay isolated from your host:

```bash
docker pull gaidabura/pgmnemo-mcp:0.9.5              # published to Docker Hub on each release tag
docker build -t pgmnemo-mcp:0.9.5 pgmnemo_mcp/        # ...or build locally
```

#### From zero — full quickstart (fresh DB → MCP)

```bash
# 1. A Postgres with the extension. pgmnemo is pure SQL (no compiler):
docker run -d --name pgmem -e POSTGRES_PASSWORD=pass pgvector/pgvector:pg17
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.9.5/pgmnemo-0.9.5.zip -o /tmp/p.zip
unzip -q /tmp/p.zip -d /tmp
docker cp /tmp/pgmnemo-0.9.5/extension/. pgmem:/usr/share/postgresql/17/extension/
docker exec pgmem psql -U postgres -c "CREATE EXTENSION pgmnemo CASCADE;"

# 2. (optional) an OpenAI-compatible embeddings endpoint (1024-dim, e.g. bge-m3 / LM Studio)
#    — without it, recall is BM25-only.

# 3. Smoke-test the MCP against that DB (note: -e BEFORE the image, and the --smoke
#    flag lives in `python -m pgmnemo_mcp`, not the default `pgmnemo-mcp` entrypoint):
docker run --rm --link pgmem -e DATABASE_URL=postgresql://postgres:pass@pgmem:5432/postgres \
  --entrypoint python gaidabura/pgmnemo-mcp:0.9.5 -m pgmnemo_mcp --smoke
  # → "pgmnemo-mcp smoke: OK (recall_lessons returned N rows)"
```

MCP client config (stdio via `docker run -i`):

```json
{
  "mcpServers": {
    "pgmnemo": {
      "command": "docker",
      "args": ["run", "-i", "--rm",
               "-e", "DATABASE_URL", "-e", "EMBEDDING_SERVER", "-e", "EMBEDDING_MODEL",
               "gaidabura/pgmnemo-mcp:0.9.5"],
      "env": {
        "DATABASE_URL": "postgresql://user:pass@host:5432/db",
        "EMBEDDING_SERVER": "http://server:1234/v1/embeddings"
      }
    }
  }
}
```

The `-e VAR` flags forward the values from `env` into the container. If your DB or
embedding server is on the Docker host, add `--add-host=host.docker.internal:host-gateway`
(or `--network=host` on Linux) and point the URLs at `host.docker.internal`.

### Tools exposed

| Tool | Arguments (all top-level) | Description |
|------|-----------|-------------|
| `pgmnemo.ingest` | `text` (req), `role`, `topic`, `importance`, `project_id`, `commit_sha`, `artifact_hash`, `metadata` | Store a lesson in agent memory |
| `pgmnemo.recall` | `query` (req), `top_k` | Retrieve relevant lessons |

`ingest` arguments are **top-level** — do **not** nest them under `metadata`. Defaults:
`role="mcp_agent"`, `topic="general"`, `importance=3`, `project_id=1`, `metadata={}`.
Pass `commit_sha` or `artifact_hash` to satisfy the provenance gate; without one the
lesson is a "ghost" (excluded from recall by default unless `pgmnemo.include_unverified` is on).
Note: `recall` searches **globally** (no `role`/`project_id` filter) even though `ingest`
scopes by `project_id` — call `pgmnemo.recall_hybrid()` in SQL directly if you need
project/role-scoped retrieval.

### MCP Registry

Server name: `pgmnemo`
Entry point: `pgmnemo-mcp` (console script)
Transport: stdio (default) · SSE (set `MCP_PORT`)

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

