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

## Tuning

### HNSW ef_search

Higher `ef_search` improves recall accuracy at the cost of query latency. Default is 40.

```sql
-- Per-session (no restart required)
SET hnsw.ef_search = 100;
```

Rule of thumb: start at 40 for latency-sensitive paths, raise to 100–200 when recall
accuracy matters more than p99 latency.

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
