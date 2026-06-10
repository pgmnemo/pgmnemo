# ADR-0.9.0: pgmnemo 0.9.0 Release — Signature Change, Additive Columns, Bug Fixes

**Status:** PROPOSED — awaiting Founder gate before public-OSS push  
**Date:** 2026-06-10  
**Author:** chief_architect (assignee_id=86)  
**Authority inputs:** DECISION_0.9_SQL.md · DECISION_0.9_RECALL_HYBRID.md · REVIEW_0.9.md  
**Applies to:** pgmnemo 0.9.0 (upgrade from 0.8.3; migration file `pgmnemo--0.8.3--0.9.0.sql`)  
**Source anchor:** All diff-line references use `pgmnemo--0.8.3.sql` (flat install). 0.8.3 is a docs-only patch over 0.8.2 — SQL is byte-identical. Line numbers are identical between 0.8.2 and 0.8.3.

---

## 1. Scope

### 1.1 Items included in 0.9.0

| # | Description | Change class | Schema change? | Signature change? |
|---|-------------|-------------|----------------|-------------------|
| **#1** | Fix `navigate_locate` budget counter: `LEAST(length, 50)` | Body-only | No | No |
| **#1b** | Add `project_id_filter INT DEFAULT NULL` to `navigate_locate` | Signature add | No | **Yes — DROP + CREATE OR REPLACE** |
| **#2** | NULL-embedding ≠ ghost at ingest (additive guard in `ingest()`) | Body-only | No | No |
| **#3** | `content_type`, `blob_ref`, `doc_ref` nullable columns on `agent_lesson` | DDL add | **Yes — ALTER TABLE ADD COLUMN** | No |
| **#4** | `recall_hybrid` O(n) → O(k log n) two-CTE rewrite | Body-only | No | No |

### 1.2 Items excluded from 0.9.0 (gate-blocked)

| Item | Gate | Current state |
|------|------|---------------|
| #5 Per-type dispatch in `navigate_locate` | G1: `content_type` coverage ≥50%, ≥3 distinct types | Not met (columns added in #3 but unpopulated) |
| #6 Typed `navigate_expand` deref | G1 (same) | Not met |
| Auto-graph / rich relation-path | G3: `mem_edge` density > 0.5 | Not met (measured 0.0, 2026-06-05) |

### 1.3 Items requiring this ADR

**#1b** and **#3** require an ADR because:
- **#1b** changes the public function signature (DROP required before CREATE OR REPLACE)
- **#3** adds columns to the main `agent_lesson` table (DDL executed at install and upgrade)

**#1, #2, #4** are body-only fixes — no schema change, no signature change. They are noted here for completeness and release traceability, but do not themselves require architectural review.

---

## 2. Context

### 2.1 Current state (0.8.3)

`navigate_locate` signature (4 parameters):
```sql
pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT   DEFAULT 2000,
    jsonb_filter      JSONB  DEFAULT NULL
)
```

`agent_lesson` table has no `content_type`, `blob_ref`, or `doc_ref` columns.

### 2.2 Motivation for #1b

`recall_hybrid` has had `project_id_filter INT DEFAULT NULL` since v0.4.0, routing queries through the B-tree index `pgmnemo_agent_lesson_project_idx`. `navigate_locate` lacks this parameter, creating a parity gap:

- Multi-tenant callers cannot scope `navigate_locate` to a single corpus
- `jsonb_filter` does not reach the `project_id` base column — it filters only on the `metadata` JSONB field, which misses the B-tree index
- Bench blocked: locate searched all ~6k lessons instead of the 300-doc target corpus

### 2.3 Motivation for #3

`content_type` is required by gated items #5 (per-type dispatch) and #6 (typed expand). Adding the nullable columns in 0.9.0 allows adopters to begin populating them; the dispatch logic ships later once G1 passes. `blob_ref` and `doc_ref` enable structured references to external storage without requiring adopters to embed binary content in `lesson_text`.

---

## 3. Decision: #1b Signature Change

### 3.1 The architectural choice

**Add `project_id_filter INT DEFAULT NULL` as the 5th parameter to `navigate_locate`, with DEFAULT NULL.**

