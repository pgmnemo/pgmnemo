# ADR-0.9.0: pgmnemo 0.9.0 — navigate_locate Signature Add, Additive Schema Columns, and Release Fork-Flow

**Status:** APPROVED — pending BENCHMARK C1 empirical gate for #4 only  
**Date:** 2026-06-10  
**Author:** chief_architect (86)  
**Authority inputs:** DECISION_0.9_SQL.md · DECISION_0.9_RECALL_HYBRID.md · REVIEW_0.9.md  
**Decision owner:** Founder (public commit / OSS push)  
**Applies to:** pgmnemo 0.9.0, migration file `pgmnemo--0.8.3--0.9.0.sql`

---

## 1. Context

pgmnemo 0.8.3 is a documentation-only patch; its SQL is byte-identical to 0.8.2. The 0.9.0 release addresses two source-confirmed bugs and adds three nullable columns required by the G1-gated dispatch items (#5/#6) that ship in a later release.

Four items are in scope for the migration file:

| # | Item | Change class | ADR section |
|---|------|-------------|-------------|
| **1** | Fix `navigate_locate` budget counter | Body-only (function rewrite) | §4 |
| **1b** | Add `project_id_filter` to `navigate_locate` | **Schema-visible: signature add** | §5 (main gate) |
| **2** | NULL-embedding ≠ ghost at ingest | Body-only (function rewrite) | §4 |
| **3** | `content_type` + `blob_ref` + `doc_ref` nullable cols | **Schema-visible: DDL add** | §6 (main gate) |
| **4** | Fix `recall_hybrid` O(n) scan | Body-only (function rewrite) | §7 (BENCHMARK gate) |

Items **#1b** and **#3** are the schema-visible changes that require explicit sign-off before migration authoring; this ADR is their human gate. Items #1 and #2 are body-only rewrites with no signature or DDL change. Item #4 is body-only but gated on an empirical BENCHMARK (§7).

---

## 2. Source Anchor

All patches in 0.9.0 are authored against **`pgmnemo--0.8.3.sql`** (current HEAD). Prior decision documents (DECISION_0.9_SQL.md appendix, DECISION_0.9_RECALL_HYBRID.md appendix) cite line numbers from `pgmnemo--0.8.2.sql`. Since 0.8.3 is a docs-only patch with byte-identical SQL, the line references remain valid; however the implementor MUST confirm each hunk against the 0.8.3 flat file before writing the migration, not the 0.8.2 file.

---

## 3. DO-NOT Scope (hard boundary)

| Excluded item | Reason |
|---------------|--------|
| Per-type dispatch in `navigate_locate` (#5) | Gated on G1 (content_type coverage ≥50%, ≥3 types). G1 not met. |
| Typed `navigate_expand` deref (#6) | Same G1 gate. |
| Auto-graph / rich relation-path | G3 density = 0.0 (measured 2026-06-05). Gate not met. |
| Vision-pixel embedding | Breaks zero-egress constraint. |
| `navigate_locate` O(n) two-CTE split | Deferred 0.9.1. `LIMIT 200` on `final_ranked` provides adequate mitigation; latency acceptable under current corpus size. |
| Any change to `pgmnemo.mem_edge`, `pgmnemo.agent_lesson` PK/FK | Not required by any 0.9 item. |

---

## 4. Items #1 and #2 — Body-Only Bug Fixes

These items have **no signature change and no DDL change**. The migration uses `CREATE OR REPLACE FUNCTION` without any prerequisite `DROP`. Existing callers are unaffected.

### #1 — navigate_locate budget counter

**Bug:** Line 4119 of `pgmnemo--0.8.3.sql` accumulates `length(al.lesson_text)` in the budget window, but line 4274 returns `left(al.lesson_text, 50)`. Budget fills ~5× too fast; `tokens_consumed` overstates by ~5× in character count.

**Fix (1 line):**
```diff
-            length(al.lesson_text)                          AS text_len,
+            LEAST(length(al.lesson_text), 50)               AS text_len,
```

**Expected effect:** `navigate_locate(budget=2000)` returns ~40 rows (up from ~8); `tokens_consumed` ≈ 2000 (down from ~2183).

**Behavioral note for CHANGELOG:** Callers that calibrated `token_budget_chars` to receive ~8 IDs will receive ~40 after upgrade. Required CHANGELOG entry:

> `navigate_locate` `token_budget_chars` accounting corrected. Budget now counts preview characters delivered (~50 chars/row). Callers will receive ~5× more IDs per equivalent budget after upgrade. Reduce `token_budget_chars` proportionally to restore prior result counts if needed.

### #2 — NULL-embedding ≠ ghost at ingest

**Bug:** `ingest()` treats a NULL-embedding row as a duplicate-ghost candidate, skipping creation. Rows without embeddings (e.g., initial sync before async embedding) are silently dropped.

**Fix:** Additive logic in `ingest()` body. No signature change, no DDL. Exact patch TBD by implementor; must be included in 0.9.0 migration as a `CREATE OR REPLACE FUNCTION pgmnemo.ingest(...)`.

---

## 5. Item #1b — navigate_locate Signature Add (MAIN GATE: signature change)

### 5.1 Decision

**APPROVED.** Add `project_id_filter INT DEFAULT NULL` as the 5th parameter to `pgmnemo.navigate_locate`.

### 5.2 Rationale

`recall_hybrid` has had `project_id_filter` since v0.4.0 (lines 4912–4913 in the flat install). `navigate_locate` has no equivalent, forcing multi-tenant callers to use `jsonb_filter` on the `metadata` JSONB column — which does NOT reach the dedicated B-tree index on `agent_lesson.project_id` (`pgmnemo_agent_lesson_project_idx`). The Agency bench was blocked because `navigate_locate` searched all ~6k lessons instead of the 300-doc target corpus. This is a parity gap, not a new feature.

### 5.3 Signature diff (against pgmnemo--0.8.3.sql lines 4015–4019)

```diff
 CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
     query_embedding   vector(1024),
     query_text        TEXT,
     token_budget_chars INT              DEFAULT 2000,
-    jsonb_filter      JSONB             DEFAULT NULL
+    jsonb_filter      JSONB             DEFAULT NULL,
+    project_id_filter INT               DEFAULT NULL
 )
```

```diff
 -- WHERE clause addition (after jsonb_filter line, ~line 4139):
           AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
+          AND (project_id_filter IS NULL OR al.project_id = project_id_filter)
```

```diff
 -- COMMENT update (~line 4291):
-COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB) IS
+COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT) IS
     'Token-economy navigation LOCATE (v0.9.0). '
+    'project_id_filter: scopes candidates to a single project (uses B-tree index). '
```

### 5.4 Migration pattern — DROP + CREATE OR REPLACE

Adding a parameter to a PostgreSQL function creates a **new overloaded signature**. `CREATE OR REPLACE FUNCTION` only replaces a function with an **identical parameter list**. If the old 4-arg signature is not dropped first:
- Both `navigate_locate/4` and `navigate_locate/5` will coexist.
- Positional callers passing 4 args will continue to call the old bugged body.
- The fix for #1 (budget counter) will be in `/5` only — the bugged `/4` remains live.

**Required migration pattern:**

```sql
-- Step 1: Drop old 4-arg signature (idempotent, IF EXISTS guards replay)
DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(
    vector, TEXT, INT, JSONB
);

-- Step 2: Create the new 5-arg function (with both #1 and #1b fixes in body)
CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT    DEFAULT 2000,
    jsonb_filter      JSONB   DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL
)
RETURNS TABLE (...)   -- full body from 0.8.3 with #1 + #1b patches applied
...
```

### 5.5 Backward compatibility

Adding a parameter with `DEFAULT NULL` at the end is safe for all existing callers:

| Caller pattern | Effect after migration |
|---------------|----------------------|
| `navigate_locate(embedding, text)` | Resolved to new 5-arg; 3rd–5th params use defaults. ✅ |
| `navigate_locate(embedding, text, 2000)` | Resolved to new 5-arg; 4th–5th params use defaults. ✅ |
| `navigate_locate(embedding, text, 2000, NULL)` | Resolved to new 5-arg; 5th param uses default. ✅ |
| `navigate_locate(embedding, text, 2000, NULL, 9)` | New usage — project-scoped. ✅ |
| Any caller invoking 4-arg by name | Old 4-arg overload is dropped; resolved to 5-arg with default. ✅ |

**Breaking change risk: NONE.** The DROP of the old 4-arg signature removes the overload; the new 5-arg overload with defaults satisfies all existing positional call sites. No dependency on the 4-arg overload exists within the pgmnemo schema.

### 5.6 Index utilization

`pgmnemo_agent_lesson_project_idx` is a B-tree partial index on `agent_lesson.project_id`. PostgreSQL will use it when `project_id_filter IS NOT NULL` (equi-join). When `project_id_filter IS NULL` (the default), the condition short-circuits and no index scan occurs — planner cost is unchanged vs 0.8.3.

---

## 6. Item #3 — Additive Nullable Columns (MAIN GATE: DDL change)

### 6.1 Decision

**APPROVED.** Add three nullable columns to `pgmnemo.agent_lesson`:

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `content_type` | `TEXT` | `NULL` | Content-type tag (e.g., `code`, `prose`, `config`, `log`). Gates per-type dispatch (#5) and typed expand (#6) when G1 passes. |
| `blob_ref` | `TEXT` | `NULL` | Optional external blob reference (URI/path). NULL = inline `lesson_text` only. |
| `doc_ref` | `TEXT` | `NULL` | Optional document reference (URI/path). NULL = standalone lesson. |

### 6.2 DDL

```sql
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS content_type TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS blob_ref     TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS doc_ref      TEXT DEFAULT NULL;

COMMENT ON COLUMN pgmnemo.agent_lesson.content_type IS
    'Content type tag (e.g. code, prose, config, log). '
    'Gates per-type dispatch (#5) and typed expand (#6) when G1 bench passes. '
    'G1: content_type_coverage >= 0.50 AND distinct_types >= 3.';
COMMENT ON COLUMN pgmnemo.agent_lesson.blob_ref IS
    'Optional external blob reference (URI/path). NULL = inline lesson_text only.';
COMMENT ON COLUMN pgmnemo.agent_lesson.doc_ref IS
    'Optional document reference (URI/path). NULL = standalone lesson.';
```

### 6.3 Backward compatibility

`ALTER TABLE ... ADD COLUMN ... DEFAULT NULL` is an additive, online-safe operation in PostgreSQL 14+. All existing rows receive `NULL` for each new column. No existing query is affected: `ADD COLUMN IF NOT EXISTS` makes the migration idempotent (safe to replay on a partially-upgraded DB).

**Breaking change risk: NONE.**

### 6.4 Why these columns ship before the features that use them

`content_type` must be populated by adopters (via `ingest()` calls tagging new lessons) before G1 can be evaluated. Shipping the column before the dispatch logic allows the adoption signal to accumulate in the wild. Features #5 and #6 cannot ship until G1 passes; the column can and should ship now.

`blob_ref` and `doc_ref` are structural placeholders for document-anchored lessons. Including them now avoids a second schema migration when multi-modal capture ships.

---

## 7. Item #4 — recall_hybrid O(n) Fix (BENCHMARK GATE)

### 7.1 Decision

**APPROVED in principle; commit blocked on BENCHMARK C1.**

The fix (FIX-IN-PLACE, Option A from DECISION_0.9_RECALL_HYBRID.md) replaces the single `raw_candidates` CTE with two bounded, index-friendly CTEs (`vec_candidates` using HNSW ORDER BY+LIMIT, `bm25_candidates` using GIN, merged via LEFT JOIN + anti-join UNION ALL). This is a body-only change; function signature is unchanged.

### 7.2 BENCHMARK C1 gate (HOST-executed, ≥2000 rows)

REVIEW_0.9.md §C1 (CRITICAL concern) confirmed no empirical quality numbers exist. The prior synthesis citing Recall@10=90%, Jaccard=1.00 on a "corpus 31337, 600 docs" is rejected as unverified. **Item #4 MUST NOT commit until BENCHMARK C1 passes.**

**Gate definition:**

| Metric | Threshold | Method |
|--------|-----------|--------|
| EXPLAIN plan: HNSW index scan active after fix | Required | `EXPLAIN ANALYZE` shows `Index Scan using pgmnemo_agent_lesson_embedding_idx` |
| p50 latency after fix | < 100 ms | 5× median on ≥2000-row corpus |
| Avg Jaccard vs Python 2-phase (10 queries) | ≥ 0.80 | `PGMNEMO_USE_NATIVE_HYBRID` toggle (REVIEW_0.9 §R4) |
| recall@10 vs LoCoMo benchmark | ≥ 0.55 | `measure_recall_locomo.py` (REVIEW_0.9 §R5) |
| LIMIT formula uses `GREATEST(k*4, _ef_search)` | Required | REVIEW_0.9 §C2 — HNSW arm must not discard ef_search candidates |

**BENCHMARK execution owner:** HOST orchestrator (not an agent node). This is the modified 0.9.0 release fork-flow (§9 below). The orchestrator runs the verification script on the host Postgres, records numbers, and gates the #4 commit. An agent node does not have the latency/isolation context to run a valid corpus benchmark.

**Escape hatch:** If BENCHMARK C1 is not completed before the 0.9.0 release window closes, #4 gates to 0.9.1. Items #1, #1b, #2, #3 are not blocked by #4.

### 7.3 LIMIT formula correction required before commit

Per REVIEW_0.9.md §C2, the draft in DECISION_0.9_RECALL_HYBRID.md uses `LIMIT (k * 4)`. With k=5 and ef_search=100, this would discard 80% of HNSW's internal candidate set. The required formula:

```sql
_fetch_k := GREATEST(k * 4, _ef_search, 40);
-- k=5, ef_search=100 → _fetch_k = 100
-- k=10, ef_search=100 → _fetch_k = 100
-- k=25, ef_search=100 → _fetch_k = 100
-- k=30, ef_search=100 → _fetch_k = 120
```

Both the HNSW arm and BM25 arm use `LIMIT _fetch_k`. `_ef_search` is already in scope (declared at line ~4808 of the flat install).

---

## 8. Migration File Structure

File: **`pgmnemo--0.8.3--0.9.0.sql`**

Required header guard (prevents direct `\i` execution):

```sql
\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.0'" to load this file. \quit
```

**Mandatory section order:**

```sql
-- §A: Header guard
\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.0'" to load this file. \quit

-- §B: #3 Additive columns (DDL before function rewrites — canonical pattern)
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS content_type TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS blob_ref     TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS doc_ref      TEXT DEFAULT NULL;
COMMENT ON COLUMN ... (×3)

-- §C: #1 + #1b navigate_locate — DROP old 4-arg + CREATE OR REPLACE new 5-arg
DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB);
CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT    DEFAULT 2000,
    jsonb_filter      JSONB   DEFAULT NULL,
    project_id_filter INT     DEFAULT NULL
)
-- FULL BODY EMBEDDED (no "copy from 0.8.3" stubs — complete function required for OSS audit)

-- §D: #2 NULL-embedding fix
CREATE OR REPLACE FUNCTION pgmnemo.ingest(...)
-- FULL BODY with NULL-embedding logic

-- §E: #4 recall_hybrid (conditional — include ONLY if BENCHMARK C1 passes)
-- CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(...)
-- FULL BODY with vec_candidates + bm25_candidates two-CTE split
-- LIMIT formula: GREATEST(k * 4, _ef_search, 40) applied to both arms
```

**Completeness requirement (REVIEW_0.9 §C6):** Each `CREATE OR REPLACE FUNCTION` block in the shipping file MUST embed the complete function body. No "copy from 0.8.3" instructions in the shipped migration. This is a hard requirement for OSS release auditability.

---

## 9. Release Fork-Flow for 0.9.0

The standard release fork-flow is modified for 0.9.0 as follows:

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 0.9.0 RELEASE FORK-FLOW                                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  A. Migration authored (SD)                                             │
│     ├── pgmnemo--0.8.3--0.9.0.sql (items #1, #1b, #2, #3)             │
│     └── pgmnemo--0.9.0.sql updated (flat install)                      │
│                                                                         │
│  B. Items #1, #1b, #2, #3 verified (SD + CA sign-off)                  │
│     ├── V1–V5 commands from REVIEW_0.9.md §Pre-Commit                  │
│     ├── CHANGELOG entry for token_budget_chars behavioral change        │
│     └── Full function body present in migration (no stubs)              │
│                                                                         │
│  C. BENCHMARK C1 ← HOST-EXECUTED BY ORCHESTRATOR (not an agent node)   │
│     ├── Corpus: Agency execas ≥2000 rows (execas: 5642 rows)           │
│     ├── R1: EXPLAIN confirms Seq Scan BEFORE fix                        │
│     ├── R3: EXPLAIN confirms Index Scan AFTER fix                       │
│     ├── R4: Avg Jaccard ≥0.80 vs Python 2-phase (10 queries)           │
│     ├── R5: recall@10 ≥0.55 vs LoCoMo benchmark                        │
│     └── R6: p50 latency <100ms at ≥2000 rows                           │
│                                                                         │
│     ┌── C1 PASS ───────────────────────────────────────────────────┐   │
│     │  Item #4 (recall_hybrid) added to migration                  │   │
│     │  Agency workaround retirement queued (1 commit, ~50 LOC)     │   │
│     └──────────────────────────────────────────────────────────────┘   │
│     ┌── C1 FAIL / TIMEOUT ─────────────────────────────────────────┐   │
│     │  #4 gates to 0.9.1                                           │   │
│     │  0.9.0 ships with #1 + #1b + #2 + #3 only                   │   │
│     └──────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  D. release_decision ← FOUNDER GATE (not automated)                    │
│     ├── Reviews BENCHMARK C1 output (or confirms #4 gated to 0.9.1)   │
│     ├── Reviews CHANGELOG entry                                         │
│     └── Approves public commit on release fork                          │
│                                                                         │
│  E. public-OSS push ← FOUNDER GATE                                      │
│     ├── git tag v0.9.0 on release fork                                 │
│     ├── GitHub release with migration notes                             │
│     └── Docker Hub push (NEVER touch main branch)                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Key modifications vs prior releases:**

1. **BENCHMARK C1 is HOST-EXECUTED by the orchestrator.** An agent node cannot provide the latency and isolation guarantees needed for a valid corpus benchmark. The orchestrator runs R1–R6 directly against the Agency execas Postgres instance and records output as a structured artifact before release_decision is reached.

2. **release_decision is a FOUNDER GATE.** No automated merge of the release fork to main. The Founder reviews BENCHMARK C1 output and CHANGELOG before approving.

3. **public-OSS push is a FOUNDER GATE.** The git tag and Docker Hub push require explicit Founder action. This is made explicit because the 0.9.0 token-economy behavioral change (#1 fix) will be visible to OSS adopters.

4. **Patches re-anchored to 0.8.3.** All diff hunks and line number references in implementation tickets MUST reference `pgmnemo--0.8.3.sql` (current HEAD), not `pgmnemo--0.8.2.sql`. The 0.8.3 flat file is byte-identical to 0.8.2's SQL; existing line references remain valid, but implementor must confirm before committing.

5. **`benchmarks/*` files are pre-existing uncommitted edits.** The migration work MUST NOT stage, amend, or entangle any file under `benchmarks/`. These edits exist independently of 0.9.0 scope and must not appear in the 0.9.0 release commit.

---

## 10. Backward Compatibility Summary

| Change | Backward-compatible? | Evidence |
|--------|---------------------|----------|
| `LEAST(length, 50)` in `navigate_locate` body | **Behavioral change (bug fix)** — output volume increases ~5×. CHANGELOG required. | Budget counted wrong vs delivered payload; fix is correct. |
| `project_id_filter INT DEFAULT NULL` (5th param) | **Compatible.** All existing positional callers unaffected. | PostgreSQL resolves 4-arg calls to new 5-arg with default. §5.5. |
| `DROP FUNCTION navigate_locate(vector, TEXT, INT, JSONB)` | **Safe.** Old overload removed; only new 5-arg overload survives. | No schema dependency on 4-arg overload within pgmnemo. |
| `ADD COLUMN IF NOT EXISTS content_type TEXT DEFAULT NULL` | **Additive, non-breaking.** All existing rows receive NULL. | ALTER TABLE ADD COLUMN DEFAULT NULL is instantaneous in PG14+ (no table rewrite). |
| `ADD COLUMN IF NOT EXISTS blob_ref TEXT DEFAULT NULL` | Same as above. | Same. |
| `ADD COLUMN IF NOT EXISTS doc_ref TEXT DEFAULT NULL` | Same as above. | Same. |
| `recall_hybrid` two-CTE rewrite (if #4 ships) | **Approximate semantic equivalence.** Same signature; hybrid-sweet-spot docs may shift rank. | BENCHMARK C1 Jaccard ≥0.80 gate quantifies impact. |

---

## 11. Rollback Path

| Scenario | Rollback |
|----------|---------|
| Post-migration rollback (#3 columns) | `ALTER TABLE pgmnemo.agent_lesson DROP COLUMN IF EXISTS content_type, DROP COLUMN IF EXISTS blob_ref, DROP COLUMN IF EXISTS doc_ref;` — safe while no application code reads these columns (none in 0.9.0). |
| Post-migration rollback (#1b signature) | `DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT); CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(...)` — restore 4-arg body from 0.8.3 flat install. |
| Post-migration rollback (#4 if shipped) | `CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(...)` — restore body from 0.8.3. Signature unchanged; rollback is a single `CREATE OR REPLACE`. |
| Extension version rollback | `ALTER EXTENSION pgmnemo UPDATE TO '0.8.3'` — requires `pgmnemo--0.9.0--0.8.3.sql` downgrade file (must be authored by implementor alongside upgrade file). The `DROP FUNCTION` for old 4-arg `navigate_locate` is irreversible without the downgrade file; implementor must author both upgrade and downgrade. |

---

## 12. Gate Summary

| Gate | Condition | Owner | Blocks |
|------|-----------|-------|--------|
| G1 (Content-Type Activation) | content_type_coverage ≥50% AND distinct_types ≥3 | Adopter corpus | #5, #6 (not 0.9.0) |
| G3 (Graph Density) | edge_density > 0.5 | Agency corpus | Auto-graph (not 0.9.0) |
| BENCHMARK C1 | R1–R6 pass on ≥2000-row corpus | Orchestrator (HOST) | #4 in 0.9.0 |
| release_decision | Founder review of C1 output + CHANGELOG | Founder | OSS commit |
| public-OSS push | Founder gate | Founder | Tag + Docker Hub |

---

## 13. Definition of Done (0.9.0 migration)

- [ ] Migration file `pgmnemo--0.8.3--0.9.0.sql` exists with header guard
- [ ] §C: `DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB)` present
- [ ] §C: `CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(... project_id_filter INT DEFAULT NULL ...)` with full body embedded
- [ ] Body contains `LEAST(length(al.lesson_text), 50) AS text_len` (#1 fix)
- [ ] Body WHERE clause contains `AND (project_id_filter IS NULL OR al.project_id = project_id_filter)` (#1b)
- [ ] `COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT)` updated (5-arg signature in comment)
- [ ] §B: Three `ADD COLUMN IF NOT EXISTS` statements with `DEFAULT NULL` (#3)
- [ ] §D: `ingest()` full body rewrite with NULL-embedding fix (#2)
- [ ] §E: `recall_hybrid` body (only if BENCHMARK C1 passes; else absent — #4 gated to 0.9.1)
- [ ] CHANGELOG entry for `token_budget_chars` behavioral change (REVIEW_0.9 §C3)
- [ ] No "copy from 0.8.3" instructions in shipping file (REVIEW_0.9 §C6)
- [ ] All patches reference `pgmnemo--0.8.3.sql` line numbers (not 0.8.2)
- [ ] `benchmarks/*` files NOT staged in the 0.9.0 commit
- [ ] V1–V5 verification commands from REVIEW_0.9 run and pass
- [ ] BENCHMARK C1 output recorded (if #4 in scope) or escape noted in release notes
- [ ] release_decision logged by Founder before OSS push

---

*ADR-0.9.0 · chief_architect (86) · 2026-06-10*  
*Authority: DECISION_0.9_SQL.md (RATIFIED 2026-06-05) · DECISION_0.9_RECALL_HYBRID.md (FINAL 2026-06-05) · REVIEW_0.9.md (GO-WITH-CONDITIONS 2026-06-05)*
