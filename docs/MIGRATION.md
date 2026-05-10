# Migration Guide: External Memory Tables → pgmnemo

This guide is for teams migrating from a `mem.*` schema (a prior mem.* schema) to
`pgmnemo.agent_lesson`. It covers field mapping, the backfill policy, and a
worked verification example.

---

## 1. Field mapping

| External `mem.mem_item` column | pgmnemo `agent_lesson` column | Notes |
|---|---|---|
| `content` / `memory_text` | `lesson_text` | Direct text copy. |
| `layer` / `type` | `topic` (primary) + `metadata->>'layer'` | Use a short human-readable `topic`; preserve the original value in `metadata`. |
| `tags` / `properties` | `metadata` (JSONB) | Merge any structured metadata into the JSONB blob. |
| `run_id` | `source_run_id` (BIGINT) | Cast TEXT→BIGINT if your IDs are numeric; keep raw value in `metadata` if not. |
| `task_id` | `source_task_id` (BIGINT) | Same casting rule as `source_run_id`. |
| `ttl` / `expires_after` / `retain_until` | `expires_at` (TIMESTAMPTZ) | Compute absolute timestamp: `NOW() + ttl_interval`. `NULL` = never expires. |
| `verified` / `verification_status` | `verified_at` (TIMESTAMPTZ) | Truthy → `NOW()` (or original verification time). Falsy → `NULL` (ghost lesson). |
| `status` / `lifecycle_state` | `state` (TEXT) | Map to pgmnemo states: `draft`, `candidate`, `validated`, `canonical`, `deprecated`, `archived`, `rejected`, `conflicted`. Default: `'candidate'` for migrated rows. |
| `agent_role` / `agent` | `role` (TEXT) | Exact role string used for recall filtering. |
| `project` / `project_id` | `project_id` (INT) | Must be an integer; map from string slug if needed. |
| `importance` / `priority` | `importance` (SMALLINT 1–5) | Normalise to 1–5 scale. Default `3` if unknown. |
| `commit` / `git_sha` | `commit_sha` (TEXT) | Used for provenance gate and `verified_at` auto-set. |
| `artifact_id` / `hash` | `artifact_hash` (TEXT) | `sha256:` prefix preferred. Either this or `commit_sha` must be non-NULL in production. |
| `embedding` | `embedding` (vector(1024)) | Must be 1024-dimensional. Null is allowed; rows without embeddings are excluded from vector recall but still reachable via full-text search. |
| `created_at` | `created_at` | `DEFAULT now()` — override by inserting explicitly. |

---

## 2. INSERT policy: raw INSERT vs `pgmnemo.ingest()`

### Use `pgmnemo.ingest()` when

- Writing **new** lessons from live agent runs.
- You want automatic `verified_at` stamping when provenance fields are present.
- You want embedding dimension validation (1024 required).

```sql
SELECT pgmnemo.ingest(
    p_role          := 'developer',
    p_project_id    := 42,
    p_topic         := 'security',
    p_lesson_text   := 'Rotate JWT secrets within 24 h of any key-compromise indicator.',
    p_importance    := 4,
    p_commit_sha    := 'a3f9b12'
);
```

### Use raw `INSERT INTO pgmnemo.agent_lesson` when

- **Bulk backfill** from an external table, where you need to:
  - Preserve the original `created_at` timestamp.
  - Set `verified_at` conditionally based on source data.
  - Insert thousands of rows without per-row function call overhead.
- You are running inside a migration script with `gate_strict = 'warn'` or
  `gate_strict = 'off'` to allow rows that lack provenance.

**Always relax the gate before a backfill, then restore it:**

```sql
SET pgmnemo.gate_strict = 'warn';   -- or 'off' during dev
-- ... INSERT statements ...
SET pgmnemo.gate_strict = 'enforce';
```

> **Production rule:** After backfill, set `gate_strict = 'enforce'` (default).
> Any row without `commit_sha` or `artifact_hash` will have `verified_at IS NULL`
> and be excluded from `recall_lessons()` by default. Enable ghost lessons with
> `SET pgmnemo.include_unverified = 'on'` only for audit queries.

---

## 3. State mapping reference

If your external table has a lifecycle/status column, map it as follows:

| External status | pgmnemo `state` |
|---|---|
| `pending` / `new` | `draft` |
| `active` / `approved` | `candidate` or `validated` |
| `confirmed` / `verified` | `validated` |
| `master` / `golden` | `canonical` |
| `outdated` / `stale` | `deprecated` |
| `replaced` / `superseded` | `superseded` |
| `archived` / `deleted` | `archived` |
| `invalid` / `wrong` | `rejected` |
| `conflict` | `conflicted` |

For most backfills, default to `'candidate'` — it is a valid starting point in
the state machine and allows promotion via `pgmnemo.transition_lesson()`.

---

## 4. TTL / retention mapping

```sql
-- Source has a retention interval stored as an INTERVAL string, e.g. '30 days'
expires_at = CASE
    WHEN src.retention IS NOT NULL
    THEN src.created_at + src.retention::INTERVAL
    ELSE NULL   -- never expires
END

-- Source has an absolute retain_until timestamp
expires_at = src.retain_until   -- direct copy

-- Source has a TTL in seconds
expires_at = src.created_at + (src.ttl_seconds || ' seconds')::INTERVAL
```

Evict expired rows on demand:

```sql
SELECT pgmnemo.evict_expired_lessons();   -- returns count of deleted rows
```

---

## 5. Verification status mapping

```sql
verified_at = CASE
    WHEN src.verified = TRUE      THEN COALESCE(src.verified_at, src.created_at)
    WHEN src.verification_status = 'verified' THEN COALESCE(src.verified_at, src.created_at)
    ELSE NULL   -- ghost lesson; excluded from recall by default
END
```

---

## 6. Multi-tenant / RLS notes

pgmnemo v0.2.1+ enforces row-level security via `pgmnemo.tenant_id` GUC.
During backfill run as a superuser or a role with `BYPASSRLS` to avoid the
policy filtering your own writes:

```sql
SET pgmnemo.tenant_id = '';   -- empty = bypass (service-account mode)
-- ... INSERT statements ...
```

After backfill, tenant-scoped reads work normally:

```sql
SET pgmnemo.tenant_id = '42';   -- restrict session to project_id = 42
```

---

## 7. Post-migration verification

After backfill, confirm recall works:

```sql
-- Text-only recall (no embedding required)
SELECT lesson_id, topic, lesson_text, score
FROM pgmnemo.recall_lessons(
    NULL::vector(1024),    -- no embedding
    5,                     -- top-5
    NULL,                  -- all roles
    42,                    -- project_id
    'JWT rotation'         -- full-text query
);
```

For rows that have embeddings, hybrid recall includes cosine similarity:

```sql
SELECT lesson_id, score, topic, lesson_text
FROM pgmnemo.recall_lessons(
    '<your_1024_dim_vector>'::vector(1024),
    10,
    'developer',
    42,
    'key rotation'
);
```

See `examples/migrate_external_memory.sql` for a complete end-to-end test.
