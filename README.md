<div align="center">

<img src="assets/logo.svg" alt="pgmnemo" width="220">

### Persistent memory for coding agents — in the Postgres you already run

[![Release](https://img.shields.io/github/v/release/pgmnemo/pgmnemo?label=release&color=brightgreen)](https://github.com/pgmnemo/pgmnemo/releases/latest)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![PyPI](https://img.shields.io/pypi/v/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
[![PyPI Downloads](https://img.shields.io/pypi/dm/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
[![PGXN](https://badge.pgxn.org/stable/pgmnemo.svg)](https://pgxn.org/dist/pgmnemo/)
[![CI](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml/badge.svg)](https://github.com/pgmnemo/pgmnemo/actions/workflows/ci.yml)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1.svg)](https://www.postgresql.org/)
[![Version](https://img.shields.io/badge/version-0.17.0-blue.svg)](https://github.com/pgmnemo/pgmnemo/releases/tag/v0.15.0)
[![LoCoMo recall@10](https://img.shields.io/badge/LoCoMo_recall%4010-0.8409-success.svg)](docs/img/all_metrics_history.md)
[![LongMemEval recall@10](https://img.shields.io/badge/LongMemEval_recall%4010-0.9604-brightgreen.svg)](docs/img/all_metrics_history.md)

[Docs](docs/USAGE.md) · [Quickstart](#quickstart) · [Discussions](https://github.com/pgmnemo/pgmnemo/discussions) · [PyPI](https://pypi.org/project/pgmnemo-mcp/)

</div>

## The problem

Your coding agent finishes a debugging session. It found the root cause, fixed it, understood something about the codebase. Next session: blank slate. Same mistake, same debugging cycle, same cost.

This happens because agent memory lives in the context window. When the session ends, the memory is gone. The agent that ran 500 sessions on your codebase knows exactly as much as a fresh install.

## See it work

The following transcript was captured on a pgmnemo v0.15.1 instance holding 8,112 active lessons (July 2026). Real output, copied from the session.

**Session 1** — an agent debugs a connection-pooling issue and writes what it learned:

```sql
SELECT pgmnemo.ingest(
  'developer', 99, 'connection-pooling',
  'When PgBouncer runs in transaction mode, prepared statements fail
   silently. Switch to session mode, or disable the statement cache
   (statement_cache_mode=none in asyncpg).',
  4, NULL, 'demo_readme_proof'
);

-- Result: 45087
```

One SQL call. The lesson is stored in your Postgres with a provenance link (`commit_sha`), indexed for hybrid retrieval. No LLM API call on the write path.

**Session 2** — a different agent, fresh context, hits the same problem. It asks memory:

```sql
SELECT lesson_id, score, lesson_text
FROM pgmnemo.recall_lessons(
  query_embedding := NULL::vector, k := 3,
  role_filter := 'developer',
  query_text := 'prepared statements broken with pgbouncer'
);

  [1] id=45087  score=0.0500
      When PgBouncer runs in transaction mode, prepared statements fail
      silently. Switch to session mode, or disable the statement cache
      (statement_cache_mode=none in asyncpg).
```

The lesson from Session 1 surfaces as the top result. The second agent skips the debugging cycle entirely.

The score of `0.0500` is BM25-only (no embedding vector was passed with this lesson). With embeddings configured, hybrid vector+BM25 recall produces richer ranking — but even text-only search finds the right answer when the vocabulary overlaps. Run `EXPLAIN ANALYZE` on any recall query to see exactly what Postgres did.

<details>
<summary>Recent releases (v0.15.0, v0.14.2, v0.14.1) · <a href="CHANGELOG.md">full CHANGELOG</a></summary>

> **v0.15.0 (2026-07-27):** **Episodic recall — situation fingerprint index.** `extract_sit_fp(topic, text)` normalises a lesson into a situation class fingerprint; `recall_situation(sit_fp, project_id, role, k)` returns prior lessons for that situation class via O(log n) expression index — no embedding search required. Two differently-phrased reports of the same failure class return the same fingerprint; two similarly-phrased reports of different classes return different fingerprints. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.14.2 (2026-07-26):** **Curation-honesty: `reclassify_corpus()` must not overwrite curator-owned content types.** Root cause (P1 data-destructive): `reclassify_corpus()` was overwriting `'event'` and `'relation'` labels set by typed write verbs. Fixed via `classifier_owned_types()` canonical source of truth; `consolidate()` now accumulates `evidence_count` correctly across passes. See [CHANGELOG.md](CHANGELOG.md).
>
> **v0.14.1 (2026-07-25):** **P0 recall latency fix + `undo_consolidate()`.** `recall_hybrid()` was taking 22–30 s on parts of a 7,440-lesson corpus (HNSW planner regression — LIMIT via plpgsql variable caused generic plan with Seq Scan). Fixed with `EXECUTE format(... LIMIT %s)`. `undo_consolidate()` added — exact inverse of `consolidate()` apply; consolidation is now reversible. See [CHANGELOG.md](CHANGELOG.md).

</details>

## Quickstart

**Option A: Wire your AI CLI (two commands)**

```bash
pip install pgmnemo-mcp
pgmnemo init claude   # or: codex | gemini
```

Session-capture and recall hooks wire into Claude Code, Codex CLI, or Gemini CLI automatically. Memory accumulates across sessions without manual `ingest()` calls.

**Option B: Install the extension directly**

```bash
# Dev / laptop evaluation (NOT for production — state lost on container rebuild):
docker run --name pgmnemo-dev -e POSTGRES_PASSWORD=pass -p 5432:5432 -d pgvector/pgvector:pg17
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.9.5/pgmnemo-0.9.5.zip -o /tmp/pg.zip
docker cp /tmp/pg.zip pgmnemo-dev:/tmp/
docker exec pgmnemo-dev bash -c "cd /tmp && unzip -q pg.zip && cp -r pgmnemo-0.9.5/extension/* /usr/share/postgresql/17/extension/"
```

```sql
-- psql -h localhost -U postgres
CREATE EXTENSION pgmnemo CASCADE;
```

**Option C: Docker production image** — pgmnemo is pure SQL, no compilation:

```dockerfile
FROM pgvector/pgvector:pg17
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.9.5/pgmnemo-0.9.5.zip /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.9.5.zip -d /tmp/ \
    && cp -r /tmp/pgmnemo-0.9.5/extension/* \
          /usr/share/postgresql/17/extension/ \
    && apt-get remove -y unzip && rm -rf /tmp/pgmnemo-0.9.5* /var/lib/apt/lists/*
```

**PGXN:** `pgxn install pgmnemo==0.9.5`

> Full installation guide with gotcha table: [INSTALL.md](INSTALL.md)

## Scenarios

### You wire hooks and forget about them

You run `pgmnemo init claude`. From now on, every Claude Code session on this project captures lessons automatically and recalls relevant ones at the start of each new session.

You don't call `ingest()` or `recall()` manually. The hooks handle it. After a week, your agent has accumulated 40 lessons — auth patterns, deployment quirks, test fixtures that break on Mondays. New sessions start with context from old ones.

### Your corpus grows; duplicates pile up

After 200 sessions, you have 800 lessons. Many are near-duplicates — the same deployment failure reported 12 different ways.

```sql
SELECT * FROM pgmnemo.consolidate(dry_run := true);

-- cluster_id | canonical_id | member_count | similarity
-- 1          | 4023         | 12           | 0.94
-- 2          | 4089         | 8            | 0.93
-- 3          | 4112         | 5            | 0.92
-- ...
```

You review the clusters, then run `consolidate(dry_run := false)`. 12 reports of the same deployment failure collapse into one canonical lesson. Changed your mind? `undo_consolidate(4023)` reverses it.

On a real 7,400-lesson corpus, `consolidate()` found 399 near-duplicate clusters — a quarter of the total. Largest cluster: 55 reports of the same failure.

### You need to know where a lesson came from

A lesson says "never use LEFT JOIN on the events table — it causes a full scan." Is that real? When was it learned? What commit produced it?

```sql
SELECT lesson_text, commit_sha, created_at, match_confidence
FROM pgmnemo.recall_hybrid(
  query_text := 'events table join performance',
  role_filter := 'developer'
);
```

Every lesson carries its provenance. With `gate_strict = 'enforce'` (the default), `ingest()` rejects writes that lack a `commit_sha` or `artifact_hash` — at the Postgres constraint layer, not application code. Hallucinated lessons from failed runs don't graduate to long-term memory.

### You run multiple agents on different projects

Each agent has a role and a project ID. Recall is scoped:

```sql
-- Agent A (backend, project 1) sees only backend lessons for project 1
SELECT * FROM pgmnemo.recall_lessons(
  query_text := 'database migration',
  role_filter := 'backend_dev',
  project_id_filter := 1
);

-- Agent B (frontend, project 2) sees only its own scope
SELECT * FROM pgmnemo.recall_lessons(
  query_text := 'component state management',
  role_filter := 'frontend_dev',
  project_id_filter := 2
);
```

Role+project isolation is built into the schema. Optional RLS enforcement via `pgmnemo.tenant_id` GUC.

### Your agent hits the same class of failure again

Two differently-worded bug reports describe the same underlying failure — a race condition in the queue consumer. `extract_sit_fp()` normalises both into the same situation fingerprint:

```sql
SELECT pgmnemo.extract_sit_fp('queue', 'consumer hangs under load');
SELECT pgmnemo.extract_sit_fp('queue', 'messages stuck when traffic spikes');
-- Both return the same fingerprint

SELECT * FROM pgmnemo.recall_situation('queue:consumer-hang', 99, 'developer', 5);
-- Returns prior lessons for this situation class via O(log n) index lookup
```

No embedding search required. The fingerprint index is an expression index — `EXPLAIN` shows the index scan.

## Honest limits

We publish where we lose. A benchmark result that shows only wins is indistinguishable from cherry-picking.

### The −68% turns result has a caveat

Agents at one engineering team used 68% fewer turns on runs where memory fired a relevant hit. This is significant on that slice. Averaged across *all* runs — including runs where memory had nothing relevant to say — the effect washes out.

Memory only helps when it has something relevant to say. We do not claim "−68% fewer turns" without this qualification.

### The graph layer does not improve recall

pgmnemo includes `add_edge()` and graph traversal primitives (`graph_proximity` in `recall_hybrid`, `navigate_locate`, `navigate_expand`). The `graph_proximity_weight` GUC defaults to 0.2.

We have no published benchmark showing graph-augmented recall outperforms hybrid (vector + BM25) alone. The graph layer ships because it is architecturally useful for dependency tracking and causal chains, but it is not a recall quality lever today. We will not claim otherwise until a controlled experiment demonstrates otherwise.

### BM25 baseline still wins on LongMemEval-S

| Benchmark | pgmnemo recall@10 | BM25 baseline recall@10 | Gap |
|---|---|---|---|
| LongMemEval-S (ICLR 2025) | 0.9604 | 0.982 | −2.2pp |
| LoCoMo (ACL 2024) | 0.8409 (session-level) | — | 22× smaller search space than paper Table 3 |
| LoCoMo turn-level | recall@5 = 0.302 | Paper DRAGON = 0.225 | +7.7pp |
| Production corpus (N=1,060) | 0.5745 | — | Leave-one-out self-retrieval |

On LongMemEval-S, a 50-line BM25 script still beats pgmnemo's hybrid recall by 2.2 percentage points. The gap closed from −5pp (v0.5.x) to −2.2pp (v0.6.2 RRF Fix-A, p=0.017), but it has not closed fully.

Full benchmark methodology and caveats: [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md) · Reproducibility: [docs/BENCHMARKS.md#reproducibility](docs/BENCHMARKS.md#reproducibility) · Per-version history: [benchmarks/METRICS_BY_VERSION.md](benchmarks/METRICS_BY_VERSION.md)

## How it works

pgmnemo is a PostgreSQL extension. `CREATE EXTENSION pgmnemo CASCADE` creates the `pgmnemo` schema with tables, indexes, and functions. Everything runs inside your existing Postgres process — no sidecar, no external service.

| Aspect | pgmnemo | Generic Vector DB | Cloud Memory API |
|---|---|---|---|
| Hybrid recall (vector + BM25 + JSONB) in one SQL plan | EXPLAIN-able | Vector-only or opaque | Opaque service |
| Data residency | In your database | External service | Vendor cloud |
| LLM cost per write | $0 (pure SQL) | Varies | ~$0.17–$0.36 / 1K writes |
| Provenance enforcement | DB-layer constraint | None | None |
| Near-duplicate collapsing | `consolidate()` built-in | None | None |
| Cross-model hooks | Claude Code / Codex / Gemini | None | Varies |
| Install model | `CREATE EXTENSION` | External service | SaaS API |
| Backup | `pg_dump` | Vendor-specific | Vendor-specific |

### What ships in the box

- **Hybrid recall** — HNSW vector + BM25 full-text + JSONB predicate pushdown in one SQL plan. `EXPLAIN ANALYZE` works on every query.
- **Provenance gate** — `enforce` / `warn` / `off` modes via `pgmnemo.gate_strict` GUC. `enforce` rejects unverified writes at the Postgres constraint layer.
- **Corpus housekeeping** — `consolidate()` collapses near-duplicates (dry-run by default); `undo_consolidate()` reverses any merge; `classify_content_type()` labels lessons as incident / decision / entity / fact / procedure (deterministic, no LLM).
- **Episodic recall** — `recall_situation()` matches by situation class fingerprint, O(log n) index lookup.
- **Outcome-learning** — `reinforce(lesson_id, 'success' | 'failure')` adjusts per-lesson confidence via Beta posterior. `recall_hybrid()` returns `match_confidence [0,1]`.
- **Cross-model hooks** — `pgmnemo init claude|codex|gemini` wires session-capture and recall into your AI CLI.
- **Bitemporal point-in-time recall** — `recall_lessons(..., as_of_ts)` restricts to a validity window. Time-travel your agent's memory.
- **Role scoping** — `role + project_id` composite isolation with optional RLS enforcement.
- **In-place maintenance** — `reembed()` / `reembed_batch()` refresh embeddings; `recompute_content()` updates lesson text with automatic hash cascade.
- **Graph traversal (opt-in)** — `traverse_causal_chain()` and `traverse_temporal_window()` walk typed edges. See [Honest limits](#honest-limits) for the current state of graph-augmented recall.
- **Diagnostic observability** — `pgmnemo.stats()` (19 columns); `pgmnemo.recall_stats` view for call-count tracking.
- **Corpus export** — `pgmnemo export` produces human-readable Markdown.

## Compatibility

| PostgreSQL | Status | pgvector | Platform |
|---|---|---|---|
| 17 | Fully tested | ≥ 0.7.0 required | amd64 (Docker + native) |
| 14–16 | Best-effort | ≥ 0.7.0 required | amd64 (Docker + native) |
| < 14 | Not supported | — | — |
| arm64 | Source-build only | ≥ 0.7.0 required | No pre-built images |

**CI status:**
- **17 blocking** — every release runs `installcheck` + `smoke-recall-hybrid` + `bench-gate`. A failure blocks the tag.
- **14/15/16 aspirational** — `compat-matrix` job fires with `continue-on-error: true`. Visibility, not enforcement. If you run pgmnemo on PG < 17 and hit a bug, [file an issue](https://github.com/pgmnemo/pgmnemo/issues) — we'll prioritise fixing or downgrading the support claim honestly.

## MCP server

`pgmnemo-mcp` is an [MCP](https://modelcontextprotocol.io/) server that exposes pgmnemo's ingest and recall as tool calls for AI agents and LLM hosts.

### Install

```bash
pip install pgmnemo-mcp          # from PyPI
# or from source:
pip install -e pgmnemo_mcp/
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql://localhost/pgmnemo` | libpq connection string |
| `MCP_PORT` | `8765` | Port for HTTP/SSE transport |
| `EMBEDDING_SERVER` | _(unset)_ | OpenAI-compatible embeddings endpoint (e.g. `http://server:1234/v1/embeddings`). When set, `ingest`/`recall` embed text for vector+BM25 hybrid recall. Unset → text-only (BM25) fallback. |
| `EMBEDDING_MODEL` | _(unset)_ | Model name sent in the embeddings request. |
| `EMBEDDING_DIM` | `1024` | Expected embedding dimension. Must match `vector(1024)` (e.g. bge-m3). |

### Usage

```bash
# Start (stdio transport — works with Claude Desktop, Cursor, etc.)
pgmnemo-mcp

# Smoke test
DATABASE_URL=postgresql://user:pass@host/db python -m pgmnemo_mcp --smoke
```

### Docker (dependency isolation)

```bash
docker pull gaidabura/pgmnemo-mcp:0.9.5
# or build locally:
docker build -t pgmnemo-mcp:0.9.5 pgmnemo_mcp/
```

<details>
<summary>Full Docker quickstart (fresh DB → MCP)</summary>

```bash
# 1. Postgres with the extension (pure SQL, no compiler):
docker run -d --name pgmem -e POSTGRES_PASSWORD=pass pgvector/pgvector:pg17
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.9.5/pgmnemo-0.9.5.zip -o /tmp/p.zip
unzip -q /tmp/p.zip -d /tmp
docker cp /tmp/pgmnemo-0.9.5/extension/. pgmem:/usr/share/postgresql/17/extension/
docker exec pgmem psql -U postgres -c "CREATE EXTENSION pgmnemo CASCADE;"

# 2. (optional) OpenAI-compatible embeddings endpoint (1024-dim, e.g. bge-m3)
#    — without it, recall is BM25-only.

# 3. Smoke-test:
docker run --rm --link pgmem -e DATABASE_URL=postgresql://postgres:pass@pgmem:5432/postgres \
  --entrypoint python gaidabura/pgmnemo-mcp:0.9.5 -m pgmnemo_mcp --smoke
  # → "pgmnemo-mcp smoke: OK (recall_lessons returned N rows)"
```

</details>

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

### Tools exposed

| Tool | Arguments | Description |
|------|-----------|-------------|
| `pgmnemo.ingest` | `text` (req), `role`, `topic`, `importance`, `project_id`, `commit_sha`, `artifact_hash`, `metadata` | Store a lesson |
| `pgmnemo.recall` | `query` (req), `top_k` | Retrieve relevant lessons |

`ingest` arguments are top-level — do not nest under `metadata`. Pass `commit_sha` or `artifact_hash` to satisfy the provenance gate; without one the lesson is a "ghost" (excluded from recall by default).

## Documentation

- [INSTALL.md](INSTALL.md) — build, install, configure, upgrade
- [docs/USAGE.md](docs/USAGE.md) — API reference and tuning guide
- [CHANGELOG.md](CHANGELOG.md) — version history
- [docs/MIGRATION.md](docs/MIGRATION.md) — upgrade path
- [docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md) — production deployment checklist
- [examples/](examples/) — annotated runnable examples
- [integrations/langchain/](integrations/langchain/) — LangChain retriever integration

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
