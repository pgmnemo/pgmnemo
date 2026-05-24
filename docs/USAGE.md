# pgmnemo Usage Guide

## Writing lessons — `pgmnemo.ingest()`

`pgmnemo.ingest()` is the validated write path. Use it instead of raw `INSERT` to get:

- embedding dimension validation (1024 required)
- automatic `verified_at` stamp when provenance fields are present
- provenance gate enforcement (controlled by `pgmnemo.gate_strict`)

### Signature

```sql
pgmnemo.ingest(
    p_role          TEXT,
    p_project_id    INT,
    p_topic         TEXT,
    p_lesson_text   TEXT,
    p_importance    SMALLINT  DEFAULT 3,       -- 1 (low) to 5 (critical)
    p_embedding     vector(1024) DEFAULT NULL,
    p_commit_sha    TEXT      DEFAULT NULL,
    p_artifact_hash TEXT      DEFAULT NULL,
    p_metadata      JSONB     DEFAULT '{}'
) RETURNS BIGINT  -- new lesson id
```

### Examples

```sql
-- Minimal: text-only lesson with provenance via commit SHA
SELECT pgmnemo.ingest(
    'developer', 1, 'security',
    'Rotate JWT secrets within 24 hours of any key-compromise indicator.',
    4,
    NULL,       -- no embedding; text-only recall still works
    'a3f9b12'   -- commit SHA from the agent run that produced this lesson
);

-- Full: with embedding + artifact hash (e.g. signed test report)
SELECT pgmnemo.ingest(
    p_role          := 'qa-agent',
    p_project_id    := 7,
    p_topic         := 'flaky-tests',
    p_lesson_text   := 'Test suite_login is flaky under high concurrency; add retry=3.',
    p_importance    := 3,
    p_embedding     := <your_vector_1024>,
    p_artifact_hash := 'sha256:e3b0c44298fc1c149afb...',
    p_metadata      := '{"model": "claude-sonnet-4-6", "run_id": "r-42"}'
);
```

**Provenance gate behaviour** (set by `pgmnemo.gate_strict`):

- `enforce` (default) — call fails if both `p_commit_sha` and `p_artifact_hash` are NULL
- `warn` — call succeeds; client receives a `WARNING`; `verified_at` remains NULL
- `off` — no check; use only for development

```sql
-- Temporarily relax for bulk backfill:
SET pgmnemo.gate_strict = 'warn';
```

---

## Reading lessons — `pgmnemo.recall_lessons()`

### Signature

```sql
pgmnemo.recall_lessons(
    query_embedding   vector(1024),  -- pass NULL for text-only recall
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
    created_at    TIMESTAMPTZ,
    -- v0.4.1+ diagnostic columns (appended; named-column callers unaffected):
    vec_score     DOUBLE PRECISION,   -- cosine component (NULL on text-only path)
    bm25_score    DOUBLE PRECISION,   -- BM25 component (NULL on vector-only path)
    rrf_score     DOUBLE PRECISION    -- RRF score (NULL on vector-only path)
)
```

### Scoring formula (paper §6.4, locked)

```
score = 0.5 × cosine_similarity
      + 0.2 × (importance / 5)
      + 0.2 × recency_decay(90 days)
      + 0.1 × provenance_strength
```

Where `provenance_strength` = 1.0 (commit + verified), 0.5 (commit only), 0.0 (none).

By default, rows with `verified_at IS NULL` (ghost lessons) are excluded. Enable with:

```sql
SET pgmnemo.include_unverified = 'true';
```

#### `pgmnemo.include_unverified` — read filter, not INSERT gate

`pgmnemo.include_unverified` controls whether ghost lessons (`verified_at IS NULL`) appear in recall
results. Setting it to `on` makes ghost lessons eligible candidates in vector search and BM25
matching. However, their score is lower: `provenance_strength = 0.0` contributes nothing to the
0.1× provenance component in the scoring formula, so verified lessons rank above ghost lessons of
equal semantic similarity.

**This GUC does not disable the INSERT-time provenance gate.** The INSERT gate — which rejects or
warns when both `commit_sha` and `artifact_hash` are NULL — is controlled separately by
`pgmnemo.gate_strict` (`enforce` / `warn` / `off`). These two GUCs operate on different lifecycle
events: `gate_strict` fires on write; `include_unverified` applies on read. You can insert ghost
lessons via `gate_strict='warn'` and still exclude them from recall (default), or include them
selectively for diagnostics and bulk-import workflows.

