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
    query_embedding  vector(1024),  -- pass NULL for text-only recall
    k                INT     DEFAULT 10,
    role             TEXT    DEFAULT NULL,
    project_id       INT     DEFAULT NULL,
    query_text       TEXT    DEFAULT NULL
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
    query_embedding  vector(1024),
    query_text       TEXT,
    k                INT     DEFAULT 10,
    role_filter      TEXT    DEFAULT NULL,
    project_id_filter INT    DEFAULT NULL,
    vec_weight       FLOAT   DEFAULT 0.4,
    bm25_weight      FLOAT   DEFAULT 0.4
) RETURNS TABLE (
    lesson_id     BIGINT,
    hybrid_score  DOUBLE PRECISION,
    rrf_score     DOUBLE PRECISION,   -- diagnostic: 1/(k+vec_rank) + 1/(k+bm25_rank)
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

Formula: `hybrid_score = vec_weight×cosine + bm25_weight×ts_rank_cd(lesson_tsv, q, 32)`  
Union retrieval: candidates matched by **either** embedding cosine **or** BM25.

### Example

```sql
-- Opt-in: call recall_hybrid() directly
SELECT topic, lesson_text, hybrid_score, rrf_score
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
