# pgmnemo SQL Reference

**Version coverage:** v0.9.6 (current)  
**Status:** authoritative — function signatures here match `extension/pgmnemo--*.sql`.

For usage patterns and worked examples see `USAGE.md`; for upgrade paths see
`MIGRATION.md`; for benchmark numbers see `BENCHMARKS.md`.

---

## 1. Schema

All pgmnemo objects live in the `pgmnemo` schema. `CREATE EXTENSION pgmnemo CASCADE`
installs the `pgmnemo` schema and pulls `vector` (pgvector) and `pg_trgm`.

### 1.1 Tables

| Table | Purpose |
|---|---|
| `pgmnemo.agent_lesson` | Primary memory rows. One row per lesson/observation. |
| `pgmnemo.mem_edge` | Typed edges between lessons (semantic, temporal, causal, entity). |

#### `pgmnemo.agent_lesson`

| Column | Type | Notes |
|---|---|---|
| `lesson_id` | BIGSERIAL PRIMARY KEY | |
| `role` | TEXT NOT NULL | agent role string used for recall filtering |
| `project_id` | INT NOT NULL | tenant / scoping key |
| `topic` | TEXT NOT NULL | short human-readable label |
| `lesson_text` | TEXT NOT NULL | full lesson body |
| `importance` | SMALLINT DEFAULT 3 | 1 (low) – 5 (critical) |
| `embedding` | vector(1024) | NULL = text-only recall path |
| `commit_sha` | TEXT | provenance — git SHA |
| `artifact_hash` | TEXT | provenance — signed artifact hash (e.g. `sha256:…`) |
| `metadata` | JSONB DEFAULT '{}' | freeform extension data |
| `state` | TEXT DEFAULT 'candidate' | lifecycle: draft, candidate, validated, canonical, deprecated, archived, rejected, conflicted |
| `verified_at` | TIMESTAMPTZ | auto-set by `ingest()` when provenance present |
| `created_at` | TIMESTAMPTZ DEFAULT NOW() | |
| `lesson_tsv` | tsvector | v0.2.2+, auto-populated for BM25 retrieval |
| `expires_at` | TIMESTAMPTZ | optional TTL (NULL = forever) |
| `source_run_id` | BIGINT | optional pointer to producing run |
| `source_task_id` | BIGINT | optional pointer to producing task |
| `t_valid_from` | TIMESTAMPTZ | bitemporality: start of validity period; NULL = no start constraint (v0.5.0) |
| `t_valid_to` | TIMESTAMPTZ | bitemporality: end of validity period; NULL = currently valid (v0.5.0) |
| `content_hash` | TEXT | SHA-256 of `lesson_text` — detects content drift across versions (v0.5.0) |
| `last_recalled_at` | TIMESTAMPTZ | timestamp of the most recent recall; NULL = never recalled since v0.9.5 (v0.9.5) |
| `recall_count` | BIGINT DEFAULT 0 | total number of recall-function calls that returned this lesson (v0.9.5) |
| `item_kind` | TEXT DEFAULT `'note'` | content category: `note`, `skill_md`, `template`, `script`, `reference`, `config`, `spec`. CHECK-constrained to this set. (v0.9.6) |
| `version_n` | INT DEFAULT 1 | monotonically increasing version counter; increment on substantial revision (v0.9.6) |
| `patch_count` | INT DEFAULT 0 | minor patch edit counter; reset to 0 on each `version_n` increment (v0.9.6) |
| `source_dag_id` | TEXT NULL | opaque identifier of the workflow run that produced this lesson; NULL = unknown/manual origin. Covered by sparse index `ix_pgmnemo_agent_lesson_source_dag_id WHERE source_dag_id IS NOT NULL`. (v0.9.6) |

Indexes: HNSW on `embedding` (cosine_ops), B-tree on `(role, project_id)`,
GIN on `lesson_tsv` (v0.2.2+), GIN on `metadata`,
partial B-tree on `(last_recalled_at ASC NULLS FIRST, created_at ASC) WHERE is_active` (v0.9.5),
partial B-tree on `source_dag_id WHERE source_dag_id IS NOT NULL` (v0.9.6).

#### `pgmnemo.memory_ingest_log` (v0.9.6)

Migration batch tracking table. Tracks ingestion runs from legacy memory tables into
`pgmnemo.agent_lesson`. One row per batch. Operators may `DROP` this table once the
cutover window is complete and no further legacy batches are expected.

| Column | Type | Notes |
|---|---|---|
| `id` | BIGSERIAL PRIMARY KEY | |
| `source_origin` | TEXT NOT NULL | identifies the legacy source, e.g. `'mem.item'` or `'legacy.agent_memory'` |
| `min_id` | BIGINT | lowest source-table id ingested in this batch (inclusive); NULL = unknown |
| `max_id` | BIGINT | highest source-table id ingested in this batch (inclusive); NULL = unknown |
| `ingested_at` | TIMESTAMPTZ DEFAULT NOW() | when the batch completed |
| `retired_at` | TIMESTAMPTZ NULL | when the source was decommissioned; NULL = still active |