```sql
-- Include ghost lessons in this session's recall queries (debugging / bulk import)
SET pgmnemo.include_unverified = 'on';
SELECT topic, lesson_text, score, verified_at
FROM pgmnemo.recall_lessons(<embedding>, 10);
-- Ghost lessons appear with lower scores than verified rows

-- Restore default for production queries
SET pgmnemo.include_unverified = 'off';
```

### Examples

```sql
-- Semantic recall with role filter
SELECT topic, lesson_text, score
FROM pgmnemo.recall_lessons(
    <your_vector_1024>,
    10,
    'developer'    -- role filter; NULL = all roles
);

-- Text-only recall (no embedding)
SELECT topic, lesson_text, score
FROM pgmnemo.recall_lessons(
    NULL::vector(1024),
    5,
    NULL,          -- all roles
    42,            -- project_id filter
    'JWT rotation' -- full-text query
);

-- Hybrid: embedding + text + project scope
SELECT topic, lesson_text, score
FROM pgmnemo.recall_lessons(
    <your_vector_1024>,
    20,
    'security-agent',
    42,
    'key rotation best practices'
);
```

---

## Edge taxonomy — `edge_kind` ENUM (v0.3.0)

v0.3.0 introduces a typed edge taxonomy as part of MAGMA §3. Each `mem_edge` row now carries
a mandatory `edge_kind` column drawn from the ENUM `pgmnemo.edge_kind`.

### `edge_kind` values

| Value | Meaning |
|-------|---------|
| `semantic` | Conceptually related lessons (shared topic or entity) |
| `temporal` | Lessons from overlapping or adjacent time windows |
| `causal` | Lesson A is a cause or precondition for lesson B |
| `entity` | Lessons share a named entity (agent, project, artifact) |

### Migration note (upgrading from v0.2.1)

The v0.2.1→v0.3.0 migration (`pgmnemo--0.2.1--0.3.0.sql`) backfills `edge_kind` from the
existing `relation_type` TEXT column using the mapping:

```
CAUSED_BY / caused_by / causal / derives_from / DERIVED_FROM / contradicts  → causal
CO_OCCURRED / co_occurred / temporal                                          → temporal
DERIVED_FROM / derived_from                                                   → semantic (fallback)
(all others)                                                                  → semantic
```

After migration, `edge_kind` is `NOT NULL` on all rows. The original `relation_type` column
is preserved as a freeform annotation column.

### Per-kind partial indexes

Four partial B-tree indexes are created automatically:

```sql
pgmnemo_mem_edge_semantic_idx   ON mem_edge (source_id, target_id)  WHERE edge_kind = 'semantic'
pgmnemo_mem_edge_temporal_idx   ON mem_edge (source_id, target_id)  WHERE edge_kind = 'temporal'
pgmnemo_mem_edge_causal_idx     ON mem_edge (source_id, target_id)  WHERE edge_kind = 'causal'
pgmnemo_mem_edge_entity_idx     ON mem_edge (source_id, target_id)  WHERE edge_kind = 'entity'
```

Queries that filter by `edge_kind` (e.g. causal-chain traversal) benefit from index-only scans.

### BFS fix in `recall_lessons()`

v0.3.0 fixes a bug where the BFS step inside `recall_lessons()` referenced the deprecated
`edge_type` column. The BFS now correctly uses `edge_kind` for graph traversal. This change
is transparent — the `recall_lessons()` signature is unchanged.

### Writing edges

**Preferred: `pgmnemo.add_edge()` helper (v0.5.0)**

`add_edge()` is idempotent, handles the `ON CONFLICT` upsert, and auto-derives `edge_kind`
from `relation_type` — no need to know the ENUM value:

```sql
-- Minimal (mode='replace' by default)
SELECT pgmnemo.add_edge(1001, 1002, 'CAUSED_BY');

-- With weight and metadata
SELECT pgmnemo.add_edge(1001, 1002, 'CAUSED_BY', 0.85, '{"run_id": 7320}');

-- Full control: running-max weight on conflict
SELECT pgmnemo.add_edge(1001, 1002, 'CAUSED_BY', 0.85, '{"run_id": 7320}', 'max');
```

