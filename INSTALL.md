# Installing pgmnemo

## Compatibility

### PostgreSQL

| Version | Status |
|---|---|
| PostgreSQL 17 | **Supported** — CI-tested on every merge |
| PostgreSQL 14, 15, 16 | **Best-effort** — untested in CI; known runtime issues on 14/15 fixed in v0.2.0.1 (see Troubleshooting) |
| PostgreSQL 13 and older | **Not supported** — generated columns (`GENERATED ALWAYS AS … STORED`) require PG 12+; HNSW requires pgvector ≥ 0.7.0 which requires PG 12+ |

### pgvector

| Version | Status |
|---|---|
| ≥ 0.7.0 | **Required** — HNSW index support added in 0.7.0 |
| 0.5.x, 0.6.x | **Not supported** — extension will install but `CREATE INDEX … USING hnsw` fails |

---

## Prerequisites

```bash
# Debian/Ubuntu — install PostgreSQL 17 + pgvector together
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list'
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
sudo apt-get update
sudo apt-get install -y postgresql-17 postgresql-17-pgvector postgresql-server-dev-17 build-essential

# macOS (Homebrew)
brew install postgresql@17 pgvector

# From pgvector source (any platform)
git clone https://github.com/pgvector/pgvector.git
cd pgvector && make && sudo make install
```

Verify pgvector version before proceeding:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'vector';
-- must be >= 0.7.0
```

---

## Build and install

```bash
git clone https://github.com/pgmnemo/pgmnemo.git
cd pgmnemo/extension

# Build (pg_config must point to your target PostgreSQL)
make

# Install extension files into PostgreSQL's extension directory
sudo make install

# Verify files are in place
ls $(pg_config --sharedir)/extension/pgmnemo*
```

---

## Fresh install (any supported version of PostgreSQL)

Connect to the target database as a superuser or a role with `CREATE EXTENSION` privilege:

```sql
-- Installs pgvector (vector) automatically if not present
CREATE EXTENSION pgmnemo CASCADE;

-- Verify
SELECT pgmnemo.version();
-- returns: 0.2.1
```

`CASCADE` handles the `vector` dependency. If you prefer explicit control:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION pgmnemo;
```

---

## Configuration GUCs

Set in `postgresql.conf`, via `ALTER SYSTEM`, or per-session with `SET`.

| GUC | Type | Default | Valid range / values | Effect |
|---|---|---|---|---|
| `pgmnemo.gate_strict` | TEXT | `enforce` | `enforce` \| `warn` \| `off` | Provenance gate on INSERT |
| `pgmnemo.include_unverified` | BOOL | `false` | `true` \| `false` | Include ghost lessons in `recall_lessons()` |
| `pgmnemo.recency_weight` | FLOAT | `0.08` | `0.0`–`1.0` | Recency decay weight (γ) in scoring formula |
| `pgmnemo.ef_search` | INT | `100` | `10`–`500` | HNSW `ef_search` applied via `SET LOCAL` per query |
| `pgmnemo.graph_proximity_weight` | FLOAT | `0.2` | `0.0`–`0.5` | Graph-proximity weight (δ) in scoring formula |
| `pgmnemo.tenant_id` | TEXT | `''` (empty) | any project_id as text | Multi-tenant row isolation; empty = bypass |

**Gate modes (`pgmnemo.gate_strict`):**

- `enforce` — INSERT raises an error when neither `commit_sha` nor `artifact_hash` is supplied (production default)
- `warn` — INSERT succeeds but emits a `WARNING`; `verified_at` remains `NULL` (development / backfill)
- `off` — gate disabled; all inserts pass through unchecked

**Typical setup after install:**

```sql
-- Apply persistent GUC defaults
ALTER SYSTEM SET pgmnemo.ef_search          = '100';
ALTER SYSTEM SET pgmnemo.recency_weight     = '0.08';
ALTER SYSTEM SET pgmnemo.gate_strict        = 'enforce';
SELECT pg_reload_conf();

-- During a bulk backfill: temporarily relax the gate
SET pgmnemo.gate_strict = 'warn';
-- ... INSERT rows ...
RESET pgmnemo.gate_strict;
```

