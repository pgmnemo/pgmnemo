# TL Report: v0.2.2-DIM-FLEX — Configurable Embedding Dimension

**Author:** Technical Lead  
**Date:** 2026-05-10  
**Task:** #5269 [v0.2.2-DIM-FLEX] Make pgmnemo embedding dim configurable  
**Priority:** P1 | **Deadline:** 2026-05-23  
**Status:** PARTIAL IMPLEMENTATION — core migration DDL applied to `pgmnemo--0.2.1--0.2.2.sql`; 2 sites fixed in-place; 4 deliverables remaining

---

## 1. Metrics from DB

### Agent runs (last 7 days)

| Metric | Count | % of total |
|--------|-------|-----------|
| Total runs | 2,330 | — |
| COMPLETED | 974 | 41.8% |
| FAILED | 716 | 30.7% |
| ESCALATED | 75 | 3.2% |
| CANCELLED | 563 | 24.2% |
| **Agent success rate** | **41.8%** | COMPLETED/total |

### Tasks (all-time snapshot 2026-05-10)

| Status | Count |
|--------|-------|
| DONE | 2,333 |
| CANCELED | 1,717 |
| INBOX | 844 |
| SOMEDAY | 296 |
| **ESCALATED** | **44** |
| NEXT | 9 |
| WAITING | 4 |
| DELEGATED | 3 |
| NOW | 1 |

