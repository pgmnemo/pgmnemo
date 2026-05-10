# pgmnemo v0.3.0 — MAGMA §3: Temporal + Entity Graph Schema RFC

**Status:** Implemented  
**Migration:** v0.3.0_001 (`extension/pgmnemo--0.2.1--0.3.0.sql`)  
**Date:** 2026-05-09  
**Authors:** pgmnemo contributors

---

## 1. Motivation

pgmnemo v0.2.x `mem_edge` uses a flat `edge_type TEXT` column with 8 allowed values:
`causal`, `temporal`, `semantic`, `entity`, `supersedes`, `derives_from`, `contradicts`, `elaborates`.

The `recall_lessons()` BFS in v0.2.x incorrectly referenced `me.relation_type` with uppercase
constants (`CAUSED_BY`, `CO_OCCURRED`, `DERIVED_FROM`) that never matched the actual stored
values — meaning graph proximity was silently zero for all queries.

MAGMA §3 introduces a two-level edge taxonomy:

| `edge_kind` (category) | `edge_type` (specific) |
|---|---|
| `causal` | `causal`, `derives_from`, `contradicts` |
| `temporal` | `temporal` |
| `semantic` | `semantic`, `elaborates`, `supersedes` |
| `entity` | `entity` |

The `edge_kind` ENUM enables:
- Partial indexes scoped per category for efficient graph traversal
- BFS filter using `edge_kind IN ('causal', 'temporal')` instead of type-string matching
- Future extension of `edge_type` values without breaking traversal logic

---

## 2. Schema Changes

### 2.1 New ENUM type

```sql
CREATE TYPE pgmnemo.edge_kind AS ENUM ('semantic', 'temporal', 'causal', 'entity');
```

### 2.2 New column on `mem_edge`

```sql
ALTER TABLE pgmnemo.mem_edge ADD COLUMN edge_kind pgmnemo.edge_kind NOT NULL;
```

The column is populated by backfill (see §3) before the NOT NULL constraint is applied.

### 2.3 Per-kind partial indexes

Four partial B-tree indexes, one per `edge_kind` value, optimised for the dominant traversal
pattern for each category:

| Index name | Columns | Partial condition |
|---|---|---|
| `ix_mem_edge_kind_causal` | `(source_id, target_id, weight DESC)` | `WHERE edge_kind = 'causal'` |
| `ix_mem_edge_kind_temporal` | `(source_id, created_at DESC, target_id)` | `WHERE edge_kind = 'temporal'` |
| `ix_mem_edge_kind_semantic` | `(source_id, weight DESC, target_id)` | `WHERE edge_kind = 'semantic'` |
| `ix_mem_edge_kind_entity` | `(source_id, target_id)` | `WHERE edge_kind = 'entity'` |

Additionally, a GIN index on `metadata` JSONB enables attribute-level filtering within any edge kind:

```sql
CREATE INDEX ix_mem_edge_metadata_gin ON pgmnemo.mem_edge USING GIN (metadata)
    WHERE metadata != '{}'::jsonb;
```

The existing `ix_pgmnemo_mem_edge_type_time` index is replaced by `ix_pgmnemo_mem_edge_kind_time`
on `(edge_kind, created_at DESC)`.

---

## 3. Backfill Logic

Migration v0.3.0_001 backfills `edge_kind` for all existing rows using the mapping:

```sql
UPDATE pgmnemo.mem_edge
SET edge_kind = CASE
    WHEN edge_type IN ('causal', 'derives_from', 'contradicts') THEN 'causal'
    WHEN edge_type = 'temporal'                                  THEN 'temporal'
    WHEN edge_type IN ('semantic', 'elaborates', 'supersedes')   THEN 'semantic'
    WHEN edge_type = 'entity'                                    THEN 'entity'
    ELSE                                                              'semantic'  -- safe fallback
END
WHERE edge_kind IS NULL;
```

Existing causal edges (`edge_type = 'causal'`) receive `edge_kind = 'causal'`.

---

## 4. Function Updates

### 4.1 `recall_lessons()` BFS fix

The BFS graph-walk CTE in `recall_lessons()` now uses:

```sql
WHERE me.edge_kind IN ('causal', 'temporal')
```

This replaces the broken v0.2.x filter `me.relation_type IN ('CAUSED_BY', 'CO_OCCURRED', 'DERIVED_FROM')`
which never matched any rows (wrong column name, wrong case).

**Impact:** Graph proximity scoring in `recall_lessons()` was effectively disabled in v0.2.x.
v0.3.0 activates it for the first time for any `mem_edge` row with `edge_kind IN ('causal','temporal')`.

### 4.2 `traverse_causal_chain()` update

The function now filters on both `edge_kind = 'causal'` and `edge_type = ANY(relation_types)`,
using the per-kind partial index for the primary filter.

Default `relation_types` changed from `ARRAY['CAUSED_BY']` to `ARRAY['causal','derives_from','contradicts']`
to match the actual stored values.

---

## 5. Insertion Requirements (post v0.3.0)

New `mem_edge` rows MUST provide `edge_kind`. Applications should derive it from `edge_type`
using the mapping in §3. The column is NOT NULL with no default — a missing value raises an error
at insert time, making misconfigured callers fail fast.

Example:

```sql
INSERT INTO pgmnemo.mem_edge (source_id, target_id, edge_type, edge_kind, weight)
VALUES (42, 99, 'causal', 'causal', 0.9);
```

---

## 6. Backward Compatibility

- The `edge_type` TEXT column and its CHECK constraint are **unchanged**.
- All existing indexes are preserved; only `ix_pgmnemo_mem_edge_type_time` is replaced.
- `recall_lessons()` signature is unchanged; the BFS fix is internal.
- `traverse_causal_chain()` signature is unchanged; default `relation_types` are updated to
  use correct lowercase values — a silent fix for callers using the default.

---

## 7. Evidence Criteria

Per MAGMA IMPL task:

| Criterion | Status |
|---|---|
| Schema reviewed | Done — DDL in `pgmnemo--0.2.1--0.3.0.sql` |
| Migration applied to dev DB | Pending operator action |
| `mem_edge` populated with temporal + entity edges from `agent_lesson` rows | Pending seed script |

Seed query to insert temporal edges from existing `agent_lesson` rows (ordered pairs by `created_at`):

```sql
-- Insert temporal edges between consecutive lessons in the same project
INSERT INTO pgmnemo.mem_edge (source_id, target_id, edge_type, edge_kind, weight, metadata)
SELECT
    a.id        AS source_id,
    b.id        AS target_id,
    'temporal'  AS edge_type,
    'temporal'  AS edge_kind,
    1.0         AS weight,
    jsonb_build_object('auto_seeded', true, 'seeded_at', NOW()) AS metadata
FROM (
    SELECT id, project_id, created_at,
           LEAD(id) OVER (PARTITION BY project_id ORDER BY created_at) AS next_id
    FROM pgmnemo.agent_lesson
    WHERE is_active
) a
JOIN pgmnemo.agent_lesson b ON b.id = a.next_id
WHERE a.next_id IS NOT NULL
ON CONFLICT DO NOTHING;
```
