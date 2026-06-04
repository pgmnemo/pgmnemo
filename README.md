# pgmnemo

**In-your-Postgres agent memory — single-plan multimodal recall, token-budget navigation, provenance-gated writes.**

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.8.1-green.svg)](CHANGELOG.md)
[![PGXN](https://badge.pgxn.org/stable/pgmnemo.svg)](https://pgxn.org/dist/pgmnemo/)
[![CI](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml/badge.svg)](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1.svg)](https://www.postgresql.org/)
[![LoCoMo recall@10](https://img.shields.io/badge/LoCoMo_recall%4010-0.8409-success.svg)](docs/img/all_metrics_history.md)
[![LongMemEval recall@10](https://img.shields.io/badge/LongMemEval_recall%4010-0.9604-brightgreen.svg)](docs/img/all_metrics_history.md)

> **v0.7.2 (2026-06-01):** **Packaging fix.** The v0.7.1 distribution double-nested the extension directory (`extension/extension/`), making it uninstallable from PGXN and GitHub release zips (`could not open extension control file`). v0.7.2 ships a correctly-structured dist and adds a CI **clean-room install gate** that installs the built zip into a pristine `pgvector/pgvector:pg17` container before any publish. **No schema changes** — SQL is identical to v0.7.1. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.7.1 (2026-06-01):** `recall_hybrid()` `match_confidence` calibration fix (BUG-1) + batch `reinforce(BIGINT[], TEXT)` overload. ⚠️ The v0.7.1 **dist was uninstallable** — use **v0.7.2** instead. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.6.3 (2026-05-24):** **`recall_lessons()` and `recall_hybrid()` now callable without `psycopg2.errors.AmbiguousColumn`.** Added `#variable_conflict use_column` to both function bodies (compile-time only — no scoring change, no signature change). New pg_regress test `role_no_ambiguity` (18 total). `pgmnemo.include_unverified` GUC semantics, hybrid-mode activation conditions, and psycopg2 calling convention documented in `docs/USAGE.md`. Gate: [`benchmarks/gate/v0.6.3.json`](benchmarks/gate/v0.6.3.json). See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.6.1 (2026-05-23):** **`recall_lessons(as_of_ts)`** — 6th param for point-in-time bitemporal recall (F2), propagates to `recall_hybrid()` via GUC. **`as_of_ts` + `stress_recall` pg_regress fixtures** (16/16 PASS, F3). RRF Fix-A (F1) benchmarked on N=500 LME-S with bge-m3: −22.44pp regression with `rrf_diag` ordering; **`recall_hybrid()` scoring unchanged** (`fusion_score` primary); F1 deferred to v0.6.2. Gate: [`benchmarks/gate/v0.6.1.json`](benchmarks/gate/v0.6.1.json). See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.6.0 (2026-05-23):** `pgmnemo.stats().ghost_count` provenance metric + `RAISE NOTICE` on content-hash dedup + `pgmnemo.recall_stats` view ([#26](https://github.com/pgmnemo/pgmnemo/issues/26)) + PostGIS cookbook ([#28](https://github.com/pgmnemo/pgmnemo/issues/28)) + docs. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.5.2.post1 (2026-05-22):** `pgmnemo-mcp` PyPI description fix — adds `README.md` to package so PyPI page renders correctly. No code or SQL changes. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.5.2 (2026-05-22):** `pgmnemo-mcp` wheel fix — empty package on `pip install` ([#32](https://github.com/pgmnemo/pgmnemo/issues/32)), `packaging-smoke` CI gate, `docs/MIGRATION.md` rollback procedure (v0.5→v0.4), `docs/USAGE.md` `temporal_boost` calibration table. No SQL schema change. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.5.1 (2026-05-18):** MCP write path via `ingest()` SP (provenance gate honoured), `temporal_boost` comment corrected. See [CHANGELOG.md](CHANGELOG.md).
>
> **Breaking changes (v0.5.0):** 4-argument `traverse_causal_chain(start, max_depth, role, project)` removed — use 2-argument form + `WHERE` clause. `mem_edge` columns renamed: `lesson_a_id` → `source_id`, `lesson_b_id` → `target_id`. Use `pgmnemo.add_edge()` to avoid direct column references. See [docs/MIGRATION.md](docs/MIGRATION.md).
>
> **v0.8.0 (2026-06-03):** **Token-economy navigation API.** `navigate_locate()` returns ranked lesson IDs within a configurable character budget; `navigate_expand()` fetches full content + graph neighbors on demand. Locate cheaply — expand only what you need. Also: `reembed()` / `reembed_batch()` for in-place embedding refresh, `recompute_content()` for in-place text updates, `source_type` column. See [CHANGELOG.md](CHANGELOG.md).

## Benchmarks (v0.8.0, retrieval-only)

> **Read this before the numbers below:** [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md)
> explains exactly what these recall@K figures mean, what they don't, and where
> our methodology has asymmetries vs paper baselines and competitor positioning.

Real numbers vs published academic benchmarks. **Canonical protocol:** [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md) (v1, frozen 2026-05-13). Full per-version history: [benchmarks/METRICS_BY_VERSION.md](benchmarks/METRICS_BY_VERSION.md). Reproduction commands in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

| Benchmark | Methodology | Embedder | recall@10 / MRR | Honest comparison |
|---|---|---|---|---|
| **LoCoMo** ([Maharana ACL 2024](https://arxiv.org/abs/2402.17753)) | **session-level** (paper-canonical headline) | DRAGON | **0.7994** / **0.5569** | Easier task than paper Table 3 (272 sessions vs 5882 turns search space) |
| **LoCoMo** same paper, turn-level (apples-to-apples with paper baseline) | **turn-level** (retrieval primitive) | DRAGON | recall@5 = **0.302** / MRR = **0.237** | Paper DRAGON dense recall@5 ≈ 0.225 → pgmnemo +7.7pp |
| **LongMemEval-S** ([Wu ICLR 2025](https://arxiv.org/abs/2410.10813)) | retrieval-only, full session | bge-m3 (subst. for Stella V5)¹ | **0.9604** / **0.8472** | Hybrid RRF Fix-A (v0.6.2) closed gap to BM25 baseline² 0.982 from −5pp to −2.2pp |

¹ Stella V5 paper-canonical incompatible with transformers 5.8 — substituted bge-m3 (1024d, MTEB-strong).
² Pure-Python BM25 baseline included for reference: [run_nollm.py](benchmarks/longmemeval/run_nollm.py). Gap narrowed from −5pp (v0.5.x) to −2.2pp (v0.6.2 RRF Fix-A, p=0.017). Full numbers: [benchmarks/METRICS_BY_VERSION.md](benchmarks/METRICS_BY_VERSION.md).

> **The "we beat everyone" framing is wrong.** Our headline session-level
> LoCoMo number compares to a 22× smaller search space than the paper baseline.
> Our LongMemEval number is below a 50-LOC BM25 script. Comparisons with Mem0 /
> Zep / MAGMA on these datasets are apples-to-oranges — they optimise different
> objectives. The honest competitive position is detailed in
> [COMPETITIVE_REALITY.md §3-§5](docs/COMPETITIVE_REALITY.md).

**Reproduce in 3 commands:** see [docs/BENCHMARKS.md#reproducibility](docs/BENCHMARKS.md#reproducibility).

**What pgmnemo's bench does NOT measure** ([§2 of COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md#2-what-we-dont-measure-and-why-it-matters)): insertion throughput, concurrent read/write, retrieval latency p50/p95/p99, multi-tenant RLS correctness, scale beyond ~5k rows, end-to-end agent task completion, provenance gate correctness, state-machine transitions.

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
pgxn install pgmnemo==0.8.1
```

**Docker (production):** pgmnemo is **pure SQL** — no compilation. Bake files
into your image with a 3-line Dockerfile:

```dockerfile
FROM pgvector/pgvector:pg17
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.8.1/pgmnemo-0.8.1.zip /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.8.1.zip -d /tmp/ \
    && cp -r /tmp/pgmnemo-0.8.1/extension/* \
          /usr/share/postgresql/17/extension/ \
    && apt-get remove -y unzip && rm -rf /tmp/pgmnemo-0.8.1* /var/lib/apt/lists/*
```

**Dev / laptop one-liner (NOT for production — state lost on container rebuild):**

```bash
docker run --name pgmnemo-dev -e POSTGRES_PASSWORD=pass -p 5432:5432 -d pgvector/pgvector:pg17
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.8.1/pgmnemo-0.8.1.zip -o /tmp/pg.zip
docker cp /tmp/pg.zip pgmnemo-dev:/tmp/
docker exec pgmnemo-dev bash -c "cd /tmp && unzip -q pg.zip && cp -r pgmnemo-0.8.1/extension/* /usr/share/postgresql/17/extension/"
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

### Usage

```bash
# Start the MCP server (stdio transport — works with Claude Desktop, Cursor, etc.)
pgmnemo-mcp

# Smoke test: verify DB connectivity
DATABASE_URL=postgresql://user:pass@host/db python -m pgmnemo_mcp --smoke
```

### Tools exposed

| Tool | Arguments | Description |
|------|-----------|-------------|
| `pgmnemo.ingest` | `text: str, metadata?: dict` | Store a lesson in agent memory |
| `pgmnemo.recall` | `query: str, top_k?: int` | Retrieve relevant lessons |

`metadata` keys for ingest: `role`, `topic`, `importance` (1–5), `commit_sha`.

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