#### `pgmnemo.mem_edge`

| Column | Type | Notes |
|---|---|---|
| `id` | BIGSERIAL PRIMARY KEY | |
| `source_id` | BIGINT REFERENCES `agent_lesson(id)` ON DELETE CASCADE | source endpoint |
| `target_id` | BIGINT REFERENCES `agent_lesson(id)` ON DELETE CASCADE | target endpoint |
| `relation_type` | TEXT | freeform annotation (e.g. `CAUSED_BY`, `CO_OCCURRED`) |
| `edge_kind` | `pgmnemo.edge_kind` ENUM NOT NULL | v0.3.0+: `{semantic, temporal, causal, entity}` |
| `weight` | DOUBLE PRECISION DEFAULT 1.0 | edge strength 0–1 |
| `metadata` | JSONB DEFAULT '{}' | |
| `created_at` | TIMESTAMPTZ DEFAULT NOW() | |

Indexes: per-kind partial B-tree on `(source_id, target_id) WHERE edge_kind = '<value>'`.

##### Population contract (canonical, since v0.4.0)

Adopters streaming edges from their orchestration layer should follow this contract.
`pgmnemo.add_edge()` (v0.5.0, see §1.2) encapsulates this pattern. You can also write the `INSERT ... ON CONFLICT` directly.

**Semantics:**

| Column | Convention |
|---|---|
| `source_id` | The **earlier** lesson in the causal chain (or the anchor of the relation) |
| `target_id` | The **later** lesson, or the satellite |
| `relation_type` | One of `CAUSED_BY`, `CO_OCCURRED`, `DERIVED_FROM`, `ENTITY_LINK` (freeform but canonical values shown) |
| `edge_kind` | Required ENUM since v0.3.0 — must match the semantics of `relation_type` (mapping below) |
| `weight` | Edge confidence in `[0.0, 1.0]`. `1.0` = certain (e.g. same git commit); `0.5` = inferred co-occurrence; `< 0.3` = weak, possibly noise. |
| `metadata` | Optional context (e.g. `{"source": "run_12345"}`) |

**Recommended `relation_type` → `edge_kind` mapping:**

| relation_type | edge_kind |
|---|---|
| `CAUSED_BY`, `DERIVED_FROM`, `CONTRADICTS` | `causal` |
| `CO_OCCURRED` | `temporal` |
| `ENTITY_LINK`, `SHARED_TAG` | `entity` |
| anything else | `semantic` (default) |

**Idempotent insertion pattern (canonical):**

```sql
INSERT INTO pgmnemo.mem_edge
    (source_id, target_id, relation_type, edge_kind, weight, metadata)
VALUES
    ($1, $2, $3, $4, $5, $6)
ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
DO UPDATE SET
    weight   = EXCLUDED.weight,
    metadata = pgmnemo.mem_edge.metadata || EXCLUDED.metadata;
```

Note: the unique constraint `(source_id, target_id, relation_type)` (partial: `valid_until IS NULL`) is the
de-dup key. Edges with different `relation_type` between the same pair of lessons
are intentionally allowed (e.g. `A CAUSED_BY B` and `A CO_OCCURRED B` may both be
true).

**Update policy options** (pick one and document in your application):

- `mode='replace'` — `SET weight = EXCLUDED.weight` (last-writer-wins; default in the SQL above)
- `mode='max'` — `SET weight = GREATEST(mem_edge.weight, EXCLUDED.weight)` (monotonic non-decreasing)
- `mode='avg'` — `SET weight = (mem_edge.weight + EXCLUDED.weight) / 2.0` (running average; requires care with race conditions)

### 1.2 `pgmnemo.add_edge()` helper (v0.5.0)

Two overloads are provided. Use the 5-param form for simple writes; the 6-param form when you need a specific conflict resolution mode.

**5-param form** (convenience, mode=`'replace'`):

```sql
pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}'
) RETURNS VOID
```

**6-param form** (full control):

```sql
pgmnemo.add_edge(
    p_source_id     BIGINT,
    p_target_id     BIGINT,
    p_relation_type TEXT,
    p_weight        FLOAT8  DEFAULT 1.0,
    p_metadata      JSONB   DEFAULT '{}',
    p_mode          TEXT    DEFAULT 'replace'
) RETURNS VOID
```

Idempotent edge writer. Inserts a new active edge; on conflict on `(source_id, target_id, relation_type)` with `valid_until IS NULL`, updates weight and metadata per `p_mode`:

| `p_mode` | Conflict action |
|---|---|
| `'replace'` (default) | `SET weight = EXCLUDED.weight, metadata = EXCLUDED.metadata, updated_at = now()` |
| `'max'` | `SET weight = GREATEST(existing, EXCLUDED)` (monotonic non-decreasing) |
| `'avg'` | `SET weight = (existing + EXCLUDED) / 2.0` (running mean) |

