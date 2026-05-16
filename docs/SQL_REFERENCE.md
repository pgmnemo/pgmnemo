# pgmnemo SQL Reference

**Version coverage:** v0.3.0 (current default)  
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

Indexes: HNSW on `embedding` (cosine_ops), B-tree on `(role, project_id)`,
GIN on `lesson_tsv` (v0.2.2+), GIN on `metadata`.

#### `pgmnemo.mem_edge`

| Column | Type | Notes |
|---|---|---|
| `id` | BIGSERIAL PRIMARY KEY | |
| `lesson_a_id` | BIGINT REFERENCES `agent_lesson(lesson_id)` ON DELETE CASCADE | source endpoint |
| `lesson_b_id` | BIGINT REFERENCES `agent_lesson(lesson_id)` ON DELETE CASCADE | target endpoint |
| `relation_type` | TEXT | freeform annotation (e.g. `CAUSED_BY`, `CO_OCCURRED`) |
| `edge_kind` | `pgmnemo.edge_kind` ENUM NOT NULL | v0.3.0+: `{semantic, temporal, causal, entity}` |
| `weight` | DOUBLE PRECISION DEFAULT 1.0 | edge strength 0–1 |
| `metadata` | JSONB DEFAULT '{}' | |
| `created_at` | TIMESTAMPTZ DEFAULT NOW() | |

Indexes: per-kind partial B-tree on `(lesson_a_id, lesson_b_id) WHERE edge_kind = '<value>'`.

##### Population contract (canonical, since v0.4.0)

Adopters streaming edges from their orchestration layer should follow this contract.
`pgmnemo.add_edge()` helper SP shipping in v0.5.0 will encapsulate it; until then,
write the `INSERT ... ON CONFLICT` pattern directly.

**Semantics:**

| Column | Convention |
|---|---|
| `lesson_a_id` | The **earlier** lesson in the causal chain (or the anchor of the relation) |
| `lesson_b_id` | The **later** lesson, or the satellite |
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
    (lesson_a_id, lesson_b_id, relation_type, edge_kind, weight, metadata)
VALUES
    ($1, $2, $3, $4, $5, $6)
ON CONFLICT (lesson_a_id, lesson_b_id, relation_type)
DO UPDATE SET
    weight   = EXCLUDED.weight,
    metadata = pgmnemo.mem_edge.metadata || EXCLUDED.metadata;
```

Note: the unique constraint `(lesson_a_id, lesson_b_id, relation_type)` is the
de-dup key. Edges with different `relation_type` between the same pair of lessons
are intentionally allowed (e.g. `A CAUSED_BY B` and `A CO_OCCURRED B` may both be
true).

**Update policy options** (pick one and document in your application):

- `mode='replace'` — `SET weight = EXCLUDED.weight` (last-writer-wins; default in the SQL above)
- `mode='max'` — `SET weight = GREATEST(mem_edge.weight, EXCLUDED.weight)` (monotonic non-decreasing)
- `mode='avg'` — `SET weight = (mem_edge.weight + EXCLUDED.weight) / 2.0` (running average; requires care with race conditions)

When `pgmnemo.add_edge(...)` ships in v0.5.0 (per
[issue #23](https://github.com/pgmnemo/pgmnemo/issues/23)), it will accept a
`mode TEXT DEFAULT 'replace'` parameter encapsulating these patterns.

### 1.2 ENUM types

```sql
CREATE TYPE pgmnemo.edge_kind AS ENUM ('semantic', 'temporal', 'causal', 'entity');
```

---

## 2. Public functions

### 2.1 `pgmnemo.version()`

```sql
pgmnemo.version() RETURNS TEXT
```

Returns the installed extension version (e.g. `'0.3.0'`).

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

### 2.3 `pgmnemo.recall_lessons(...)`

Default retrieval path. Hybrid dense+text with paper §6.4 scoring.

```sql
pgmnemo.recall_lessons(
    query_embedding   vector(1024),     -- pass NULL for text-only
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    query_text        TEXT    DEFAULT NULL
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
    created_at    TIMESTAMPTZ
)
```

**Scoring formula (paper §6.4, locked):**
```
score = 0.5 × cosine_similarity
      + 0.2 × (importance / 5)
      + 0.2 × recency_decay(half-life = pgmnemo.recency_weight × 90 days)
      + 0.1 × provenance_strength
```
`provenance_strength`: 1.0 (commit + verified), 0.5 (commit only), 0.0 (none).

By default, rows with `verified_at IS NULL` are excluded. Enable via
`SET pgmnemo.include_unverified = 'true'`.

### 2.4 `pgmnemo.recall_lessons_pooled(...)`

Session-pooled wrapper around `recall_lessons()`. Same signature, returns
session-aggregated top-K per `metadata->>'sid'`. Used by LoCoMo session-level
benchmark methodology.

### 2.5 `pgmnemo.recall_hybrid(...)` — EXPERIMENTAL (v0.2.2+)

Vector + BM25 weighted fusion. Opt-in only; not default.

```sql
pgmnemo.recall_hybrid(
    query_embedding   vector(1024),
    query_text        TEXT,
    k                 INT     DEFAULT 10,
    role_filter       TEXT    DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL,
    vec_weight        FLOAT   DEFAULT 0.4,
    bm25_weight       FLOAT   DEFAULT 0.4,
    rrf_k             INT     DEFAULT 60
) RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,   -- weighted hybrid combination (sort key)
    vec_score     DOUBLE PRECISION,   -- diagnostic: cosine similarity component
    bm25_score    DOUBLE PRECISION,   -- diagnostic: ts_rank_cd component
    rrf_score     DOUBLE PRECISION,   -- diagnostic: 1/(rrf_k+vec_rank) + 1/(rrf_k+bm25_rank)
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