**Direct INSERT** (if you need to bypass the helper or bulk-load):

```sql
-- Add a causal edge between two lessons (v0.5.0 column names)
INSERT INTO pgmnemo.mem_edge (source_id, target_id, edge_kind, relation_type)
VALUES (1001, 1002, 'causal', 'CAUSED_BY');

-- Add a temporal co-occurrence edge
INSERT INTO pgmnemo.mem_edge (source_id, target_id, edge_kind, relation_type)
VALUES (1003, 1004, 'temporal', 'CO_OCCURRED');
```

> **v0.5.0 breaking change:** columns were renamed `lesson_a_id` / `lesson_b_id` →
> `source_id` / `target_id`. See `docs/MIGRATION.md §0.4.1→0.5.0`.

---

## Hybrid retrieval — `pgmnemo.recall_hybrid()` ⚠ EXPERIMENTAL

> **EXPERIMENTAL — opt-in only.** `recall_hybrid()` is NOT the default retrieval path.
> Call it directly when you need it. `recall_lessons()` is unchanged.
>
> Bench status (2026-05-10, simulation): LoCoMo recall@10 +12.7pp vs vector-only (all
> question types positive, statistically significant). LongMemEval MRR +5.8pp (p=0.005,
> significant); recall@10 +1.5pp (p=0.308, not significant). Numbers are simulation
> (TF-IDF proxy for dense retrieval); real-DB confirmation pending.

Combines dense cosine retrieval with BM25-class sparse matching. Best suited for tasks
where the correct memory is lower in the top-K ranking (MRR improvement) or where
keyword-match queries appear alongside semantic queries (LoCoMo-style mixed corpus).

### Signature

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

> **Note:** The sort column is `score`, not `hybrid_score`. The name `hybrid_score`
> appeared in pre-release drafts and is incorrect — sort by `score`.

Formula: `hybrid_score = vec_weight×cosine + bm25_weight×ts_rank_cd(lesson_tsv, q, 32)`  
Union retrieval: candidates matched by **either** embedding cosine **or** BM25.

### Example

```sql
-- Opt-in: call recall_hybrid() directly
SELECT topic, lesson_text, score, vec_score, bm25_score, rrf_score
FROM pgmnemo.recall_hybrid(
    <your_vector_1024>,
    'JWT rotation key compromise',
    10,
    'security-agent',  -- role filter
    42                 -- project_id filter
);
```

### When to use

- Task requires ranking the correct result higher in top-K (MRR-sensitive)
- Your memory corpus has both keyword-matchable and semantic queries (LoCoMo profile)
- You have confirmed the recall@10 signal on your own data before relying on it

### When does hybrid mode activate?

Hybrid routing in `recall_lessons()` fires **per-query** when all three conditions hold:

1. `pgmnemo.disable_hybrid` is `off` (default) — the opt-out GUC is not set
2. The `query_text` argument passed to `recall_lessons()` is non-NULL and non-empty
3. The `query_embedding` argument is non-NULL

**There is no corpus-size threshold.** Hybrid does not auto-enable or auto-disable based on how
many rows have `lesson_tsv` populated. If rows have `lesson_tsv IS NULL`, they score 0 on BM25
and may not appear in BM25 candidates — but this does not flip hybrid mode off.

Use this probe to check hybrid-readiness of your corpus:

```sql
SELECT
    COUNT(*)                                                  AS total_lessons,
    COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL)            AS bm25_ready,
    COUNT(*) FILTER (WHERE embedding  IS NOT NULL)            AS vec_ready,
    COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL
                       AND embedding  IS NOT NULL)            AS hybrid_ready,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL)
        / NULLIF(COUNT(*), 0), 1
    )                                                         AS bm25_coverage_pct,
    NOT COALESCE(
        current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
        FALSE
    )                                                         AS hybrid_enabled_guc
FROM pgmnemo.agent_lesson
WHERE is_active;
```

If `bm25_coverage_pct` is low, run a backfill to populate `lesson_tsv` for existing rows:

```sql
UPDATE pgmnemo.agent_lesson
SET lesson_tsv = to_tsvector('english', lesson_text)
WHERE lesson_tsv IS NULL AND lesson_text IS NOT NULL;
```

### psycopg2 calling convention