`edge_kind` is derived automatically from `p_relation_type` using the canonical mapping in §1.1. `p_weight` is clamped to `[0.0, 1.0]`. FK violations on unknown `source_id`/`target_id` propagate to the caller. `NULL` inputs raise a NOT NULL constraint violation (not a PL/pgSQL null pointer error).

```sql
-- Simple write (5-param, mode='replace' by default)
SELECT pgmnemo.add_edge(101, 205, 'CAUSED_BY');

-- With explicit weight and metadata
SELECT pgmnemo.add_edge(101, 205, 'CAUSED_BY', 0.85, '{"run_id": 7320}');

-- Full control: running-max weight
SELECT pgmnemo.add_edge(101, 205, 'CAUSED_BY', 0.85, '{"run_id": 7320}', 'max');
```

### 1.3 ENUM types

```sql
CREATE TYPE pgmnemo.edge_kind AS ENUM ('semantic', 'temporal', 'causal', 'entity');
```

### 1.4 Views

#### `pgmnemo.recall_stats` (v0.6.0, R9)

Surfaces call counts and cumulative timing for `recall_lessons()`,
`recall_hybrid()`, and `ingest()` from `pg_stat_user_functions`.

```sql
SELECT * FROM pgmnemo.recall_stats;
-- schema | function_name  | calls | total_time | self_time | observed_at
```

**Requires** `track_functions = 'pl'` or `track_functions = 'all'` in
`postgresql.conf` (default is `'none'`); rows appear only after the first call
following a `SELECT pg_stat_reset()`.

---

## 2. Public functions

### 2.1 `pgmnemo.version()`

```sql
pgmnemo.version() RETURNS TEXT
```

Returns the installed extension version (e.g. `'0.5.0'`).

### 2.2 `pgmnemo.ingest(...)`

Validated write path. Use this instead of raw `INSERT` to get embedding dim
validation, automatic `verified_at` stamping, and provenance gate enforcement.

```sql
pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT  DEFAULT 3,
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT      DEFAULT NULL,
    p_artifact_hash TEXT      DEFAULT NULL,
    p_metadata      JSONB     DEFAULT '{}'
) RETURNS BIGINT     -- new lesson_id
```

Provenance gate behavior set by GUC `pgmnemo.gate_strict`:
- `enforce` (default): fail if both `commit_sha` and `artifact_hash` are NULL
- `warn`: succeed, emit WARNING, leave `verified_at` NULL
- `off`: no check (development only)

#### Disabling the provenance gate

If `ingest()` / `INSERT` is rejected with `pgmnemo provenance gate [enforce]:
INSERT rejected`, the gate is doing its job — it requires every lesson to carry a
`commit_sha` or `artifact_hash`. You can relax or disable it via the
`pgmnemo.gate_strict` GUC at the scope you need:

```sql
-- Current connection only:
SET pgmnemo.gate_strict = 'off';

-- Current transaction only:
SET LOCAL pgmnemo.gate_strict = 'off';

-- Persistently for a whole database (applies to new connections):
ALTER DATABASE mydb SET pgmnemo.gate_strict = 'off';

-- Persistently for a specific role:
ALTER ROLE myuser SET pgmnemo.gate_strict = 'off';
```

Use `'warn'` instead of `'off'` to keep writes flowing while still logging an
audit warning for each unprovenanced row.

**Recommended:** rather than turning the gate off, pass `commit_sha` or
`artifact_hash` when you ingest. The write then succeeds in **any** mode and the
lesson keeps its provenance (and stays eligible for recall — unprovenanced rows
are "ghost" lessons with `verified_at IS NULL`, excluded from recall by default).

**Allowing recall of ghost lessons (v0.8.2):** If you have ghost lessons
already ingested and want to include them in recall, set
`pgmnemo.include_unverified`. This GUC accepts `on`, `true`, `1`, or `yes`:

```sql
-- Current session only (takes effect immediately):
SET pgmnemo.include_unverified = 'on';

-- Current transaction only:
SET LOCAL pgmnemo.include_unverified = 'on';

-- Persist for a database — applies ONLY to NEW connections:
ALTER DATABASE mydb SET pgmnemo.include_unverified = 'on';

-- Persist for a role — applies ONLY to NEW connections:
ALTER ROLE myuser SET pgmnemo.include_unverified = 'on';
```

> ⚠️ **Connection-pool / MCP footgun (v0.8.2):** `ALTER DATABASE SET` and
> `ALTER ROLE SET` apply only when a connection is established — they do **not**
> affect already-open connections. If you use a connection pool (PgBouncer,
> RDS Proxy) or a long-lived MCP server, the existing connections will not pick
> up the change. For those, run `SET pgmnemo.include_unverified = 'on'` directly
> in each session, or restart the connection pool / MCP process so new
> connections inherit the database default.
>
> To diagnose: if `recall_lessons()` returns 0 rows, pgmnemo will emit a
> `NOTICE` telling you how many ghost lessons exist in your role/project scope
> and are being excluded. Enable client_min_messages to `notice` to see it.