Sort by the `score` column (NOT `hybrid_score` — that name appears in some
draft docs and is a documented error; the actual output column is `score`).
A signature smoke test lives at `scripts/smoke_recall_hybrid.py` and runs in
CI on every push (job `smoke-recall-hybrid` in `.github/workflows/ci.yml`).

Formula: `score = vec_weight × cosine + bm25_weight × ts_rank_cd(lesson_tsv, q, 32)`
plus minor importance/recency/provenance components matching the
`recall_lessons()` §6.4 formula. Union retrieval: candidates matched by
**either** cosine **or** BM25.

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

---

## 3. GUCs

> **Reading GUCs:** `SHOW pgmnemo.*` will fail because pgmnemo is a pure-SQL extension
> (cannot use `DefineCustomXxxVariable`). Use `current_setting('pgmnemo.X', TRUE)`.
> Full guide: [docs/INSTALL.md "Reading the GUCs"](INSTALL.md#reading-the-gucs-read-this-if-you-came-from-show).
> One-row inspection of current values: `SELECT * FROM pgmnemo.stats()` (v0.4.1+).

### 3.1 Recall scoring GUCs (used by `recall_lessons()`)

| GUC | Type | Default | Range | Description |
|---|---|---|---|---|
| `pgmnemo.recency_weight` | float | **`0.05`** (v0.4.1; was `0.08` in v0.2.1–v0.4.0, was `0.20` in v0.1.x) | 0.0 – 0.3 (rec.) | Coefficient on the recency-decay term (90-day half-life). Lower values reduce the bias toward recent lessons. Agency RFC ablation (N=1081, 0-365d age) found 0.05 near-optimal for long-lived corpora. |
| `pgmnemo.importance_weight` | float | **`0.15`** (v0.4.1 documented; was implicit `0.20` in pre-v0.4.1 formula) | 0.0 – 0.3 | Coefficient on `importance / 5` term in scoring. Documents the per-formula importance coefficient. |
| `pgmnemo.ef_search` | int | `100` (v0.2.1+) | 10 – 500 | Applied as `SET LOCAL pgvector.hnsw.ef_search` at recall entry. Higher = more accurate ANN at cost of latency. |
| `pgmnemo.disable_hybrid` | bool | `false` (v0.4.0+) | `true` / `false` | Opt out of hybrid routing. When `true`, `recall_lessons()` always uses vector-only path regardless of `query_text`. Use for adopters who need deterministic v0.3.x behaviour. |
| `pgmnemo.graph_proximity_weight` | float | `0.2` | 0.0 – 0.5 | Weight on `mem_edge` graph-walk proximity term in `recall_hybrid()` scoring. Set to `0.0` for pure semantic recall (Agency's bench setup). |

### 3.2 Write/ingest GUCs (used by `pgmnemo.ingest()` and `recall_lessons()` filtering)

| GUC | Type | Default | Range | Description |
|---|---|---|---|---|
| `pgmnemo.gate_strict` | enum | `enforce` | `enforce` / `warn` / `off` | Provenance gate behaviour in `ingest()`. `enforce` blocks; `warn` logs and proceeds; `off` skips. |
| `pgmnemo.include_unverified` | bool | `false` | `true` / `false` | Include ghost lessons (`verified_at IS NULL`) in `recall_lessons()` output. |

### 3.3 Multi-tenant scoping (v0.2.1+)

| GUC | Type | Default | Description |
|---|---|---|---|
| `pgmnemo.tenant_id` | text | `''` (empty = service-account bypass; all rows visible) | RLS scoping key. Non-empty restricts `agent_lesson` to rows where `project_id::text = current_setting('pgmnemo.tenant_id')`. |

### 3.4 Override patterns

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

### 3.5 Default-change history (operator notes)

| Version | GUC | Old → New | Reason |
|---|---|---|---|
| v0.2.1 | `pgmnemo.recency_weight` | `0.20` → `0.08` | Pending REC-1 ablation (never completed our side) |
| v0.4.1 | `pgmnemo.recency_weight` | `0.08` → `0.05` | Agency RFC ablation (N=1081 production corpus); see RFC §R1 |
| v0.2.1 | `pgmnemo.ef_search` | (new GUC, default 100) | HNSW recall quality at production query rate |
| v0.4.0 | `pgmnemo.disable_hybrid` | (new GUC, default FALSE) | Hybrid retrieval became default; this is the opt-out switch |

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

No public function signature has been removed since v0.1.0. Parameter renames
(role → role_filter, project_id → project_id_filter) were applied in
v0.2.0.1 / v0.2.1 to resolve `RETURNS TABLE` collisions; named-argument callers
must use the new names.

For all changes per release see `CHANGELOG.md`.