---

## Upgrade paths

PostgreSQL resolves the upgrade chain automatically from the installed migration scripts. Run:

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

This works from **any** installed version listed below. PostgreSQL chains through intermediate scripts automatically (e.g., 0.1.2 → 0.1.3 → 0.1.4 → … → 0.2.1).

### Complete upgrade chain

```
0.0.1 → 0.1.0 → 0.1.1 → 0.1.2 → 0.1.3 → 0.1.4 ─┬─→ 0.1.4.1 ─→ 0.2.0 ─→ 0.2.0.1 → 0.2.1
                                                    │
                                                    └──────────────→ 0.2.0 (shortcut)
```

### Shortcut paths

| From | To | Note |
|---|---|---|
| 0.1.4 | 0.2.0 | `pgmnemo--0.1.4--0.2.0.sql` available — skip 0.1.4.1 |
| 0.1.4.1 | 0.2.0 | `pgmnemo--0.1.4.1--0.2.0.sql` available |
| 0.2.0 | 0.2.1 | must pass through 0.2.0.1 (`pgmnemo--0.2.0--0.2.0.1.sql` + `pgmnemo--0.2.0.1--0.2.1.sql`) |

`ALTER EXTENSION pgmnemo UPDATE TO '0.2.1'` resolves all shortcut paths automatically.

### Per-version upgrade notes

#### 0.0.1 → 0.1.0

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.0';
```

Adds: HNSW index (replaces IVFFlat), `pgmnemo.ingest()`, `recall_lessons()` with hybrid scoring.

#### 0.1.0 → 0.1.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.1';
```

Adds: `pgmnemo.recency_weight` GUC.

Post-upgrade optional:

```sql
ALTER SYSTEM SET pgmnemo.recency_weight = '0.08';
SELECT pg_reload_conf();
```

#### 0.1.1 → 0.1.2

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.2';
```

Adds: `prov_strength` tri-state column, `recall_lessons_pooled()`.

#### 0.1.2 → 0.1.3

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.3';
```

Adds: `verifier_role TEXT` column on `agent_lesson`.

#### 0.1.3 → 0.1.4

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.4';
```

Adds: lifecycle state machine (`state`, `state_changed_at`, `transition_lesson()`), provenance FK columns (`source_run_id`, `source_task_id`), TTL (`expires_at`, `evict_expired_lessons()`).

No data migration required. New columns are nullable or have defaults.

#### 0.1.4 → 0.1.4.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.4.1';
```

**P0 fix** (INS-029): `recall_lessons()` raised `ERROR: parameter name "role" used more than once` on every call. If you are on 0.1.4, apply this immediately — `recall_lessons()` is broken at 0.1.4.

Also: idempotent upgrade DDL guards added throughout.

#### 0.1.4.1 → 0.2.0  *(or 0.1.4 → 0.2.0 shortcut)*

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0';
```

Adds: `pgmnemo.mem_edge` table (directed typed edges), `traverse_causal_chain()`, `traverse_temporal_window()`, graph-proximity mixin in `recall_lessons()` scoring.

New GUC:

```sql
ALTER SYSTEM SET pgmnemo.graph_proximity_weight = '0.2';
SELECT pg_reload_conf();
```

#### 0.2.0 → 0.2.0.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0.1';
```

**Hotfix** (INS-030): fixes `NUMERIC → DOUBLE PRECISION` cast error in `traverse_temporal_window()` that caused runtime failures on PostgreSQL 14/15. Version bump only — no schema changes. Apply before upgrading to 0.2.1.

#### 0.2.0.1 → 0.2.1

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

Adds: `pgmnemo.tenant_id` GUC for row-level security, `pgmnemo.ef_search` GUC, `traverse_causal_chain(direction)` parameter. Fixes `project_id` param collision in `recall_lessons()`. Lowers `recency_weight` default from 0.20 to 0.08.