**Bitemporal dedup NOTICE (v0.6.0, RFC Q5):** When an `INSERT` triggers
the `trg_agent_lesson_bitemporal_close` trigger (same `content_hash` as an active
row), `ingest()` emits:
```
NOTICE: pgmnemo.ingest: bitemporal close+create fired — closed N prior version(s)
        (content_hash=<hash>). New lesson_id=<id>. Prior row(s) now have t_valid_to=NOW().
```
This is informational only. The trigger is the authoritative dedup mechanism;
the `NOTICE` adds caller-visible observability.

### 2.3 `pgmnemo.recall_lessons(...)`

Default retrieval path. Hybrid dense+text with Fix-A RRF ranking (v0.6.0) and
optional point-in-time temporal scoping.

```sql
pgmnemo.recall_lessons(
    query_embedding   vector(1024),     -- pass NULL for text-only
    k                 INT          DEFAULT 10,
    role_filter       TEXT         DEFAULT NULL,
    project_id_filter INT          DEFAULT NULL,
    query_text        TEXT         DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ  DEFAULT NULL, -- v0.6.0: point-in-time scope
    exclude_dag_id    TEXT         DEFAULT NULL  -- v0.9.6: suppress lessons from this workflow run
) RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,
    role          TEXT,
    project_id    INT,
    topic         TEXT,
    lesson_text   TEXT,
    importance    SMALLINT,
    metadata      JSONB,
    commit_sha    TEXT,
    artifact_hash TEXT,
    verified_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ,
    -- v0.4.1+ diagnostic columns (appended; named-column callers unaffected):
    vec_score     DOUBLE PRECISION,   -- cosine similarity component (NULL on text-only path)
    bm25_score    DOUBLE PRECISION,   -- BM25 ts_rank_cd component (NULL on vector-only path)
    rrf_score     DOUBLE PRECISION    -- RRF score (NULL on vector-only path)
)
```

**Parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `query_embedding` | `vector(1024)` | — | Dense query vector. Pass `NULL` for text-only recall. |
| `k` | `INT` | `10` | Maximum results to return. |
| `role_filter` | `TEXT` | `NULL` | Restrict to lessons with this role. NULL = all roles. |
| `project_id_filter` | `INT` | `NULL` | Restrict to a tenant/project. NULL = all projects. |
| `query_text` | `TEXT` | `NULL` | Text for BM25 hybrid path. Requires `query_embedding` to activate hybrid routing. |
| `as_of_ts` | `TIMESTAMPTZ` | `NULL` | **(v0.6.0)** Point-in-time scope. When set, restricts candidates to lessons where `t_valid_from ≤ as_of_ts < t_valid_to`. NULL = current active lessons only. |
| `exclude_dag_id` | `TEXT` | `NULL` | **(v0.9.6)** When set, suppresses lessons whose `source_dag_id` matches this value (`IS DISTINCT FROM` semantics: rows with `source_dag_id IS NULL` always pass). Forwarded to `recall_hybrid()` on the hybrid path. |

**Scoring (hybrid path, Fix-A v0.6.0):**
```
score = (rrf_diag / norm_denom)       -- Fix-A: normalized RRF (Cormack 2009)
      + 0.05 × (importance / 5)
      + 0.05 × recency_decay(90 days, ref = as_of_ts or NOW())
      + 0.05 × provenance_strength
      + graph_weight × graph_proximity
```
`rrf_diag = vec_weight/(rrf_k+vec_rank) + bm25_weight/(rrf_k+bm25_rank)`.
`norm_denom = (vec_weight + bm25_weight)/(rrf_k + 1)` (normalizes to [0,1]).
`provenance_strength`: 1.0 (commit + verified), 0.4 (commit only), 0.0 (none).

**Scoring (vector-only path):**
```
score = 0.5 × cosine_similarity
      + 0.2 × (importance / 5)
      + γ   × recency_decay(90 days)   -- γ = pgmnemo.recency_weight × temporal_boost
      + 0.1 × provenance_strength
      + graph_weight × graph_proximity
```

By default, rows with `verified_at IS NULL` are excluded. Enable via
`SET pgmnemo.include_unverified = 'true'`.

**Connection pool safety (as_of_ts):** Sets `pgmnemo.as_of_timestamp` as a
transaction-local GUC (`set_config(..., TRUE)`). Cleared on `COMMIT`/`ROLLBACK`.
No session-state leaks.

### 2.4 `pgmnemo.recall_lessons_pooled(...)`

Session-pooled wrapper around `recall_lessons()`. Same signature, returns
session-aggregated top-K per `metadata->>'sid'`. Used by LoCoMo session-level
benchmark methodology.

### 2.5 `pgmnemo.recall_hybrid(...)` (v0.2.2+, default path since v0.4.0)

Vector + BM25 union recall with RRF fusion. Used by `recall_lessons()` when
`query_text` is provided. **Fix-A (v0.6.0):** primary ranking signal is now
normalized `rrf_diag` (Cormack 2009 RRF), replacing the previous linear
`fusion_score`. Temporal filter via `pgmnemo.as_of_timestamp` GUC.

