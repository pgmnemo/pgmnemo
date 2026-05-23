# Migration Guide: External Memory Tables → pgmnemo

This guide covers version-to-version upgrade paths and migration from an external
`mem.*` schema to `pgmnemo.agent_lesson`.

---

## 0.5.1 → 0.6.0

**Release date:** 2026-05-22 (target) | **SQL changes:** Yes

### Upgrade

```bash
ALTER EXTENSION pgmnemo UPDATE TO '0.6.0';
```

No table rewrite. DDL-only changes (`CREATE OR REPLACE` / `DROP + CREATE` functions).
Estimated duration: <1s on any corpus size.

### Breaking changes

**None for positional callers.** All public function signatures remain backward compatible
for code that calls functions with positional arguments (see [PLAN §2](../spec/v060/PLAN_V060.md)).

> **Note on `recall_lessons()` signature:** The 5-argument overload
> `recall_lessons(vector, INT, TEXT, INT, TEXT)` is dropped and replaced by a 6-argument
> form (`as_of_ts TIMESTAMPTZ DEFAULT NULL`). Callers using positional arguments are
> unaffected. Explicit `GRANT EXECUTE` statements referencing the old 5-arg type signature
> must be re-applied to the new 6-arg form after upgrade.

### New behavior

1. **`recall_hybrid()` ranking** — **unchanged from v0.5.1**. `ORDER BY` still
   uses `fusion_score` (weighted linear combination of raw vec + BM25 scores).
   RRF Fix-A (normalized rrf_diag as primary signal) was deferred to v0.6.1
   after failing the bench gate (−2.40 pp LME-S recall@10); see
   [`spec/v060/INVESTIGATION_FIX_A_REGRESSION.md`](../spec/v060/INVESTIGATION_FIX_A_REGRESSION.md).
   The `rrf_score` output column is retained (diagnostic value). Output columns
   and their types are unchanged.

2. **`recall_lessons()` — `as_of_ts` parameter** — new optional 6th parameter.
   Existing calls with 5 args resolve to `as_of_ts = NULL` (identical behavior).

3. **`stats()` — `ghost_count`** — new column at position 14. Named-column callers
   unaffected. `SELECT *` callers receive one additional column.

4. **`ingest()` — dedup NOTICE** — `RAISE NOTICE` now fires when bitemporal
   close+create triggers. Informational only; no behavior change.

### Rollback (Q6)

PostgreSQL does not support `ALTER EXTENSION pgmnemo UPDATE TO '0.5.1'` (downgrade
via extension update mechanism is not supported).

**Pre-upgrade backup procedure (run BEFORE upgrade):**

```bash
# Option A — table-level backup (fastest, recommended):
psql "$DSN" -c "COPY pgmnemo.agent_lesson TO '/tmp/pgmnemo_backup_pre060.csv' CSV HEADER;"
psql "$DSN" -c "COPY pgmnemo.mem_edge TO '/tmp/pgmnemo_mem_edge_pre060.csv' CSV HEADER;"

# Option B — pg_dump schema+data (more complete, portable):
pg_dump -Fc \
    -t 'pgmnemo.agent_lesson' \
    -t 'pgmnemo.mem_edge' \
    "$DSN" \
    > pgmnemo_pre_060_$(date +%Y%m%d_%H%M%S).dump

# Recommended: run both A and B before applying upgrade.
```

**To roll back after upgrade (if needed):**

1. Restore from pre-upgrade backup:
   ```bash
   # From pg_dump:
   pg_restore -d "$DSN" pgmnemo_pre_060_YYYYMMDD_HHMMSS.dump

   # From CSV (only data; functions are already reverted by step 2):
   psql "$DSN" -c "\COPY pgmnemo.agent_lesson FROM '/tmp/pgmnemo_backup_pre060.csv' CSV HEADER;"
   ```

2. OR: manual function replacement (apply v0.5.1 from source):
   ```bash
   # This is destructive — drops and recreates all pgmnemo functions.
   DROP EXTENSION pgmnemo CASCADE;
   CREATE EXTENSION pgmnemo VERSION '0.5.1';
   ```

3. Zero-downtime rollback: **not available** — extension upgrade holds
   `ACCESS EXCLUSIVE` briefly; rollback requires restore from dump.

**No-downgrade caveat:** The extension update mechanism is one-directional.
`ALTER EXTENSION pgmnemo UPDATE TO '0.5.1'` will raise:
```
ERROR: version "0.5.1" of extension "pgmnemo" is already installed
```
or if 0.5.1 is no longer the installed version, the update path back does not exist.
The only safe rollback is a full restore from the pre-upgrade dump.