Post-upgrade required actions:

```sql
ALTER SYSTEM SET pgmnemo.ef_search      = '100';
ALTER SYSTEM SET pgmnemo.recency_weight = '0.08';  -- or keep 0.20 if you prefer old behaviour
SELECT pg_reload_conf();
```

### Verify current version after upgrade

```sql
SELECT pgmnemo.version();
```

### Check available upgrade paths (before running)

```sql
SELECT name, installed_version, default_version
FROM pg_available_extensions
WHERE name = 'pgmnemo';
```

```sql
-- List all registered migration scripts PostgreSQL knows about
SELECT name, installed_version, default_version
FROM pg_available_extension_versions
WHERE name = 'pgmnemo'
ORDER BY installed_version;
```

---

## Rollback limitations

**There are no downgrade scripts.** pgmnemo does not ship `pgmnemo--0.2.1--0.1.x.sql` files.

| Scenario | Recovery path |
|---|---|
| Upgrade fails mid-script (DDL error) | Run `ALTER EXTENSION pgmnemo UPDATE TO '<target>'` again — all DDL is idempotent (`CREATE OR REPLACE`, `ADD COLUMN IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`). The re-run will skip already-applied changes and complete the remaining steps. |
| Upgrade succeeds but new behaviour is wrong | Roll back to a **pre-upgrade PostgreSQL base backup** (pg_basebackup / snapshot). No SQL-level downgrade path exists. |
| Data written under new schema must be preserved | Export with `pg_dump`, restore to old version database, migrate data manually. |
| Emergency: revert to 0.1.4.1 after 0.2.1 upgrade | Not possible via SQL. Requires restoring from backup taken before the upgrade. |

**Backup recommendation:** always take a `pg_dump` of the target database before applying any `ALTER EXTENSION pgmnemo UPDATE`.

```bash
pg_dump -Fc -f pgmnemo_pre_upgrade_$(date +%Y%m%d).dump <dbname>
```

---

## Troubleshooting

**`ERROR: type "vector" does not exist`**

pgvector is not installed. Install it and retry:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
-- then retry:
CREATE EXTENSION pgmnemo;
-- or:
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

**`ERROR: index method "hnsw" does not exist`**

Your pgvector is older than 0.7.0. HNSW was added in 0.7.0.

```sql
SELECT extversion FROM pg_extension WHERE extname = 'vector';
-- if < 0.7.0: upgrade pgvector, then retry
```

**`ERROR: embedding dimension mismatch — expected 1024, got N`**

`pgmnemo.ingest()` requires 1024-dimensional vectors. Either use a 1024-dim embedder (e.g., `BAAI/bge-m3`) or omit `p_embedding` to store the lesson text-only (full-text search still works without a vector).

**`ERROR: pgmnemo provenance gate [enforce]: INSERT rejected`**

`pgmnemo.gate_strict = 'enforce'` (default). Supply `p_commit_sha` or `p_artifact_hash` to `pgmnemo.ingest()`, or relax during development:

```sql
SET pgmnemo.gate_strict = 'warn';
```

**`ERROR: parameter name "role" used more than once`** (on 0.1.4)

This is INS-029, a P0 bug in v0.1.4. Upgrade immediately:

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.1.4.1';
-- or go straight to current:
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

**`ERROR: operator does not exist: numeric = double precision`** (PostgreSQL 14/15, on `traverse_temporal_window`)

This is INS-030, fixed in v0.2.0.1. Upgrade:

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

**`ALTER EXTENSION pgmnemo UPDATE` fails with `could not find upgrade path`**

The extension files for intermediate versions are not installed in PostgreSQL's `sharedir`. Re-run `make install` from the full pgmnemo source tree, which installs all migration scripts, then retry the `ALTER EXTENSION` command.

**RLS blocks all rows after setting `pgmnemo.tenant_id`**

If `pgmnemo.tenant_id` is set to a value that matches no `project_id`, all rows are hidden. Reset to empty to bypass:

```sql
SET pgmnemo.tenant_id = '';
```