```sql
pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT              DEFAULT 10,
    role_filter       TEXT             DEFAULT NULL,
    project_id_filter INT              DEFAULT NULL,
    vec_weight        DOUBLE PRECISION DEFAULT 0.4,
    bm25_weight       DOUBLE PRECISION DEFAULT 0.4,
    rrf_k             INT              DEFAULT 60,
    exclude_dag_id    TEXT             DEFAULT NULL   -- v0.9.6: suppress lessons from this workflow run
) RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,   -- Fix-A (v0.6.0): normalized rrf_diag + auxiliaries
    vec_score     DOUBLE PRECISION,   -- diagnostic: raw cosine similarity
    bm25_score    DOUBLE PRECISION,   -- diagnostic: ts_rank_cd component
    rrf_score     DOUBLE PRECISION,   -- rrf_diag = vec_w/(k+rank_v) + bm25_w/(k+rank_b)
    role          TEXT,
    project_id    INT,
    topic         TEXT,
    lesson_text   TEXT,
    importance    SMALLINT,
    metadata      JSONB,
    commit_sha    TEXT,
    artifact_hash TEXT,
    verified_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ
)
```

Sort by the `score` column. A signature smoke test lives at
`scripts/smoke_recall_hybrid.py` and runs in CI on every push.

**Fix-A formula (v0.6.0):**
```
norm_denom = (vec_weight + bm25_weight) / (rrf_k + 1)
rrf_diag   = vec_weight / (rrf_k + vec_rank) + bm25_weight / (rrf_k + bm25_rank)
score      = (rrf_diag / norm_denom)
           + 0.05 × (importance / 5)
           + 0.05 × recency_decay(90 days, ref = as_of_ts or NOW())
           + 0.05 × provenance_strength
           + graph_weight × graph_proximity
```

**Prior formula (pre-v0.6.0, for reference):**
```
score = vec_weight × cosine + bm25_weight × ts_rank_cd(lesson_tsv, q, 32)
```

Union retrieval: candidates matched by **either** cosine **or** BM25.
`rrf_score` column = raw `rrf_diag` value (unchanged from pre-v0.6.0 column).
`graph_proximity_weight` GUC (default `0.2`). Set to `0.0` for pure semantic recall.

### 2.6 `pgmnemo.traverse_causal_chain(...)` (v0.2.0+, direction added in v0.2.1)

BFS over causal edges.

```sql
pgmnemo.traverse_causal_chain(
    start_lesson_id BIGINT,
    max_depth       INT  DEFAULT 5,
    direction       TEXT DEFAULT 'forward'   -- 'forward'|'backward'|'both'
) RETURNS TABLE (
    lesson_id  BIGINT,
    depth      INT,
    path       BIGINT[],
    weight_sum DOUBLE PRECISION
)
```

Cycle guard via path array applies to all directions. Invalid `direction` raises
`EXCEPTION`. Filters via `relation_type` patterns (causal-family values).

### 2.7 `pgmnemo.traverse_temporal_window(...)` (v0.2.0+)

Co-temporal lesson retrieval.

```sql
pgmnemo.traverse_temporal_window(
    start_lesson_id BIGINT,
    window_interval INTERVAL DEFAULT '24 hours'
) RETURNS TABLE (
    lesson_id  BIGINT,
    distance_s DOUBLE PRECISION
)
```

### 2.8 `pgmnemo.stats()` (v0.4.1+, updated v0.6.0)

One-row diagnostic snapshot. Returns current GUC values, corpus size, embedding and
full-text index coverage, orphan-function count, and (v0.6.0) ghost lesson count.
Safe to call from monitoring loops; typically < 50 ms on a N = 10 k corpus.

```sql
pgmnemo.stats()
RETURNS TABLE (
    version                 TEXT,            -- installed extension version
    lesson_count            BIGINT,          -- total rows in agent_lesson
    embedded_count          BIGINT,          -- rows with embedding IS NOT NULL
    embedding_coverage_pct  DOUBLE PRECISION,-- embedded_count / lesson_count × 100
    tsv_coverage_pct        DOUBLE PRECISION,-- rows with lesson_tsv IS NOT NULL × 100
    mem_edge_count          BIGINT,          -- total rows in mem_edge
    recency_weight          DOUBLE PRECISION,-- current pgmnemo.recency_weight GUC
    ef_search               INT,             -- current pgmnemo.ef_search GUC
    importance_weight       DOUBLE PRECISION,-- current pgmnemo.importance_weight GUC
    hybrid_enabled          BOOLEAN,         -- NOT pgmnemo.disable_hybrid
    recall_hybrid_available BOOLEAN,         -- TRUE if recall_hybrid() is installed
    oldest_lesson_age_days  INT,             -- days since oldest created_at
    orphan_count            BIGINT,          -- functions not owned by the extension
    ghost_count             BIGINT           -- v0.6.0: active lessons with verified_at IS NULL
)
```