Named argument syntax (`=>`, PostgreSQL 14+) is the recommended style for production Python code.
It is order-independent, allows omitting optional parameters, and is self-documenting.

```python
import os
import psycopg2

def format_vector(arr) -> str:
    """Convert a list or numpy array to pgvector literal."""
    return "[" + ",".join(f"{v:.6f}" for v in arr) + "]"

conn = psycopg2.connect(os.environ["DATABASE_URL"])
cur = conn.cursor()

embedding_str = format_vector(your_embedding_array)  # list or np.ndarray, length 1024

# Named argument style — recommended for production (omit optional params freely)
cur.execute(
    """SELECT lesson_id, score, role, topic, lesson_text
       FROM pgmnemo.recall_lessons(
           query_embedding => %s::vector,
           query_text      => %s,
           k               => %s,
           role_filter     => %s
       )
       ORDER BY score DESC""",
    (embedding_str, "JWT rotation policy", 10, "developer")
)
rows = cur.fetchall()

# Positional style — acceptable for scripts and tests
cur.execute(
    "SELECT * FROM pgmnemo.recall_lessons(%s::vector, %s, %s, %s, %s) ORDER BY score DESC",
    (embedding_str, 10, "developer", None, "JWT rotation policy")
)
```

> **Note:** psycopg2 has no native `vector` type. Always pass embeddings as Python strings with
> an explicit `::vector` cast in the SQL. Format: `"[" + ",".join(f"{v:.6f}" for v in arr) + "]"`.
> For point-in-time recall pass `as_of_ts => %s::timestamptz` (v0.6.1+).

### Install

```sql
-- Run once after upgrading to v0.2.2:
\i extension/pgmnemo--0.2.1--0.2.2-hybrid.sql
```

---

## Tuning

> **All pgmnemo GUCs** with current defaults are in
> [`docs/SQL_REFERENCE.md §3`](SQL_REFERENCE.md#3-gucs). The most commonly tuned
> ones are summarised below. `SELECT * FROM pgmnemo.stats()` (v0.4.1+) shows
> what's currently active.

### HNSW ef_search — via the pgmnemo GUC

pgmnemo wraps pgvector's HNSW `ef_search` parameter so you don't need to know
pgvector internals. Set the pgmnemo-namespaced GUC; recall_lessons() applies
`SET LOCAL pgvector.hnsw.ef_search` internally for the duration of the call.

```sql
-- Default 100 (v0.2.1+; was 40 in upstream pgvector). Per-session:
SET pgmnemo.ef_search = '200';

-- Or persistent (requires superuser):
ALTER SYSTEM SET pgmnemo.ef_search = '200';
SELECT pg_reload_conf();
```

Rule of thumb: start at 100 (v0.2.1+ default), raise to 200–400 when recall
accuracy matters more than p99 latency. Below 40 = sharp recall degradation.

### Recency-weight tuning

```sql
-- Default 0.05 in v0.4.1 (was 0.08 in v0.2.1-v0.4.0).
-- Lower → less bias toward recent lessons (good for long-lived corpora).
-- Higher → more bias toward recent (good for ephemeral / fast-moving corpora).
SET pgmnemo.recency_weight = '0.10';
```

Agency RFC (Production corpus N=1081, age 0–365 days) found 0.05 near-optimal.
If your corpus is shorter-lived (e.g. 30-day rolling window) you may want 0.10–0.15.

### HNSW index parameters

The index is built with `m=16, ef_construction=64` (extension defaults). To rebuild with
higher-quality construction (slower build, better recall at low ef_search):

```sql
-- Requires pgvector 0.7+
REINDEX INDEX pgmnemo.pgmnemo_agent_lesson_embedding_idx;
-- Or drop/recreate with custom params:
DROP INDEX pgmnemo.pgmnemo_agent_lesson_embedding_idx;
CREATE INDEX pgmnemo_agent_lesson_embedding_idx
  ON pgmnemo.agent_lesson
  USING hnsw (embedding vector_cosine_ops)
  WITH (m=32, ef_construction=128)
  WHERE is_active AND embedding IS NOT NULL;
```

### Scoring weight overrides

The §6.4 formula weights are hardcoded in v0.1.0. Custom scoring is supported by calling
`recall_lessons()` and applying your own reranker in application code, or by wrapping the
returned columns in a custom SQL query.

### Limiting ghost lessons

Keep `pgmnemo.gate_strict = 'enforce'` (default) in production. Ghost lessons (unverified
rows) dilute recall quality because they score 0 on the provenance component and may contain
hallucinated observations.

---

## Temporal Ranking Calibration

> **Applies to:** v0.5.0+ (`pgmnemo.temporal_boost` GUC). If `temporal_boost` is absent
> from `pgmnemo.stats()` output, you are on v0.4.x and this section does not apply.

### Decay formula

`recall_lessons()` applies an exponential time-decay multiplier to each candidate's base score:

```
adjusted_score = base_score × exp(−temporal_boost × days_since_created)
```

where `days_since_created = EXTRACT(EPOCH FROM (NOW() − created_at)) / 86400.0`.

`temporal_boost = 0` disables decay entirely (scores are unmodified). The GUC is a
non-negative float; there is no upper bound, but values above `0.5` make lessons older
than a week nearly invisible.

### Half-life relationship

Half-life is the age at which a lesson's temporal multiplier reaches 0.5 (i.e. the lesson
contributes half its base score):