Adding a parameter with `DEFAULT NULL` at the end of a function signature is a **non-breaking addition for all existing positional callers** — PostgreSQL resolves a 4-arg call to the new 5-arg function using the default. However, in PostgreSQL, `CREATE OR REPLACE FUNCTION` cannot change the number of parameters on an existing overload. The old 4-arg overload must be dropped first.

### 3.2 Migration pattern

```sql
-- Step 1: Drop the old 4-arg overload (safe — no schema objects depend on this signature)
DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB);

-- Step 2: Create the 5-arg function (complete body with all 0.9.0 changes applied)
CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(
    query_embedding   vector(1024),
    query_text        TEXT,
    token_budget_chars INT   DEFAULT 2000,
    jsonb_filter      JSONB  DEFAULT NULL,
    project_id_filter INT    DEFAULT NULL   -- NEW: scopes to project B-tree index
)
RETURNS TABLE(...) ...
```

### 3.3 Why DROP is safe

PostgreSQL function overloading means a 4-arg and 5-arg version are two distinct catalog entries. There are no pg_depend dependents on the 4-arg signature:

- No views reference it (verified: no view in pgmnemo schema calls `navigate_locate`)
- No other stored functions call it by exact argument count (callers use named or positional 4-arg form, which the new 5-arg function satisfies via the DEFAULT)
- No CHECK constraints, triggers, or domain expressions reference it

`DROP FUNCTION IF EXISTS` (not `DROP FUNCTION`) is used so the migration is idempotent: running against a schema where the old 4-arg function was already dropped (e.g., fresh install) does not error.

### 3.4 Backward-compatibility analysis

| Caller pattern | Compatible after DROP+CREATE? | Evidence |
|----------------|-------------------------------|----------|
| `navigate_locate($1, $2)` (2-arg positional) | ✅ Yes | Defaults fill args 3–5 |
| `navigate_locate($1, $2, $3)` (3-arg positional) | ✅ Yes | Default fills args 4–5 |
| `navigate_locate($1, $2, $3, $4)` (4-arg positional) | ✅ Yes | Default fills arg 5 |
| `navigate_locate($1, $2, $3, $4, $5)` (5-arg, new) | ✅ Yes | Exact match |
| Named-parameter call with `project_id_filter =>` | ✅ Yes | New callers post-0.9.0 |
| `COMMENT ON FUNCTION ... (vector, TEXT, INT, JSONB)` | ❌ Must update | Old 4-arg signature no longer exists |

The `COMMENT ON FUNCTION` in the migration must reference the new 5-arg signature:
```sql
COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT) IS
    'Token-economy navigation LOCATE (v0.9.0). '
    'project_id_filter: scopes candidates to a single project (uses B-tree index). '
    'token_budget_chars counts Unicode code points of preview text delivered (~50/row).';
```

### 3.5 WHERE clause addition

In the `raw_candidates` CTE, after the `jsonb_filter` guard:

```sql
-- Source anchor: pgmnemo--0.8.3.sql line 4139
AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)
AND (project_id_filter IS NULL OR al.project_id = project_id_filter)   -- NEW #1b
```

When `project_id_filter IS NOT NULL`, the planner uses `pgmnemo_agent_lesson_project_idx` (B-tree on `project_id`), limiting the scan to the target corpus.

---

## 4. Decision: #3 Additive Columns

### 4.1 The architectural choice

**Add three nullable columns to `pgmnemo.agent_lesson` using `ALTER TABLE ... ADD COLUMN ... DEFAULT NULL`.**

```sql
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS content_type TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS blob_ref     TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS doc_ref      TEXT DEFAULT NULL;
```

`ADD COLUMN IF NOT EXISTS` makes the DDL idempotent. Running the migration twice does not error.

### 4.2 Column definitions