**`ghost_count` column (v0.6.0):** active lessons (`t_valid_to = 'infinity'`) where
`verified_at IS NULL` — i.e. no `commit_sha` and no `artifact_hash`. These are
lessons ingested with `pgmnemo.gate_strict = 'off'` or `'warn'` and represent
provenance debt.

**Recommended provenance target:** `ghost_count < 5% × lesson_count` before
enabling `pgmnemo.include_unverified = 'off'`. Use `ghost_count` to track
Phase 4 migration progress (RFC Q4).

**Typical usage:**

```sql
-- Quick health check:
SELECT * FROM pgmnemo.stats();

-- Check embedding backfill coverage:
SELECT embedding_coverage_pct FROM pgmnemo.stats();
-- 0.0 → no embeddings; recall falls back to full-text only.

-- Confirm GUC values active in this session:
SELECT recency_weight, ef_search, importance_weight, hybrid_enabled
FROM pgmnemo.stats();

-- Check for orphan functions (non-zero blocks ALTER EXTENSION UPDATE):
SELECT orphan_count FROM pgmnemo.stats();

-- v0.6.0: Check ghost lesson debt (RFC Q4):
SELECT ghost_count, lesson_count,
       ROUND(100.0 * ghost_count / NULLIF(lesson_count, 0), 1) AS ghost_pct
FROM pgmnemo.stats();
-- Target: ghost_pct < 5% before enabling include_unverified=off
```

**`orphan_count` column:** counts functions in the `pgmnemo` schema that PostgreSQL does
not recognise as part of the extension — typically caused by intermediate manual SQL
patches applied via `psql -f` outside the `ALTER EXTENSION UPDATE` mechanism. A non-zero
value will block future upgrades with:

```
ERROR: function pgmnemo.X(...) already exists but is not a member of extension "pgmnemo"
```