```
half_life_days = ln(2) / temporal_boost  ≈  0.693 / temporal_boost
```

### Calibration table

| `temporal_boost` | Half-life | Score at 7 d | Score at 30 d | Score at 365 d | Typical use case |
|-----------------|-----------|-------------|--------------|----------------|-----------------|
| `0` (disabled)  | ∞         | 1.000       | 1.000        | 1.000          | Disable decay; treat all lessons equally regardless of age |
| `0.001`         | ~693 days | 0.993       | 0.970        | 0.695          | Historical archive — decade-scale institutional knowledge |
| `0.005`         | ~139 days | 0.966       | 0.861        | 0.160          | Long-lived corpus; lessons valid for months |
| `0.01`          | ~70 days  | 0.933       | 0.741        | 0.026          | **Balanced** — general-purpose agent (recommended default) |
| `0.05`          | ~14 days  | 0.705       | 0.223        | ~0.000         | Fast-moving domain; week-scale relevance window |
| `0.1`           | ~7 days   | 0.497       | 0.050        | ~0.000         | Fresh-knowledge agent — today's context dominates |

Score values are the multiplier `exp(−boost × age_days)` applied to base score, rounded to 3 d.p.

### Recommended presets

#### Fresh knowledge agent
Ideal for agents that consume rapidly-changing information (news, incident response, live deployments).
Lessons older than a week carry less than half their original weight.

```sql
SET pgmnemo.temporal_boost = '0.1';   -- half-life ≈ 7 days
-- Or persist:
ALTER SYSTEM SET pgmnemo.temporal_boost = '0.1';
SELECT pg_reload_conf();
```

#### Balanced (recommended default)
Suitable for most general-purpose agents. Recent lessons are preferred but lessons from the
past two months remain competitive. Matches the Agency RFC N=1081 corpus validation.

```sql
SET pgmnemo.temporal_boost = '0.01';  -- half-life ≈ 70 days
```

#### Historical archive agent
For agents that manage long-lived institutional knowledge (design decisions, compliance
policies, architecture records). Temporal decay is present but slow — a year-old lesson
still contributes ~70% of its base score.

```sql
SET pgmnemo.temporal_boost = '0.001'; -- half-life ≈ 693 days
```

### Tuning workflow

1. Start with `0.01` (balanced preset).
2. Query `SELECT created_at, score FROM pgmnemo.recall_lessons(...)` for a representative
   set of queries and inspect whether age-appropriate lessons are surfacing.
3. If old lessons crowd out recent ones, raise `temporal_boost` toward `0.05–0.1`.
   If recent lessons crowd out established knowledge, lower toward `0.001–0.005`.
4. Validate against your recall benchmark before applying `ALTER SYSTEM`.

```sql
-- Inspect effective decay for lessons in your corpus:
SELECT lesson_id, created_at,
       ROUND((NOW() - created_at)::numeric / 86400, 1)            AS age_days,
       ROUND(EXP(-current_setting('pgmnemo.temporal_boost')::float
             * EXTRACT(EPOCH FROM (NOW() - created_at)) / 86400
             )::numeric, 4)                                        AS temporal_multiplier
FROM pgmnemo.agent_lesson
ORDER BY created_at DESC
LIMIT 20;
```

