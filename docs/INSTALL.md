# pgmnemo Installation Guide

**Versions:** v0.5.0+
**License:** Apache-2.0
**Prerequisites:** PostgreSQL 14+ with [pgvector](https://github.com/pgvector/pgvector) 0.7.0+

This document covers four installation paths in increasing order of operational
robustness. **Most production Docker users want path 3 (Dockerfile COPY).**

---

## Path 1 — PGXN (recommended for hand-installed PostgreSQL)

```bash
# Requires pgxnclient (pip install pgxnclient)
pgxn install pgmnemo==0.5.0
psql -d your_db -c "CREATE EXTENSION pgmnemo CASCADE;"
```

`pgxnclient` downloads, validates, and installs to `$(pg_config --sharedir)/extension/`
on the host. Use this when you own the PostgreSQL host filesystem.

---

## Path 2 — GitHub release zip (no compiler needed)

pgmnemo is **pure SQL** — no C code, no compilation step. The `Makefile` exists
for PGXS conventions but `make install` only copies `.sql` and `.control` files.
You can skip `make` entirely:

```bash
# 1. Download the release zip
curl -LO https://github.com/pgmnemo/pgmnemo/releases/download/v0.5.0/pgmnemo-0.5.0.zip
unzip pgmnemo-0.5.0.zip
cd pgmnemo-0.5.0/extension/

# 2. Copy directly to PostgreSQL's extension directory
SHAREDIR=$(pg_config --sharedir)
sudo cp pgmnemo.control pgmnemo--*.sql "$SHAREDIR/extension/"

# 3. Load the extension
psql -d your_db -c "CREATE EXTENSION pgmnemo CASCADE;"
```

No `postgresql-server-dev-*` package required. No build tools.

---

## Path 3 — Docker production install (most users want this)

Standard Docker images (`pgvector/pgvector:pg17`, `postgres:17`, etc.) do **not**
include build tooling. The `docker exec ... make install` pattern in the README
quickstart works for development but has two problems for production:

1. **Build tools absent.** The container lacks `postgresql-server-dev-17`, `make`,
   `gcc`, so `make install` fails with `No such file or directory`.
2. **State doesn't persist.** Files copied into `/usr/share/postgresql/17/extension/`
   live in the container layer, not in a volume. `docker compose down && up` loses
   the extension.

Recommended: build a custom image that bakes the extension files into the image
layer. **No compilation involved** — `COPY` is enough.

### 3.1 Custom Dockerfile

```dockerfile
# docker/postgres/Dockerfile
FROM pgvector/pgvector:pg17

# Download release zip (or use ADD from a local checkout)
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.5.0/pgmnemo-0.5.0.zip /tmp/

RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && unzip /tmp/pgmnemo-0.5.0.zip -d /tmp/ \
    && cp /tmp/pgmnemo-0.5.0/extension/pgmnemo.control \
          /tmp/pgmnemo-0.5.0/extension/pgmnemo--*.sql \
          /usr/share/postgresql/17/extension/ \
    && rm -rf /tmp/pgmnemo-0.5.0 /tmp/pgmnemo-0.5.0.zip \
    && apt-get remove -y unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

### 3.2 Compose snippet

```yaml
# docker-compose.yml
services:
  postgres:
    build:
      context: ./docker/postgres
    environment:
      POSTGRES_PASSWORD: bench
      POSTGRES_DB: bench
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "15432:5432"

volumes:
  pgdata:
```

### 3.3 Load the extension

```bash
docker compose up -d
docker compose exec postgres psql -U bench -d bench -c "CREATE EXTENSION pgmnemo CASCADE;"
```

### 3.4 Upgrading pgmnemo in production

```dockerfile
# bump the ADD line to the new version, rebuild image:
ADD https://github.com/pgmnemo/pgmnemo/releases/download/v0.5.0/pgmnemo-0.5.0.zip /tmp/
```

Then:
```bash
docker compose build postgres
docker compose up -d postgres
docker compose exec postgres psql -U bench -d bench -c "ALTER EXTENSION pgmnemo UPDATE TO '0.5.0';"
```

Volume `pgdata` carries the schema state across image rebuilds. The extension
files are baked into the new image layer.

---

## Path 4 — Vendored extension directory (air-gapped style)

If you cannot reach the internet at build time (air-gapped, strict CI policy),
vendor the extension files into your repository:

```bash
# One-time bootstrap (run on your dev machine with internet access)
mkdir -p docker/postgres/pgmnemo-extension/
curl -L https://github.com/pgmnemo/pgmnemo/releases/download/v0.5.0/pgmnemo-0.5.0.zip | \
    bsdtar -xf- -C /tmp/
cp /tmp/pgmnemo-0.5.0/extension/pgmnemo.control \
   /tmp/pgmnemo-0.5.0/extension/pgmnemo--*.sql \
   docker/postgres/pgmnemo-extension/
git add docker/postgres/pgmnemo-extension/ && git commit -m "vendor pgmnemo 0.5.0"
```

Dockerfile:
```dockerfile
FROM pgvector/pgvector:pg17
COPY pgmnemo-extension/ /usr/share/postgresql/17/extension/
```

On every pgmnemo upgrade, repeat the curl+cp+commit step. ~25 files to manage;
not great but predictable.

---

## Reading the GUCs (read this if you came from `SHOW`)

**pgmnemo is a pure-SQL extension. `SHOW pgmnemo.*` will fail** with
`unrecognized configuration parameter`. This is a PostgreSQL constraint:
custom GUCs can only be registered in `pg_settings` via the C API
(`DefineCustomXxxVariable`), and pure-SQL extensions cannot call that.

Use `current_setting('...', TRUE)` instead — the second argument `missing_ok=TRUE`
makes it return NULL instead of erroring when the GUC isn't set:

```sql
-- Read a GUC value (returns NULL if unset → falls back to function default):
SELECT current_setting('pgmnemo.recency_weight', TRUE);

-- Set for current session:
SET pgmnemo.recency_weight = '0.05';

-- Persist across sessions (requires superuser):
ALTER SYSTEM SET pgmnemo.recency_weight = '0.05';
SELECT pg_reload_conf();

-- Verify what's persisted (works because ALTER SYSTEM writes to postgresql.auto.conf):
SELECT name, setting, sourcefile, sourceline
FROM pg_file_settings
WHERE name LIKE 'pgmnemo.%';
```

All GUCs accept the same `SET` / `ALTER SYSTEM SET` / `current_setting()` pattern shown above.

| GUC | Default | Range | Category |
|---|---|---|---|
| `pgmnemo.recency_weight` | 0.05 | 0.0–0.3 | recall scoring |
| `pgmnemo.importance_weight` | 0.15 | 0.0–0.3 | recall scoring |
| `pgmnemo.ef_search` | 100 | 10–500 | recall scoring |
| `pgmnemo.disable_hybrid` | FALSE | bool | recall routing |
| `pgmnemo.graph_proximity_weight` | 0.2 | 0.0–0.5 | recall scoring |
| `pgmnemo.temporal_boost` | 1.0 | 0.0–20.0 | recall scoring (v0.5.0+) |
| `pgmnemo.gate_strict` | `enforce` | `enforce`/`warn`/`off` | write/ingest |
| `pgmnemo.include_unverified` | FALSE | bool | write/ingest |
| `pgmnemo.max_query_text_chars` | 2000 | 0–any | write/ingest (v0.5.0+) |
| `pgmnemo.tenant_id` | `''` | any project_id as text | multi-tenant RLS |

See `docs/SQL_REFERENCE.md §3` for full semantics, scoring formulas, and per-version default-change history.

---

## Verifying the install

After any install path:

```sql
-- Version
SELECT pgmnemo.version();   -- → '0.5.0'

-- Sanity smoke
SELECT pgmnemo.ingest('test', 1, 'hello', 'world', 3, NULL, 'abc1234');
SELECT lesson_id, score, lesson_text
FROM pgmnemo.recall_lessons(NULL::vector(1024), 5, 'test', 1, 'hello');
DELETE FROM pgmnemo.agent_lesson WHERE role = 'test';
```

If the version output and the SELECT both succeed, you're installed correctly.

---

## Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `extension "vector" is not available` | pgvector not installed first | Use `pgvector/pgvector:pg17` base image, or `CREATE EXTENSION vector;` before `pgmnemo` |
| `extension files for pgmnemo do not exist` | `.sql` / `.control` not in `$(pg_config --sharedir)/extension/` | Check copy step; verify with `ls $(pg_config --sharedir)/extension/pgmnemo*` |
| `make: command not found` (in container) | You're using `make install`; not needed | Switch to Path 2 (zip) or Path 3 (Dockerfile) — no compiler needed |
| `function already exists but is not a member of extension` on UPDATE | Intermediate manual SQL patch applied outside extension | See [docs/MIGRATION.md §B.5](MIGRATION.md) recovery recipe |
| `SHOW pgmnemo.recency_weight` errors | PostgreSQL pure-SQL extension limitation | Use `current_setting('pgmnemo.recency_weight', TRUE)` — see above |
| Extension files disappear after `docker compose down && up` | Files in container layer, not volume | Switch from `docker exec ... make install` to Path 3 (Dockerfile bake) |

---

## What next

- **Production usage patterns:** [docs/USAGE.md](USAGE.md)
- **Full SQL reference:** [docs/SQL_REFERENCE.md](SQL_REFERENCE.md)
- **Version-to-version upgrades:** [docs/MIGRATION.md](MIGRATION.md)
- **Benchmarks and methodology:** [docs/BENCHMARKS.md](BENCHMARKS.md), [docs/BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md)
- **Honest competitive context:** [docs/COMPETITIVE_REALITY.md](COMPETITIVE_REALITY.md)