See [`docs/MIGRATION.md §B.5`](MIGRATION.md#b5-recovery-from-extension-orphan-objects-v041)
for the detection + recovery procedure.

---

### 2.9 `pgmnemo.mark_stale(...)` (v0.9.5+)

Usage-based corpus curation primitive. Identifies lessons that have not been
recalled within a configurable window and optionally deprecates them.

```sql
pgmnemo.mark_stale(
    p_unused_days         INT     DEFAULT 45,     -- stale if not recalled in this many days
    p_min_confidence_keep REAL    DEFAULT 0.6,    -- safeguard: keep confidence >= this
    p_keep_provenance     BOOLEAN DEFAULT TRUE,   -- safeguard: keep commit_sha / artifact_hash
    p_dry_run             BOOLEAN DEFAULT TRUE,   -- TRUE = preview only, no state change
    p_cap                 INT     DEFAULT 500     -- refuse to act if candidates > cap
)
RETURNS TABLE (
    lesson_id        BIGINT,
    role             TEXT,
    topic            TEXT,
    last_recalled_at TIMESTAMPTZ,
    confidence       REAL,
    would_deprecate  BOOLEAN        -- FALSE = safeguard protects this lesson
)
```

**Candidate rule:** a lesson is a candidate when:
- `last_recalled_at < NOW() - p_unused_days * INTERVAL '1 day'`, OR
- `last_recalled_at IS NULL AND created_at < NOW() - p_unused_days * INTERVAL '1 day'`

**Safeguards** — lessons matching any of these are returned but `would_deprecate = FALSE`
and are never touched even in non-dry-run mode:
- `confidence >= p_min_confidence_keep` (default 0.6)
- `importance = 5`
- `p_keep_provenance = TRUE` and `commit_sha IS NOT NULL` or `artifact_hash IS NOT NULL`

**Cap guard:** if `p_dry_run = FALSE` and candidate count exceeds `p_cap`, a `RAISE NOTICE`
is emitted, the full candidate list is returned, but **no lessons are deprecated**. The caller
must explicitly raise `p_cap` to proceed.

**Typical usage:**

```sql
-- Always preview first (default dry_run=TRUE):
SELECT * FROM pgmnemo.mark_stale() WHERE would_deprecate;

-- Review, then apply with explicit cap:
SELECT COUNT(*) FROM pgmnemo.mark_stale(p_dry_run=>FALSE, p_cap=>200)
WHERE would_deprecate;

-- Typical settings (45d unused, confidence < 0.6, provenance kept):
SELECT * FROM pgmnemo.mark_stale(
    p_unused_days         => 45,
    p_min_confidence_keep => 0.6,
    p_keep_provenance     => TRUE,
    p_dry_run             => TRUE
) WHERE would_deprecate;
```

> ⚠️ **Never run `p_dry_run=>FALSE` without reviewing the candidate set first.**
> The deprecation is a direct `UPDATE state = 'deprecated'` that bypasses the normal
> state-machine guard — it is intentional (mark_stale covers draft/candidate/validated/canonical
> equally) but irreversible without a manual `UPDATE`.

---

## 3. GUCs

> **Reading GUCs:** `SHOW pgmnemo.*` will fail because pgmnemo is a pure-SQL extension
> (cannot use `DefineCustomXxxVariable`). Use `current_setting('pgmnemo.X', TRUE)`.
> Full guide: [docs/INSTALL.md "Reading the GUCs"](INSTALL.md#reading-the-gucs-read-this-if-you-came-from-show).
> One-row inspection of current values: `SELECT * FROM pgmnemo.stats()` (v0.4.1+).

### 3.1 Recall scoring GUCs (used by `recall_lessons()`)

| GUC | Type | Default | Range | Description |
|---|---|---|---|---|
| `pgmnemo.recency_weight` | float | **`0.05`** (v0.4.1; was `0.08` in v0.2.1–v0.4.0, was `0.20` in v0.1.x) | 0.0 – 0.3 (rec.) | Coefficient on the recency-decay term (90-day half-life). Lower values reduce the bias toward recent lessons. An internal RFC ablation (N=1081, 0-365d age) found 0.05 near-optimal for long-lived corpora. |
| `pgmnemo.importance_weight` | float | **`0.15`** (v0.4.1 documented; was implicit `0.20` in pre-v0.4.1 formula) | 0.0 – 0.3 | Coefficient on `importance / 5` term in scoring. Documents the per-formula importance coefficient. |
| `pgmnemo.ef_search` | int | `100` (v0.2.1+) | 10 – 500 | Applied as `SET LOCAL pgvector.hnsw.ef_search` at recall entry. Higher = more accurate ANN at cost of latency. |
| `pgmnemo.disable_hybrid` | bool | `false` (v0.4.0+) | `true` / `false` | Opt out of hybrid routing. When `true`, `recall_lessons()` always uses vector-only path regardless of `query_text`. Use for adopters who need deterministic v0.3.x behaviour. |
| `pgmnemo.graph_proximity_weight` | float | `0.2` | 0.0 – 0.5 | Weight on `mem_edge` graph-walk proximity term in `recall_hybrid()` scoring. Set to `0.0` for pure semantic recall (the reference bench setup). |
| `pgmnemo.temporal_boost` | float | `1.0` (v0.5.0+) | 0.0 – 20.0 | Multiplier on the recency component. `effective_γ = recency_weight × temporal_boost`. Default `1.0` = unchanged behaviour from v0.4.1. H-06 optimal: `boost=10` with `recency_weight=0.05` → `effective_γ=0.5`. Helper: `SELECT pgmnemo.get_temporal_boost()`. |
| `pgmnemo.confidence_boost_weight` | float | **`0.0`** (v0.9.2+, off by default) | 0.0 – 0.01 | Additive confidence boost in `recall_hybrid()` final score: `score += w × (confidence − 0.5)`. Zero-centered: confidence=0.5 gets no boost. Off by default — byte-identical to v0.9.1 without `SET`. Activate with `SET pgmnemo.confidence_boost_weight = '0.003'`. Recommended range: 0.001 – 0.005. |
| `pgmnemo.track_recall_recency` | bool | **`on`** (v0.9.5+) | `on` / `off` | When `on`, every recall function (`recall_hybrid`, `recall_lessons`, `navigate_locate`, `navigate_expand`) stamps `last_recalled_at = NOW()` and increments `recall_count` on the returned lessons via a data-modifying CTE. Set to `off` to disable all stamping — functions are then byte-identical to v0.9.4. Default `on` (opt-out, not opt-in). |

### 3.2 Write/ingest GUCs (used by `pgmnemo.ingest()` and `recall_lessons()` filtering)

| GUC | Type | Default | Range | Description |
|---|---|---|---|---|
| `pgmnemo.gate_strict` | enum | `enforce` | `enforce` / `warn` / `off` | Provenance gate behaviour in `ingest()`. `enforce` blocks; `warn` logs and proceeds; `off` skips. |
| `pgmnemo.include_unverified` | bool | `false` | `true` / `false` | Include ghost lessons (`verified_at IS NULL`) in `recall_lessons()` output. |
| `pgmnemo.max_query_text_chars` | int | `2000` (v0.5.0+) | 0 – any | Maximum length of `query_text` in `recall_lessons()` and `lesson_text` in `ingest()`. Input exceeding the cap is silently truncated with a `RAISE NOTICE`. Set to `0` to disable the cap entirely. |

### 3.3 Outcome-learning GUCs (used by `reinforce()`, v0.9.3+)

| GUC | Type | Default | Range | Description |
|---|---|---|---|---|
| `pgmnemo.reinforce_success_delta` | float | **`0.02`** (v0.9.3+; was `0.10` in v0.7.0–v0.9.2) | 0.001 – 0.5 | Confidence increment on `'success'` outcome. Applied as `confidence += delta` (clamped to 1.0). Base-rate-adjusted default: slow upward drift, one success is not sufficient evidence. |
| `pgmnemo.reinforce_fail_delta` | float | **`0.12`** (v0.9.3+; was `0.15` in v0.7.0–v0.9.2) | 0.001 – 0.5 | Confidence decrement on `'failure'` outcome. Applied as `confidence -= delta` (clamped to 0.0). Asymmetric by design: failures are penalised faster than successes are rewarded. |

Override per-session or at DB/role level:

```sql
SET pgmnemo.reinforce_success_delta = '0.05';  -- more aggressive success reward
SET pgmnemo.reinforce_fail_delta    = '0.08';  -- lighter failure penalty
```

### 3.4 Multi-tenant scoping (v0.2.1+)

| GUC | Type | Default | Description |
|---|---|---|---|
| `pgmnemo.tenant_id` | text | `''` (empty = service-account bypass; all rows visible) | RLS scoping key. Non-empty restricts `agent_lesson` to rows where `project_id::text = current_setting('pgmnemo.tenant_id')`. |

### 3.5 Override patterns

```sql
-- Session-scope (this connection only):
SET pgmnemo.recency_weight = '0.05';

-- System-scope (persistent until next ALTER SYSTEM; requires superuser):
ALTER SYSTEM SET pgmnemo.recency_weight = '0.05';
SELECT pg_reload_conf();

-- Verify what's currently active (works without registration):
SELECT * FROM pgmnemo.stats();  -- v0.4.1+
-- Or individually:
SELECT current_setting('pgmnemo.recency_weight', TRUE);
-- (TRUE = return NULL on missing instead of error; falls back to function default)

-- Verify what's persisted in postgresql.auto.conf:
SELECT name, setting, sourcefile FROM pg_file_settings WHERE name LIKE 'pgmnemo.%';
```

### 3.6 Default-change history (operator notes)

| Version | GUC | Old → New | Reason |
|---|---|---|---|
| v0.2.1 | `pgmnemo.recency_weight` | `0.20` → `0.08` | Pending REC-1 ablation (never completed our side) |
| v0.4.1 | `pgmnemo.recency_weight` | `0.08` → `0.05` | Internal RFC ablation (N=1081 production corpus); see RFC §R1 |
| v0.2.1 | `pgmnemo.ef_search` | (new GUC, default 100) | HNSW recall quality at production query rate |
| v0.4.0 | `pgmnemo.disable_hybrid` | (new GUC, default FALSE) | Hybrid retrieval became default; this is the opt-out switch |
| v0.5.0 | `pgmnemo.temporal_boost` | (new GUC, default 1.0) | H-06: tunable recency multiplier; default 1.0 = no change from v0.4.1 behaviour |
| v0.5.0 | `pgmnemo.max_query_text_chars` | (new GUC, default 2000) | R5: input-length guard for ingest() and recall query_text; 0 = disabled |
| v0.9.2 | `pgmnemo.confidence_boost_weight` | (new GUC, default 0.0 = off) | I1: opt-in confidence-weighted ranking; off by default, byte-identical to v0.9.1 without SET |
| v0.9.3 | `pgmnemo.reinforce_success_delta` | `0.10` → `0.02` | D1: base-rate-adjusted default; old value caused confidence saturation at ceiling |
| v0.9.5 | `pgmnemo.track_recall_recency` | (new GUC, default `on`) | E: recall-recency stamping; opt-out (`off`) for byte-identical behaviour to v0.9.4 |
| v0.9.3 | `pgmnemo.reinforce_fail_delta` | `0.15` → `0.12` | D1: base-rate-adjusted default; asymmetric: failures penalised faster than successes rewarded |

Adopters who set GUCs via `ALTER SYSTEM` keep their values across version upgrades.
Only the **function default fallback** changes when we ship a new default. To
explicitly use the previous default after upgrade: `SET pgmnemo.recency_weight = '0.08'`.

---

## 4. Row-Level Security (v0.2.1+)

RLS is enabled on `agent_lesson` (by `project_id`) and `mem_edge` (by endpoint
ownership). The policies are gated by `pgmnemo.tenant_id`:

- **Empty / unset** → service-account bypass (all rows visible)
- **Non-empty** → only rows where `project_id::text = current_setting('pgmnemo.tenant_id')`

Policies use `DROP IF EXISTS` then `CREATE`; safe to re-apply.

---

## 5. Deprecation log

| Version | Change | Action required |
|---|---|---|
| v0.2.0.1 / v0.2.1 | `recall_lessons()` params renamed: `role`→`role_filter`, `project_id`→`project_id_filter` (resolved `RETURNS TABLE` collision) | Named-argument callers must use new names |
| v0.5.0 | 4-argument `traverse_causal_chain(start, max_depth, role, project)` **removed** (deprecated since v0.4.1 with `RAISE NOTICE`) | Use 2-arg form + `WHERE` clause (see MIGRATION.md §0.4.1→0.5.0) |
| v0.5.0 | `mem_edge.lesson_a_id` / `lesson_b_id` **renamed** to `source_id` / `target_id` | Use `pgmnemo.add_edge()` (§1.2) to avoid direct column references; or update INSERT statements |

For all changes per release see `CHANGELOG.md`.