**Pre-upgrade checklist:**
- [ ] `COPY pgmnemo.agent_lesson TO '/tmp/pgmnemo_backup_pre060.csv' CSV HEADER;`
- [ ] `pg_dump -Fc -t 'pgmnemo.*' "$DSN" > pgmnemo_pre_060.dump`
- [ ] Confirm no other `ALTER EXTENSION` is in flight (`SELECT * FROM pg_stat_activity`)
- [ ] Review `SELECT ghost_count FROM pgmnemo.stats()` post-upgrade to baseline provenance debt

---

## 0.4.1 → 0.5.0

**Release date:** 2026-05-17 | **Commit:** 9aa8f85

### Breaking changes

#### (a) 4-argument `traverse_causal_chain()` removed

The overload `traverse_causal_chain(start_id, max_depth, role_filter, project_id_filter)` is removed. Use the 2-argument form and filter in the caller:

```sql
-- Before (removed):
SELECT * FROM pgmnemo.traverse_causal_chain(101, 5, 'developer', 42);

-- After:
SELECT * FROM pgmnemo.traverse_causal_chain(101, 5)
WHERE role = 'developer' AND project_id = 42;
```

#### (b) `mem_edge` column rename: `lesson_a_id` / `lesson_b_id` → `source_id` / `target_id`

The upgrade script (`pgmnemo--0.4.1--0.5.0.sql`) runs `ALTER TABLE pgmnemo.mem_edge RENAME COLUMN` automatically. Any application code that references these columns by name must be updated:

```sql
-- Before:
INSERT INTO pgmnemo.mem_edge (lesson_a_id, lesson_b_id, edge_kind, relation_type)
VALUES (1001, 1002, 'causal', 'CAUSED_BY');

-- After (direct INSERT):
INSERT INTO pgmnemo.mem_edge (source_id, target_id, edge_kind, relation_type)
VALUES (1001, 1002, 'causal', 'CAUSED_BY');

-- After (preferred — use add_edge() helper, column-name agnostic):
SELECT pgmnemo.add_edge(1001, 1002, 'CAUSED_BY');
```

### New columns (non-breaking, nullable)

Three bitemporality columns are added to `pgmnemo.agent_lesson` with `DEFAULT NULL`:

| Column | Type | Purpose |
|--------|------|---------|
| `t_valid_from` | TIMESTAMPTZ | Start of the validity period for this lesson |
| `t_valid_to` | TIMESTAMPTZ | End of the validity period (NULL = currently valid) |
| `content_hash` | TEXT | SHA-256 of `lesson_text` — detects content drift across versions |

These columns are optional. Existing rows are unaffected (all NULL). To query only currently-valid lessons:

```sql
SELECT * FROM pgmnemo.agent_lesson
WHERE (t_valid_to IS NULL OR t_valid_to > NOW());
```

### Extension update command

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.5.0';
```

The upgrade script handles all DDL changes automatically (column renames via `ALTER TABLE`, new nullable columns, index updates). No data is lost or rewritten.

### Rollback (v0.5.0 → v0.4.1)

pgmnemo does not ship a DOWN migration script for this release. Use the procedure below to
reverse the v0.5.0 DDL changes manually.

> ⚠ **Data-loss warning:** If any rows in `pgmnemo.agent_lesson` were inserted with
> explicit `t_valid_from` / `t_valid_to` values (i.e., non-NULL valid windows), those
> values will be **permanently lost** when the columns are dropped. Rows that used the
> default (`NULL`) are unaffected in content — only the column metadata is removed.
> **Take a full dump before proceeding.**

#### Step 1 — Dump current state

```bash
pg_dump -d <db> -n pgmnemo -F custom > pre_rollback_v0.5.0_$(date +%Y%m%d).dump
```

#### Step 2 — Drop the `pgmnemo.as_of()` function

`as_of()` was introduced in v0.5.0 and does not exist in v0.4.1. Drop it first to avoid
foreign-dependency errors when the trigger is removed.

```sql
DROP FUNCTION IF EXISTS pgmnemo.as_of(TIMESTAMPTZ);
```

#### Step 3 — Drop the `temporal_closure` trigger

```sql
DROP TRIGGER IF EXISTS temporal_closure ON pgmnemo.agent_lesson;
-- Also drop the trigger function if it was created as a standalone object:
DROP FUNCTION IF EXISTS pgmnemo.temporal_closure_trigger();
```

#### Step 4 — Drop the bitemporal columns

```sql
ALTER TABLE pgmnemo.agent_lesson
    DROP COLUMN IF EXISTS t_valid_from,
    DROP COLUMN IF EXISTS t_valid_to,
    DROP COLUMN IF EXISTS content_hash;