---

## Point-in-time recall — `as_of_ts` (v0.6.0)

### Using `as_of_ts` for historical recall

`recall_lessons()` v0.6.0 accepts `as_of_ts TIMESTAMPTZ` as the optional 6th
parameter. When provided, the query returns only lessons that were **valid at
that timestamp** (`t_valid_from ≤ as_of_ts < t_valid_to`).

```sql
-- Current state (default — as_of_ts NULL):
SELECT topic, lesson_text, score
FROM pgmnemo.recall_lessons($embedding, 10, 'developer', 1, 'query');

-- Historical state — what did the agent know at the start of a session?
SELECT topic, lesson_text, score
FROM pgmnemo.recall_lessons(
    $embedding,
    10,
    'developer',
    1,
    'query',
    '2026-04-01 09:00:00+00'::TIMESTAMPTZ   -- as_of_ts
);

-- Pre-incident snapshot (audit trail use case):
SELECT topic, lesson_text, score
FROM pgmnemo.recall_lessons(
    $embedding,
    10,
    NULL,    -- all roles
    42,      -- project_id
    NULL,    -- no text query
    '2026-05-01 00:00:00+00'::TIMESTAMPTZ
);
```

**Requires bitemporality (v0.5.0+).** Rows have `t_valid_from` / `t_valid_to`
columns. Lessons ingested before v0.5.0 have `t_valid_from = created_at` and
`t_valid_to = 'infinity'` (backfilled by the v0.5.0 migration).

**Connection pool safety:** `as_of_ts` sets a transaction-local GUC internally
(`set_config('pgmnemo.as_of_timestamp', ..., TRUE)`). The `TRUE` flag means
"transaction-local" — the GUC is cleared on `COMMIT` or `ROLLBACK`. No
session-state leaks between pooled connections.

**Hybrid path:** When `query_text` is also provided, `as_of_ts` flows through
`recall_lessons()` → GUC → `recall_hybrid()`. Both the dense ANN branch and the
BM25 sparse branch apply the temporal filter.

---

## Tuning recency × boost (v0.6.0 reference table)

### `temporal_boost` × `recency_weight` interaction

Recency factor: `exp(−recency_weight × temporal_boost × age_days / 90)`

| age\_days | boost=1, w=0.05 | boost=3, w=0.10 | boost=10, w=0.05 |
|-----------|-----------------|-----------------|------------------|
| 7         | 0.996           | 0.977           | 0.962            |
| 90        | 0.951           | 0.741           | 0.607            |
| 365       | 0.817           | 0.018           | 0.130            |
| 730       | 0.668           | 0.000           | 0.017            |

Score values are the multiplier applied to the recency component, rounded to 3 d.p.

**Warning:** At `recency_weight=0.10` + `temporal_boost=3`, lessons >365 days old
score ~0 on the recency component. If your corpus includes historical lessons
(migrated from earlier systems), use `recency_weight=0.05` + `temporal_boost=10` or
`temporal_boost=1` (effectively disables extra decay).

**Guidance:**

| Scenario | Recommended settings |
|---|---|
| Fast-moving corpus (ephemeral tasks) | `temporal_boost=10`, `recency_weight=0.05` |
| Balanced general-purpose (default) | `temporal_boost=1`, `recency_weight=0.05` |
| Long-lived / archival corpus | `temporal_boost=1`, `recency_weight=0.005` |
| Historical audit / time-travel | Use `as_of_ts` instead of boost tuning |
| Disable temporal decay entirely | `temporal_boost=0` |

```sql
-- Fast-moving: ephemeral task context
SET pgmnemo.temporal_boost = '10';
SET pgmnemo.recency_weight = '0.05';

-- Archival: institutional knowledge base
SET pgmnemo.temporal_boost = '1';
SET pgmnemo.recency_weight = '0.005';

-- Disable decay:
SET pgmnemo.temporal_boost = '0';
```

**Note on Fix-A (v0.6.0):** The recency term in `recall_hybrid()` scoring uses
`COALESCE(as_of_ts, NOW())` as the reference point. When querying a historical
`as_of_ts`, recency decay is computed relative to that timestamp (not wall-clock
`NOW()`), so very old `as_of_ts` queries produce historically-consistent scores.
