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

## 2. Agent Health Metrics (from tasks DB — queried 2026-05-10)

### 2.0 System-wide throughput

| Metric | Value |
|---|---|
| Total tasks | 5,084 |
| DONE | 2,313 |
| CANCELED | 1,716 |
| ESCALATED | 48 |
| Open (INBOX + SOMEDAY + NEXT + WAITING + DELEGATED + NOW) | 1,007 |
| **Agent success rate** (DONE / terminal) | **56.7%** |
| Escalation rate | 1.2% |
| Cancel rate | 42.1% |

### 2.1 ESCALATED count by priority

| Priority | ESCALATED | DONE | Cancel rate |
|---|---|---|---|
| P1 | 16 | 1,691 | 49.1% |
| P2 | 12 | 458 | 12.3% |
| P3 | 19 | 153 | 9.5% |
| P4 | 1 | 11 | 8.3% |

**Notable open ESCALATED tasks (sampled, 2026-05-09):**

| Task | Priority |
|---|---|
| `[PHANTOM-SWEEP-1]` Audit historical DONE tasks — phantom-DONE class-3 | P1 |
| `[INFRA-PHANTOM-COMMIT]` Reject phantom-DONE without verified commits | P1 |
| `[EVAL-MEM-EDGE-1]` Backfill mem_edge graph layer (currently 0 rows on prod) | P3 |
| `[EVAL-DW-1]` Dual-write parity gap: mem.* 1821 vs pgmnemo 781 (43% in 7d) | P3 |
| `[INFRA-SDK-HANG-1]` SDK_HANG_PATTERN flood — 5 WG tasks escalated 2026-05-09 | P1 |

### 2.2 Stalled runs (INBOX stale ≥ 3 days)

12 tasks in INBOX with `updated_at < 2026-05-07`, oldest since 2026-04-15. Examples:

| Task | Priority | Stale since |
|---|---|---|
| `[LESSONS-260410-1-SHIP]` Activate learning loop + backfill | P2 | 2026-04-15 |
| `[DAG-TPL-IMPL-8]` Integration: wire everything + e2e verification | P2 | 2026-04-15 |
| `[OSF-PREREG-260430-2-FIX-PI-INTEGRATE]` PI integrate v3 draft | P1 | 2026-04-15 |
| `[RES-ACM-M12]` Log-driven anti-pattern catalog from agent_run data | P1 | 2026-04-27 |

2 WAITING, 4 DELEGATED also stalled (not blocked by external gates).

### 2.3 Quality trends (7-day window)

| Date | DONE | ESCALATED | CANCELED | Escalation rate |
|---|---|---|---|---|
| 2026-05-09 | 128 | 16 | 9 | 10.4% |
| 2026-05-08 | 121 | 10 | 1,312 | 7.6% |
| 2026-05-07 | 90 | 1 | 235 | 1.1% |
| 2026-05-06 | 169 | 1 | 20 | 0.6% |
| 2026-05-05 | 120 | 8 | 34 | 6.3% |
| 2026-05-04 | 145 | 12 | 34 | 7.6% |
| 2026-05-03 | 87 | 0 | 3 | 0.0% |

**Trend:** Escalation rate spiked to 10.4% on 2026-05-09 (phantom-DONE audit + SDK_HANG flood).
Mass cancellation on 2026-05-08 (1,312 tasks) indicates a sweep/cleanup run.

---

## 3. Schema Metrics (static analysis — dev DB not available in this environment)

### 3.1 `mem_edge` column count

| Version | Columns |
|---|---|
| v0.2.1 | 7 (`id`, `source_id`, `target_id`, `edge_type`, `weight`, `metadata`, `created_at`) |
| v0.3.0 | 8 (+ `edge_kind pgmnemo.edge_kind NOT NULL`) |

### 3.2 Index inventory (post-migration)

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

### 3.3 ENUM values

```
pgmnemo.edge_kind: {semantic, temporal, causal, entity}
```

### 3.4 Backfill mapping (MAGMA §3 Table 1)

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

## 4. Bugs Found and Fixed

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

## 5. Evidence Checklist (MAGMA IMPL)

| Criterion | Status | Notes |
|---|---|---|
| Schema reviewed | DONE | DDL in migration file, RFC §2 |
| Migration applies cleanly | PENDING | Needs dev DB; migration is idempotent (IF NOT EXISTS / DO $$ checks) |
| `mem_edge` populated — temporal edges | PENDING | DB metric: 0 rows on prod (`[EVAL-MEM-EDGE-1]` ESCALATED); seed query in RFC §7 |
| `mem_edge` populated — entity edges | PENDING | Entity-edge extraction from `agent_lesson.metadata` TBD |
| Backfill of existing causal edges | DONE (in migration) | UPDATE WHERE `edge_kind IS NULL` |

---

## 6. Remaining Work

1. **Apply migration to dev DB** — run `pgmnemo--0.2.1--0.3.0.sql` and verify `\d pgmnemo.mem_edge` shows `edge_kind` column.
2. **Seed temporal edges** — run the seed query from RFC §7 against `agent_lesson` rows.
3. **Seed entity edges** — requires entity extraction from `metadata` JSONB; out of scope for v0.3.0_001 but recommended as a follow-on seed script.
4. **Task draft for entity-edge seeder** — create MAGMA-3 task for entity extraction and `edge_kind='entity'` population.

---

## 7. Self-Evaluation

**What worked:**
- Static analysis of existing migration files revealed BUG-1 (dead graph proximity) which had been silently broken since v0.2.0. This is a correctness fix with real impact on recall quality.
- The two-level taxonomy (edge_kind / edge_type) is clean and backwards-compatible — existing `edge_type` values and constraints are untouched.
- Partial indexes per kind are strictly better than the previous single composite index for filtered graph traversals.

**What could improve:**
- No dev DB was available to run `EXPLAIN (ANALYZE)` on the new indexes or measure backfill row counts. All metrics above are from static analysis of the SQL files.
- Entity-edge population is deferred — temporal edges have an obvious seeding strategy (consecutive lessons by `created_at`), but entity extraction requires NLP/metadata parsing that is outside this migration's scope.
- The GIN index on `metadata` is conditional (`WHERE metadata != '{}'`) — this means rows inserted with `metadata = '{}'::jsonb` default won't be indexed. This is intentional to skip empty rows but should be documented for callers that do put query-relevant data in metadata.