```

These columns were added with `DEFAULT NULL` in v0.5.0 and are safe to drop if all values
are NULL (default install). If any rows carry non-NULL valid windows, those values are
irrecoverably lost after this step — see the warning above.

#### Step 5 — Restore the 4-argument `traverse_causal_chain()` overload

v0.5.0 removed the 4-argument overload. If your application requires it, restore from
the v0.4.1 extension files:

```bash
# On the PG server: reinstall v0.4.1 extension scripts, then:
psql -c "ALTER EXTENSION pgmnemo UPDATE TO '0.4.1';"
```

Alternatively, apply the v0.4.1 function body from the `rollback/v0.4.1` git branch.

#### Step 6 — Verify

```sql
-- Confirm bitemporal columns are gone:
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'pgmnemo' AND table_name = 'agent_lesson'
  AND column_name IN ('t_valid_from', 't_valid_to', 'content_hash');
-- Expected: 0 rows

-- Confirm trigger is gone:
SELECT tgname FROM pg_trigger
WHERE tgrelid = 'pgmnemo.agent_lesson'::regclass
  AND tgname = 'temporal_closure';
-- Expected: 0 rows

-- Confirm as_of() is gone:
SELECT proname FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgmnemo' AND p.proname = 'as_of';
-- Expected: 0 rows

-- Smoke-test recall:
SELECT lesson_id, score FROM pgmnemo.recall_lessons(NULL::vector(1024), 5);
```

---

## External Memory Tables → pgmnemo

This section is for teams migrating from a `mem.*` schema (a prior mem.* schema) to
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

---

# Part B — Version-to-version upgrade (existing pgmnemo installs)

This section covers in-place upgrades **between pgmnemo versions**. For a fresh
install, just run `CREATE EXTENSION pgmnemo CASCADE`.

## B.1 General mechanism

pgmnemo follows the standard PostgreSQL extension upgrade mechanism. Every
release ships an `extension/pgmnemo--<from>--<to>.sql` script that PG applies
when you run:

```sql
ALTER EXTENSION pgmnemo UPDATE TO '<to_version>';
```

Each upgrade script is **idempotent** (DDL uses `IF NOT EXISTS` / `CREATE OR
REPLACE`) and **does not** require `DROP EXTENSION` + `CREATE EXTENSION`.

## B.2 Per-version notes

### v0.1.x → v0.2.0 (mem_edge, traversal SPs, GUCs)

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0';
```

- New `pgmnemo.mem_edge` table, traversal SPs, GUCs (`recency_weight`,
  `gate_strict`, `include_unverified`).
- No backfill required; `mem_edge` starts empty.
- Rollback: dump + reinstall pattern.

### v0.2.0 → v0.2.0.1 (collision fix)

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.0.1';
```

- `recall_lessons()` IN-param `role`→`role_filter` (INS-029).
- `traverse_temporal_window()` numeric→double precision cast (INS-030).
- Pure function-body fix; no data touched.

### v0.2.0.1 → v0.2.1 (RLS, ef_search, recency tuning)

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.2.1';
```

- RLS policies on `agent_lesson` / `mem_edge`, gated by `pgmnemo.tenant_id` GUC
  (empty = service bypass).
- `pgmnemo.ef_search` GUC (default 100, clamped 10–500).
- `traverse_causal_chain(direction)` parameter added.
- `pgmnemo.recency_weight` default lowered 0.20 → 0.08 (operator override OK).
- **Operator action (optional):** enable RLS by `SET pgmnemo.tenant_id = '<project_id>'`.

### v0.2.1 → v0.2.2 (recall_hybrid — EXPERIMENTAL)

```sql
\i extension/pgmnemo--0.2.1--0.2.2-hybrid.sql
```

- New `pgmnemo.recall_hybrid()` (vector + BM25 fusion). EXPERIMENTAL, opt-in.
- `recall_lessons()` unchanged.
- Adds `lesson_tsv` tsvector column with auto-populating trigger.
- **Backfill:** trigger fires on next UPDATE; to backfill all existing rows:
  `UPDATE pgmnemo.agent_lesson SET lesson_text = lesson_text;`

