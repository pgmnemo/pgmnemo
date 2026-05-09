# Installing pgmnemo

## Prerequisites

| Requirement | Version |
|---|---|
| PostgreSQL | 17 (14–16 work but untested) |
| pgvector | >= 0.7.0 (HNSW index support) |
| pg_config | must be on `$PATH` |
| make + C compiler | for PGXS build |

Install pgvector first if you haven't:

```bash
# Debian/Ubuntu
sudo apt install postgresql-17-pgvector

# From source
git clone https://github.com/pgvector/pgvector.git
cd pgvector && make && sudo make install
```

## Build from source

```bash
git clone https://github.com/pgmnemo/pgmnemo.git
cd pgmnemo/extension
make
sudo make install
```

The Makefile uses PGXS — `pg_config` must point to your target PostgreSQL installation.

## Enable the extension

```sql
-- Creates the pgmnemo schema and all objects
CREATE EXTENSION pgmnemo CASCADE;
-- CASCADE installs pgvector (vector) automatically if not already present
```

## Configuration GUCs

Set in `postgresql.conf`, `ALTER SYSTEM`, or per-session with `SET`:

| GUC | Values | Default | Effect |
|---|---|---|---|
| `pgmnemo.gate_strict` | `enforce` \| `warn` \| `off` | `enforce` | Controls provenance gate on INSERT |
| `pgmnemo.include_unverified` | `true` \| `false` | `false` | Whether `recall_lessons()` returns unverified rows |

```sql
-- Per-session override (e.g. during backfill)
SET pgmnemo.gate_strict = 'warn';

-- Persistent system-wide change
ALTER SYSTEM SET pgmnemo.gate_strict = 'enforce';
SELECT pg_reload_conf();
```

**Gate modes:**

- `enforce` — INSERT raises an error when neither `commit_sha` nor `artifact_hash` is supplied
- `warn` — INSERT succeeds but emits a `WARNING`; `verified_at` remains `NULL`
- `off` — gate is disabled; all inserts pass through unchecked

## Upgrade

Supported upgrade paths currently documented:

- `0.0.1 -> 0.1.0`
- `0.1.4.1 -> 0.2.0.1`
- `0.2.0.1 -> 0.2.1`

### Upgrade from v0.0.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.0';
```

This applies `pgmnemo--0.0.1--0.1.0.sql`: adds the HNSW index, `ingest()` function, and recency-scoring changes to `recall_lessons()`.

### Upgrade from v0.1.4.1 to v0.2.0.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0.1';
```

### Upgrade from v0.2.0.1 to v0.2.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

For version/API notes, always check:
- [CHANGELOG.md](CHANGELOG.md)
- [docs/USAGE.md](docs/USAGE.md)
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)

## Troubleshooting

**`ERROR: type "vector" does not exist`**
pgvector is not installed. Run `CREATE EXTENSION vector;` first, or use `CREATE EXTENSION pgmnemo CASCADE;`.

**`ERROR: index method "hnsw" does not exist`**
Your pgvector version is older than 0.7.0 — HNSW was added in 0.7.0. Upgrade pgvector.

**`ERROR: embedding dimension mismatch — expected 1024`**
`pgmnemo.ingest()` expects 1024-dimensional vectors. Truncate or pad your embedding, or omit `p_embedding` to store the lesson text-only (full-text search still works).

**Gate raises error on every insert**
`pgmnemo.gate_strict` is `enforce` (default). Supply `p_commit_sha` or `p_artifact_hash`, or set the GUC to `warn` during development.