| Column | Type | Default | Nullable | Purpose |
|--------|------|---------|----------|---------|
| `content_type` | `TEXT` | `NULL` | Yes | Content classification tag (e.g. `code`, `prose`, `config`, `log`). Gates per-type dispatch (#5) and typed expand (#6) when G1 passes. |
| `blob_ref` | `TEXT` | `NULL` | Yes | External blob reference (URI or path). `NULL` = lesson is inline `lesson_text` only. |
| `doc_ref` | `TEXT` | `NULL` | Yes | Document reference (URI or path). `NULL` = standalone lesson with no parent document. |

All three columns are TEXT (not JSONB, not enum) to preserve adopter flexibility and avoid migration churn when content-type vocabulary expands.

### 4.3 Backward-compatibility analysis

`ALTER TABLE ... ADD COLUMN ... DEFAULT NULL` is:

- **Non-locking on PostgreSQL 14+**: A column with a constant `DEFAULT NULL` is added via a catalog-only update (fast-path), without a table rewrite or `ACCESS EXCLUSIVE` lock held for the duration of the write
- **Non-breaking for existing queries**: `SELECT *` queries will return additional columns; `INSERT` statements that do not mention the new columns receive `NULL` automatically
- **Non-breaking for existing indexes**: No index changes; no constraint changes

No existing `pgmnemo` function references `content_type`, `blob_ref`, or `doc_ref` — verified by inspection of `pgmnemo--0.8.3.sql`. The columns are inert until populated.

### 4.4 No indexes added in 0.9.0

Indexes on `content_type` are deferred to the release when #5 ships (post-G1). Adding an index on an unpopulated column in 0.9.0 would be dead cost. The G1 gate query (`WHERE content_type IS NOT NULL`) will use a sequential scan until G1 passes — acceptable given G1 requires ≥50% coverage before #5 is unlocked.

---

## 5. Bug Fixes #1 and #4 (Body-Only)

### 5.1 #1 — navigate_locate budget counter (body-only)

**Change:** In `raw_candidates` CTE, line 4119 of `pgmnemo--0.8.3.sql`:

```sql
-- Before (0.8.3):
length(al.lesson_text) AS text_len

-- After (0.9.0):
LEAST(length(al.lesson_text), 50) AS text_len
```

No signature change. No schema change. `CREATE OR REPLACE` (which replaces the full body) handles this together with #1b.

**Behavioral impact (documented for CHANGELOG):** `navigate_locate(token_budget_chars => 2000)` previously returned ~8 rows (budget exhausted by full-length text counting). After fix: ~40 rows (budget counts ≤50 chars/row, matching the `left(lesson_text, 50)` preview actually delivered). Callers who calibrated `token_budget_chars` to receive ~8 IDs should reduce their budget to ~400 after upgrading.

### 5.2 #4 — recall_hybrid O(n) rewrite (body-only, gated)

**Change:** Replace single `raw_candidates` CTE with two bounded index-scan CTEs (`vec_candidates` + `bm25_candidates`) plus a dedup `all_candidates` UNION. Window functions in `rrf_ranked` then operate over ≤2×`_fetch_k` rows instead of all N active rows.

**Signature:** Unchanged. `recall_hybrid(vector, TEXT, INT, TEXT, INT, DOUBLE PRECISION, DOUBLE PRECISION, INT)` — zero caller impact.

**LIMIT formula (REVIEW_0.9 C2 required fix):**

```sql
_fetch_k := GREATEST(k * 4, _ef_search, 40);
-- HNSW arm: LIMIT _fetch_k  (≥ ef_search=100 by default — does not discard HNSW candidates)
-- BM25 arm:  LIMIT _fetch_k  (same floor, no ef_search relevance for GIN)
```

This addresses REVIEW_0.9 C2: without the `GREATEST(_, _ef_search)` floor, a k=5 call uses `LIMIT 20`, discarding 80 of 100 HNSW candidates when `ef_search=100`.

**Tie-breaker (REVIEW_0.9 C7):** Add secondary sort `, f.id ASC` to final `ORDER BY f.final_score DESC LIMIT k`.

---

## 6. Release Fork-Flow

### 6.1 Modified flow for 0.9.0

```
Items #1 + #1b + #2 + #3   ─── Code-complete ──→  REVIEW gate (this ADR)
                                                           │
                                                           ▼
Item #4 (recall_hybrid)     ─── BENCHMARK C1 ──→  BLOCKED (HOST-exec)
                                                           │
                              ┌────────────────────────────┘
                              │
                    ┌─────────▼──────────┐
                    │  Benchmark PASS?   │
                    │  (≥2000 rows,      │
                    │  Recall@10 ≥0.55,  │
                    │  Jaccard ≥0.80,    │
                    │  p50 < 100ms)      │
                    └──┬──────────────┬──┘
                  YES  │              │  NO
                       ▼              ▼
               #4 ships in      #4 gates to 0.9.1
                  0.9.0             (#1-#3 unblocked)
                       │
                       ▼
          FOUNDER gate: release_decision
                       │
                       ▼
          FOUNDER gate: public-OSS push
```

### 6.2 BENCHMARK execution

Per task directive: **BENCHMARK (#4 C1, ≥2000 rows) is HOST-executed by the orchestrator, not by an agent node.**

Required outputs (REVIEW_0.9 R1–R6):

| Check | Gate |
|-------|------|
| R1: EXPLAIN ANALYZE before fix shows Seq Scan | `Seq Scan on agent_lesson` present, time > 500ms |
| R2: LIMIT formula uses `GREATEST(k*4, _ef_search)` | Code review of migration SQL |
| R3: EXPLAIN ANALYZE after fix shows Index Scan | `Index Scan using pgmnemo_agent_lesson_embedding_idx` present, time < 100ms |
| R4: Jaccard vs Python 2-phase on ≥2000-row corpus | avg Jaccard ≥ 0.80, no individual query < 0.50 |
| R5: Recall@10 vs LoCoMo | ≥ 0.55, delta vs python_2phase < 5pp |
| R6: p50 latency at ≥2000 rows | p50 < 100ms |

The prior "Recall@10=90%, Jaccard=1.00" numbers cited in task 8887 are **not accepted** (REVIEW_0.9 §C1): corpus identifier non-standard, Jaccard=1.00 implausible for approximate-NN, corpus size mismatches production. New measurements required.

### 6.3 Founder gates

1. **release_decision**: Founder reviews this ADR + benchmark results, approves `pgmnemo--0.8.3--0.9.0.sql`, and authorises tagging `v0.9.0`.
2. **public-OSS push**: Founder executes `git push` to the public repository. No agent or orchestrator pushes to main or creates tags.

**Constraint:** Do not touch `benchmarks/*` uncommitted edits. Do not push. Do not touch main branch.

---

## 7. Upgrade Path

### 7.1 Migration file

File: `extension/pgmnemo--0.8.3--0.9.0.sql`

```
pgmnemo--0.8.3--0.9.0.sql execution order:
  1. #3 ALTER TABLE ADD COLUMN (DDL, catalog-only, non-locking)
  2. DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB)
  3. CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(5-arg) — includes #1 + #1b
  4. CREATE OR REPLACE FUNCTION pgmnemo.ingest(...) — includes #2
  5. CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(...) — includes #4, IF benchmark passes
  6. COMMENT ON COLUMN / COMMENT ON FUNCTION updates
```

Items 1, 2+3, 4 are independent and can be in any order relative to each other. The only ordering constraint: `DROP` before `CREATE OR REPLACE` for `navigate_locate`.

### 7.2 Flat install file

File: `extension/pgmnemo--0.9.0.sql` — regenerated from 0.8.3 flat install with all 0.9.0 changes applied. This is the file used for fresh installs (`CREATE EXTENSION pgmnemo VERSION '0.9.0'`). The implementor must apply all diff hunks to the 0.8.3 flat file and verify correctness.

### 7.3 Source anchor (re-anchor from 0.8.2 to 0.8.3 refs)

Prior decision documents (DECISION_0.9_SQL.md, DECISION_0.9_RECALL_HYBRID.md) reference `pgmnemo--0.8.2.sql` line numbers. Since 0.8.3 is a docs-only patch with SQL byte-identical to 0.8.2, all line numbers are valid against `pgmnemo--0.8.3.sql`. The migration file is anchored to **0.8.3** (not 0.8.2) in:
- The migration filename: `pgmnemo--0.8.3--0.9.0.sql`
- The `\echo` guard: `ALTER EXTENSION pgmnemo UPDATE TO '0.9.0'`
- The `default_version` entry in `pgmnemo.control`

### 7.4 ALTER EXTENSION path

For existing installations:
```sql
ALTER EXTENSION pgmnemo UPDATE TO '0.9.0';
```

This loads `pgmnemo--0.8.3--0.9.0.sql` via the extension update path. PostgreSQL verifies that the installed version is 0.8.3 before applying. If an older version is installed (e.g. 0.8.2), the user must first run `ALTER EXTENSION pgmnemo UPDATE TO '0.8.3'`.

### 7.5 Rollback

| Change | Rollback procedure |
|--------|-------------------|
| #3 columns | `ALTER TABLE pgmnemo.agent_lesson DROP COLUMN IF EXISTS content_type, DROP COLUMN IF EXISTS blob_ref, DROP COLUMN IF EXISTS doc_ref;` |
| #1b signature | `DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT);` then restore 4-arg function from 0.8.3 source |
| #1 body fix | `CREATE OR REPLACE` with 0.8.3 body (restore from source) |
| #2 body fix | `CREATE OR REPLACE` with 0.8.3 body |
| #4 body fix | `CREATE OR REPLACE` with 0.8.3 body |

No migration removes data. All DDL changes are additive. Rollback path exists for every change.

---

## 8. Verification Checklist

### Schema / DDL review

- [ ] `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` present for all three columns
- [ ] All three columns are `TEXT DEFAULT NULL` (not enum, not NOT NULL)
- [ ] `COMMENT ON COLUMN` entries present for all three new columns
- [ ] `DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB)` before CREATE OR REPLACE
- [ ] New 5-arg signature has `project_id_filter INT DEFAULT NULL` as 5th parameter
- [ ] `COMMENT ON FUNCTION` references the new `(vector, TEXT, INT, JSONB, INT)` signature
- [ ] Migration has `\echo` guard at top (`ALTER EXTENSION pgmnemo UPDATE TO '0.9.0'`)
- [ ] `pgmnemo.control` updated: `default_version = '0.9.0'`, from_version entry added

### Backward compatibility

- [ ] 4-arg positional callers return correct results after `DROP + CREATE OR REPLACE` (test V5 below)
- [ ] `project_id_filter IS NULL` path is functionally equivalent to 0.8.3 (no filter applied)
- [ ] `project_id_filter IS NOT NULL` path uses B-tree index (EXPLAIN confirms)

### Pre-commit verification (items #1, #1b, #2, #3)

These are runnable now — no benchmark blocker:

```bash
# V1. Confirm bug lines in source
grep -n "text_len\|left.*lesson_text" /external-repos/pgmnemo/extension/pgmnemo--0.8.3.sql | grep "4[12][0-9][0-9]\:"

# V3. Confirm navigate_locate 4-arg signature (before migration)
psql $EXECAS_DB_URL -c "\df pgmnemo.navigate_locate"
# Expected: 4 parameters

# V4. Confirm B-tree project_id index
psql $EXECAS_DB_URL -c "SELECT indexname FROM pg_indexes WHERE schemaname='pgmnemo' AND tablename='agent_lesson' AND indexdef ILIKE '%project_id%';"
# Expected: pgmnemo_agent_lesson_project_idx

# V5. Backward-compat test (after applying migration)
psql $EXECAS_DB_URL -c "SELECT id FROM pgmnemo.navigate_locate(NULL::vector(1024),'test',100) LIMIT 1;"
psql $EXECAS_DB_URL -c "SELECT id FROM pgmnemo.navigate_locate(NULL::vector(1024),'test',100,NULL,9) LIMIT 1;"
# Both must return without error
```

### Benchmark gate (item #4 — HOST-executed by orchestrator)

Run R1–R6 from REVIEW_0.9.md §Pre-Commit Verification Commands (Item #4 block) on a corpus of ≥2000 rows. Record output. Gate: R4 avg Jaccard ≥ 0.80, R5 Recall@10 ≥ 0.55 with delta < 5pp vs Python 2-phase, R6 p50 < 100ms. If any gate fails, #4 gates to 0.9.1.

### CHANGELOG (required per REVIEW_0.9 C3)

Entry required before any commit:

> **navigate_locate `token_budget_chars` accounting corrected (v0.9.0).** Budget now counts preview characters delivered (~50 chars/row). Callers will receive approximately 5× more candidate IDs per equivalent budget after upgrading from 0.8.x. To preserve prior result counts, reduce `token_budget_chars` proportionally (e.g. `2000 → 400`).

---

## 9. Decision Record

| Question | Decision | Rationale |
|----------|----------|-----------|
| Can `CREATE OR REPLACE` add a new parameter? | **No — DROP old signature first.** `DROP FUNCTION IF EXISTS (vector, TEXT, INT, JSONB)` required before CREATE OR REPLACE with 5-arg signature. | PostgreSQL catalog: function overloads are distinct. CREATE OR REPLACE can only replace same-signature overload. |
| Is the DROP safe (no dependents)? | **Yes.** No views, stored functions, constraints, or triggers depend on the 4-arg overload. | Verified by inspection of pgmnemo--0.8.3.sql. |
| Are existing callers unaffected? | **Yes.** 4-arg positional callers route to the new 5-arg function via DEFAULT on 5th param. | PostgreSQL DEFAULT resolution for positional calls. |
| ADD COLUMN safe without lock? | **Yes.** `DEFAULT NULL` column addition is catalog-only on PostgreSQL 14+ (fast-path, no table rewrite). | PostgreSQL ALTER TABLE locking documentation. |
| Why TEXT not enum for content_type? | **TEXT.** Vocabulary is undefined until G1 passes. Enum changes require DDL migration per new value. TEXT is lower churn for an evolving vocabulary. | Minimum blast radius principle. |
| Should content_type have an index in 0.9.0? | **No.** Column will be NULL on all rows until adopters populate it. Index on unpopulated column is dead cost. Add when #5 ships (post-G1). | Gate-based feature development. |
| #4 ships in 0.9.0 or 0.9.1? | **Conditional.** Ships in 0.9.0 if HOST benchmark R1–R6 pass. Gates to 0.9.1 if any gate fails. #1–#3 are not blocked by #4. | DECISION_0.9_SQL.md §D item 4; REVIEW_0.9.md §C1. |
| Who executes benchmark? | **Orchestrator, HOST-side.** Not an agent node. | Task directive. |
| Who gates release and push? | **Founder.** release_decision and public-OSS push are Founder gates. | Task directive. |

---

## 10. Rejected Alternatives

| Alternative | Rejected because |
|-------------|-----------------|
| `CREATE OR REPLACE` with 5-arg without `DROP` | Fails with `ERROR: cannot change return type of existing function` (PostgreSQL rejects changing arg count via OR REPLACE on different overload). |
| Add `project_id_filter` as a GUC (`pgmnemo.project_id_filter`) | GUCs are session-global. Concurrent callers (different tenants) would corrupt each other's filter state. Not safe for multi-tenant use. |
| Add `content_type` as `TEXT NOT NULL DEFAULT 'prose'` | Forces a default classification onto all existing lessons, polluting the coverage metric used by G1 gate (coverage ≥50% would be trivially satisfied by the default, not by actual tagging). |
| Add `content_type` as a PostgreSQL ENUM | Each new vocabulary term requires a DDL migration. The vocabulary is unknown pre-G1. TEXT avoids this churn. |
| Bundle #4 unconditionally in 0.9.0 | REVIEW_0.9 C1 CRITICAL: quality regression risk unquantified. No Recall@10 or Jaccard numbers measured. Prior numbers rejected as unverifiable (REVIEW_0.9 §Note). |
| Push MCPRT before #1 | #1 bug makes navigate_locate token economy incorrect. MCPRT wrapping a broken function exposes the defect to all MCP callers. |

---

*Authority: DECISION_0.9_SQL.md (ratified 2026-06-05) · DECISION_0.9_RECALL_HYBRID.md (final 2026-06-05) · REVIEW_0.9.md (adversarial pass, 2026-06-05). Founder review required before public-OSS push.*