### v0.4.0 → v0.4.1 (production hardening + new diagnostic API)

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.4.1';
```

- **New SP `pgmnemo.stats()`** — 13-column health-check snapshot (R3 of Agency RFC).
  Safe to call from monitoring loops.
- **`recall_lessons()` output grew 12 → 15 columns** (R4). Appended diagnostic
  columns: `vec_score`, `bm25_score`, `rrf_score`. Named-column callers
  unaffected; **positional-argument callers MUST re-audit**.
- **`pgmnemo.recency_weight` default 0.08 → 0.05** (R1). Adopters using
  `ALTER SYSTEM SET pgmnemo.recency_weight` keep their explicit values across
  the upgrade; only the function-default fallback changes. To preserve the
  previous default explicitly:
  ```sql
  ALTER SYSTEM SET pgmnemo.recency_weight = '0.08';
  SELECT pg_reload_conf();
  ```
- **4-arg `traverse_causal_chain()` DEPRECATED** with `RAISE NOTICE` (R10).
  Will be REMOVED in v0.5.0. Update callers to pass `direction` explicitly:
  ```sql
  -- Before (deprecated):
  SELECT * FROM pgmnemo.traverse_causal_chain(start_id, 5, ARRAY['causal'], TRUE);
  -- After (canonical):
  SELECT * FROM pgmnemo.traverse_causal_chain(start_id, 5, ARRAY['causal'], TRUE, 'forward');
  ```

### v0.2.1 → v0.3.0 (edge_kind ENUM)

```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.3.0';
```

- New ENUM `pgmnemo.edge_kind` with `{semantic, temporal, causal, entity}`.
- `mem_edge.edge_kind` column added (NOT NULL after auto-backfill).
- Per-kind partial B-tree indexes auto-created.
- `recall_lessons()` BFS now uses `edge_kind` (was `edge_type` — never existed).
- `traverse_causal_chain()` BFS filters via `relation_type` (P0 bug fix).
- **Backfill mapping (case-insensitive, automatic inside script):**
  - `CAUSED_BY` / `causal` / `derives_from` / `contradicts` → `causal`
  - `CO_OCCURRED` / `temporal` → `temporal`
  - All others → `semantic` (default)
- Idempotent; safe to re-run.

## B.3 Generic rollback policy

pgmnemo does not ship DOWN migrations. To revert:

1. **Before upgrade:** `pg_dump -d <db> -n pgmnemo -F custom > pre_<version>.dump`
2. **Revert:**
   ```bash
   psql -c "DROP EXTENSION pgmnemo CASCADE"   # drops pgmnemo objects, NOT user data
   # Reinstall older extension files in PG sharedir
   psql -c "CREATE EXTENSION pgmnemo VERSION '<previous>' CASCADE"
   pg_restore -d <db> pre_<version>.dump
   ```

For production, the maintainer team keeps `rollback/v<previous>` git branches at
each release; CI can redeploy from them.

## B.5 Recovery from extension-orphan objects (v0.4.1+)

**Symptom on `ALTER EXTENSION pgmnemo UPDATE`:**

```
ERROR: function pgmnemo.X(...) already exists but is not a member of extension "pgmnemo"
```

**Cause:** Someone applied an intermediate manual SQL patch (e.g. an old
`step4-recall-mixin.sql` snippet from a WG iteration) **outside** the
`ALTER EXTENSION ... UPDATE` mechanism. The function now exists in the schema
but PostgreSQL doesn't consider it part of the extension, so it refuses to
let the extension upgrade replace it.

**Detection:** v0.4.1 ships `pgmnemo.stats()` with an `orphan_count` column.
On a clean install this is `0`. Non-zero means orphans exist:

```sql
SELECT orphan_count FROM pgmnemo.stats();
```

To list the actual orphans:

```sql
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS signature
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
LEFT JOIN pg_depend d
    ON d.objid = p.oid
   AND d.deptype = 'e'
   AND d.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmnemo')
WHERE n.nspname = 'pgmnemo' AND d.objid IS NULL
  AND p.proname NOT LIKE '\_%' ESCAPE '\';
```

**Recovery — re-parent orphans to the extension:**

```sql
-- For each orphan listed by the query above:
ALTER EXTENSION pgmnemo ADD FUNCTION pgmnemo.<proname>(<signature>);
-- Then retry the upgrade:
ALTER EXTENSION pgmnemo UPDATE TO '<target_version>';
```

Requires superuser. **Verify the function body matches the canonical
extension version** before re-parenting — orphans may carry a divergent
implementation from your prior manual patch. If unsure, `DROP FUNCTION` it
and let the upgrade re-create the canonical version:

```sql
DROP FUNCTION pgmnemo.<proname>(<signature>);   -- only the orphan
ALTER EXTENSION pgmnemo UPDATE TO '<target_version>';
```

**Prevention going forward:** never apply files from `extension/` directly via
`psql -f` outside of `CREATE EXTENSION` / `ALTER EXTENSION UPDATE`. Migration
files include a `\quit` directive at the top precisely to discourage this.

## B.4 Post-upgrade verification

```sql
SELECT pgmnemo.version();                                          -- expected new version
SELECT lesson_id, score FROM pgmnemo.recall_lessons(NULL::vector(1024), 5);  -- text recall still works
SELECT edge_kind, COUNT(*) FROM pgmnemo.mem_edge GROUP BY edge_kind;          -- v0.3.0+ only
```

File a GitHub issue with `version()` output + sample query if anything looks off.

