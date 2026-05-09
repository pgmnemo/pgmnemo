# TL Report: MAGMA-2 pgmnemo v0.3.0 Schema — temporal + entity graphs

**Date:** 2026-05-09  
**Task:** MAGMA-2 IMPL — Extend `mem_edge` with `edge_kind` ENUM + per-kind indexes  
**Priority:** P3 | **Deadline:** 2026-05-23

---

## 1. Deliverables

| File | Type | Status |
|---|---|---|
| `extension/pgmnemo--0.2.1--0.3.0.sql` | Migration SQL | Created |
| `spec/v2/pgmnemo/PGMNEMO_V0.3.0_MAGMA_RFC.md` | RFC | Created |

---

## 2. Schema Metrics (static analysis — dev DB not available in this environment)

### 2.1 `mem_edge` column count

| Version | Columns |
|---|---|
| v0.2.1 | 7 (`id`, `source_id`, `target_id`, `edge_type`, `weight`, `metadata`, `created_at`) |
| v0.3.0 | 8 (+ `edge_kind pgmnemo.edge_kind NOT NULL`) |

### 2.2 Index inventory (post-migration)

| Index name | Type | Scope | Purpose |
|---|---|---|---|
| `ix_pgmnemo_mem_edge_source` | B-tree | all rows | source traversal by type |
| `ix_pgmnemo_mem_edge_target` | B-tree | all rows | target traversal by type |
| `ix_pgmnemo_mem_edge_kind_time` | B-tree | all rows | time-ordered listing by kind |
| `ix_mem_edge_kind_causal` | B-tree (partial) | `edge_kind = 'causal'` | causal chain BFS |
| `ix_mem_edge_kind_temporal` | B-tree (partial) | `edge_kind = 'temporal'` | temporal window BFS |
| `ix_mem_edge_kind_semantic` | B-tree (partial) | `edge_kind = 'semantic'` | semantic fan-out |
| `ix_mem_edge_kind_entity` | B-tree (partial) | `edge_kind = 'entity'` | entity co-lookup |
| `ix_mem_edge_metadata_gin` | GIN | non-empty metadata | JSONB attribute queries |

Removed: `ix_pgmnemo_mem_edge_type_time` (replaced by `ix_pgmnemo_mem_edge_kind_time`)

### 2.3 ENUM values

```
pgmnemo.edge_kind: {semantic, temporal, causal, entity}
```

### 2.4 Backfill mapping (MAGMA §3 Table 1)

| `edge_type` | → `edge_kind` |
|---|---|
| `causal` | `causal` |
| `derives_from` | `causal` |
| `contradicts` | `causal` |
| `temporal` | `temporal` |
| `semantic` | `semantic` |
| `elaborates` | `semantic` |
| `supersedes` | `semantic` |
| `entity` | `entity` |
| *(unknown)* | `semantic` (safe fallback) |

---

## 3. Bugs Found and Fixed

### BUG-1 (Critical): `recall_lessons()` BFS never matched any edges

**File:** `extension/pgmnemo--0.2.0.1--0.2.1.sql:192`

```sql
-- v0.2.x (broken)
WHERE me.relation_type IN ('CAUSED_BY', 'CO_OCCURRED', 'DERIVED_FROM')
```

The column `relation_type` does not exist on `mem_edge` — the column is `edge_type`.
Additionally, the values are uppercase (`CAUSED_BY`) while the stored values are lowercase (`causal`).
**Result:** `graph_walk` CTE always returned zero rows; `graph_proximity` was always 0.0 for all
recall queries. The `δ × graph_proximity` term in the scoring formula was silently dead.

**Fix (v0.3.0):** `extension/pgmnemo--0.2.1--0.3.0.sql:S7`

```sql
-- v0.3.0 (fixed)
WHERE me.edge_kind IN ('causal', 'temporal')
```

### BUG-2 (Minor): `traverse_causal_chain()` default `relation_types` used uppercase

**File:** `extension/pgmnemo--0.2.0.1--0.2.1.sql:278`

```sql
-- v0.2.x (broken default)
relation_types TEXT[] DEFAULT ARRAY['CAUSED_BY']
```

The default value `'CAUSED_BY'` never matched stored `edge_type = 'causal'` rows.

**Fix (v0.3.0):** `extension/pgmnemo--0.2.1--0.3.0.sql:S8`

```sql
-- v0.3.0 (fixed default)
relation_types TEXT[] DEFAULT ARRAY['causal', 'derives_from', 'contradicts']
```

---

## 4. Evidence Checklist (MAGMA IMPL)

| Criterion | Status | Notes |
|---|---|---|
| Schema reviewed | DONE | DDL in migration file, RFC §2 |
| Migration applies cleanly | PENDING | Needs dev DB; migration is idempotent (IF NOT EXISTS / DO $$ checks) |
| `mem_edge` populated — temporal edges | PENDING | Seed query provided in RFC §7 |
| `mem_edge` populated — entity edges | PENDING | Entity-edge extraction from `agent_lesson.metadata` TBD |
| Backfill of existing causal edges | DONE (in migration) | UPDATE WHERE `edge_kind IS NULL` |

---

## 5. Remaining Work

1. **Apply migration to dev DB** — run `pgmnemo--0.2.1--0.3.0.sql` and verify `\d pgmnemo.mem_edge` shows `edge_kind` column.
2. **Seed temporal edges** — run the seed query from RFC §7 against `agent_lesson` rows.
3. **Seed entity edges** — requires entity extraction from `metadata` JSONB; out of scope for v0.3.0_001 but recommended as a follow-on seed script.
4. **Task draft for entity-edge seeder** — create MAGMA-3 task for entity extraction and `edge_kind='entity'` population.

---

## 6. Self-Evaluation

**What worked:**
- Static analysis of existing migration files revealed BUG-1 (dead graph proximity) which had been silently broken since v0.2.0. This is a correctness fix with real impact on recall quality.
- The two-level taxonomy (edge_kind / edge_type) is clean and backwards-compatible — existing `edge_type` values and constraints are untouched.
- Partial indexes per kind are strictly better than the previous single composite index for filtered graph traversals.

**What could improve:**
- No dev DB was available to run `EXPLAIN (ANALYZE)` on the new indexes or measure backfill row counts. All metrics above are from static analysis of the SQL files.
- Entity-edge population is deferred — temporal edges have an obvious seeding strategy (consecutive lessons by `created_at`), but entity extraction requires NLP/metadata parsing that is outside this migration's scope.
- The GIN index on `metadata` is conditional (`WHERE metadata != '{}'`) — this means rows inserted with `metadata = '{}'::jsonb` default won't be indexed. This is intentional to skip empty rows but should be documented for callers that do put query-relevant data in metadata.