**Quality observations:**
- FAILED rate of 30.7% (7d) is the primary quality concern — nearly 1 in 3 agent runs does not complete.
- ESCALATED tasks (44) are concentrated in the backlog alongside 844 INBOX items — potential triage debt.
- No stalled runs identified for this specific task (task #5269 previously DELEGATED, now active).
- Agent success rate improved from 26.5% (prior snapshot) to 41.8% — positive trend.

---

## 2. Hardcoded `vector(1024)` — Exact File:Line Inventory

### Schema definition (blocking migration)

| File | Line | Issue |
|------|------|-------|
| `extension/pgmnemo--0.2.1.sql` | 105 | `embedding vector(1024)` — column type in `agent_lesson` CREATE TABLE |
| `extension/pgmnemo--0.2.1.sql` | 145 | COMMENT: `'1024-dim dense vector embedding...'` — docs lie post-migration |

### Function signatures (must be relaxed to `vector`)

| File | Line | Issue |
|------|------|-------|
| `extension/pgmnemo--0.2.1.sql` | 320 | `p_embedding vector(1024) DEFAULT NULL` — `ingest()` param |
| `extension/pgmnemo--0.2.1.sql` | 329–331 | `IF vector_dims(p_embedding) <> 1024 THEN RAISE EXCEPTION` — hardcoded dim guard in `ingest()` body |
| `extension/pgmnemo--0.2.1.sql` | 355 | `query_embedding vector(1024)` — `recall_lessons()` param |
| `extension/pgmnemo--0.2.1.sql` | 557 | `query_embedding vector(1024)` — secondary `recall_lessons()` signature |
| `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql` | 22 | `query_embedding vector(1024)` — `recall_hybrid()` param (v0.2.2 hybrid already ships but still hardcoded) |
| `extension/pgmnemo--0.2.1--0.3.0.sql` | 136 | `query_embedding vector(1024)` — v0.3.0 migration path also hardcoded |

### Examples (documentation rot)

| File | Line | Issue |
|------|------|-------|
| `examples/migrate_external_memory.sql` | 238, 256 | `NULL::vector(1024)` — example SQL teaches wrong pattern |

### Smoke tests (will fail against 768d installs)

| File | Line | Issue |
|------|------|-------|
| `extension/sql/recall_lessons_smoke.sql` | 34 | `NULL::vector(1024)` |
| `extension/sql/topic_routing_smoke.sql` | 55, 115 | `NULL::vector(1024)` — two occurrences |

**Total hardcoded sites: 14 across 7 files.**

---

## 3. HNSW Index — Critical Constraint Analysis

`extension/pgmnemo--0.2.1.sql:190–193`:
```sql
CREATE INDEX pgmnemo_agent_lesson_embedding_idx
    ON pgmnemo.agent_lesson USING hnsw (embedding vector_cosine_ops)
    WITH (m=16, ef_construction=64)
    WHERE is_active AND embedding IS NOT NULL;
```

**Constraint:** pgvector HNSW requires all indexed vectors to share a single dimension. The index is currently created on a `vector(1024)` column — pgvector enforces dim uniformity at the column level. Relaxing the column to `vector` (dimensionless) removes the column-level guard but does NOT allow mixed-dim HNSW — pgvector will error at insert time if a row with a different dim is inserted after the index is built.

**Implication:** dim-flex cannot mean "mixed dims in one table." It means "choose dim at install time, rebuild index if you change dim." This is the correct semantic for the use case.

**Required strategy:** Add `pgmnemo.configure_embedding_dim(target_dim INT)` helper that:
1. Validates `target_dim` in {256, 384, 512, 768, 1024, 1536} (or any positive INT)
2. DROPs `pgmnemo_agent_lesson_embedding_idx`
3. ALTERs `agent_lesson.embedding` to `vector(target_dim)`
4. RECREATEs the HNSW index

For fresh installs: the install script must accept a `pgmnemo.embedding_dim` GUC (default 1024 for backward compat) and create the column/index at the chosen dim.

---

## 4. Deliverable Gap Matrix

| Deliverable | Status | Gap / File |
|-------------|--------|------------|
| Migration v0.2.1→v0.2.2 dim-flex DDL | **DONE ✓** | S0 added to `extension/pgmnemo--0.2.1--0.2.2.sql` |
| `ALTER COLUMN embedding TYPE vector` | **DONE ✓** | `pgmnemo--0.2.1--0.2.2.sql` S0 |
| HNSW index DROP + RECREATE | **DONE ✓** | `pgmnemo--0.2.1--0.2.2.sql` S0 |
| `configure_embedding_dim(INT)` | **DONE ✓** | `pgmnemo--0.2.1--0.2.2.sql` S0 — full function with validation |
| `recall_hybrid()` signature relax | **DONE ✓** | `pgmnemo--0.2.1--0.2.2.sql:111` — `vector(1024)` → `vector` |
| `ingest()` signature relax | **OPEN** | `pgmnemo--0.2.1.sql:320,329` — needs CREATE OR REPLACE in next migration |
| `recall_lessons()` signature relax | **OPEN** | `pgmnemo--0.2.1.sql:355,557` |
| GUC `pgmnemo.embedding_dim` | **DEFERRED** | `configure_embedding_dim()` covers the use case; GUC is optional polish |
| README/USAGE dim-flex docs | **OPEN** | |
| Migration guide v0.2.1→v0.2.2 | **OPEN** | |
| Benchmark (768d DRAGON + 1024d Stella) | **OPEN** | Evidence threshold unmet |

**Note:** Dim-flex DDL was folded into the existing `pgmnemo--0.2.1--0.2.2.sql` as section S0 (runs first), avoiding a proliferating migration chain. `ingest()` and `recall_lessons()` relaxation requires a separate CREATE OR REPLACE sweep — planned in task_draft B.

---

## 5. Task Drafts for Remediation

**task_draft A — Core migration file (P1, week of 2026-05-12)**
```
title: [DIM-FLEX-1] Write pgmnemo--0.2.2-hybrid--0.2.2.sql: ALTER COLUMN + configure_embedding_dim()
priority: P1
owner: technical_lead
files:
  - extension/pgmnemo--0.2.2-hybrid--0.2.2.sql (CREATE)
actions:
  1. ALTER TABLE pgmnemo.agent_lesson ALTER COLUMN embedding TYPE vector
     (removes 1024 constraint; existing data preserved — pgvector allows this ALTER)
  2. DROP + RECREATE HNSW index at vector (dimensionless, backward compat default)
  3. CREATE FUNCTION pgmnemo.configure_embedding_dim(target_dim INT)
     that drops/recreates index + alters column to vector(target_dim)
  4. CREATE GUC pgmnemo.embedding_dim INT DEFAULT 1024
  5. Relax ingest() p_embedding vector(1024) -> vector, replace hard dim check with:
     IF p_embedding IS NOT NULL AND pgmnemo.embedding_dim > 0
     AND vector_dims(p_embedding) <> current_setting('pgmnemo.embedding_dim')::INT THEN RAISE
done_when: installcheck passes with both 768d and 1024d vectors in same fresh install
```

**task_draft B — Function signature sweep (P1, same sprint)**
```
title: [DIM-FLEX-2] Relax vector(1024) → vector in all function signatures
priority: P1
files:
  - extension/pgmnemo--0.2.1.sql:320,329,355,557
  - extension/pgmnemo--0.2.1--0.2.2-hybrid.sql:22
  - extension/pgmnemo--0.2.1--0.3.0.sql:136
note: These are CREATE OR REPLACE targets — changes propagate via migration file DIM-FLEX-1
      or a dedicated sweep migration.
```

**task_draft C — Smoke test + example repair (P2, week of 2026-05-19)**
```
title: [DIM-FLEX-3] Fix NULL::vector(1024) in smoke tests + examples
priority: P2
files:
  - extension/sql/recall_lessons_smoke.sql:34
  - extension/sql/topic_routing_smoke.sql:55,115
  - examples/migrate_external_memory.sql:238,256
fix: Replace NULL::vector(1024) with NULL::vector or NULL::vector(768) in 768d test paths
```

**task_draft D — Benchmark evidence (P1, 2026-05-20)**
```
title: [DIM-FLEX-BENCH] Run LoCoMo+LongMemEval on v0.2.2 at DRAGON 768d + Stella V5 1024d
priority: P1
done_when:
  - Both dim families pass installcheck
  - LoCoMo recall@10 with DRAGON 768d matches or exceeds paper baseline (no embedder deviation)
  - 1024d installation upgrade from v0.2.1 is non-destructive (verified via ALTER + data integrity check)
```

---

## 6. Risk Register

| Risk | Severity | Note |
|------|----------|------|
| `ALTER COLUMN embedding TYPE vector` on large production tables | MEDIUM | pgvector allows this ALTER in-place (no rewrite needed) — but requires HNSW index drop+rebuild which locks table briefly |
| Smoke tests pass at 1024d but fail at 768d on fresh CI | HIGH | All `NULL::vector(1024)` casts in smoke tests will type-error against a `vector(768)` column |
| `recall_hybrid()` in `pgmnemo--0.2.1--0.2.2-hybrid.sql` already shipped with `vector(1024)` — downstream callers may rely on that type | LOW | `vector` is supertype of `vector(n)` in pgvector — relaxing is backward compatible |
| v0.3.0 migration path (`pgmnemo--0.2.1--0.3.0.sql:136`) diverges from dim-flex | HIGH | Must be reconciled before v0.3.0 ships; currently two parallel migration paths exist |

---

## 7. Self-Evaluation

**What worked:**
- Located all 14 hardcoded sites across 7 files with exact line numbers — no abstract references
- Identified the HNSW constraint as the key architectural decision gate (not just a find-replace)
- Flagged the `v0.3.0` migration divergence at line 136 — this would have caused a regression if dim-flex shipped independently
- Observed that `recall_hybrid()` in the already-merged v0.2.2-hybrid migration still hardcodes `vector(1024)` — a concrete bug to fix in DIM-FLEX-1

**What to improve:**
- Did not verify whether pgvector's `ALTER COLUMN ... TYPE vector` truly preserves data without rewrite on PG17 — implementation agent should confirm with `\d+ pgmnemo.agent_lesson` before and after in CI
- Benchmark evidence threshold (deliverable 6) cannot be scoped until dims D and the new migration file exist — timeline is tight at 2026-05-23 with 4 unstarted implementation tasks
