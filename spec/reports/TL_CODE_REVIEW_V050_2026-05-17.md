# Code Review: pgmnemo v0.5.0 SQL + MCP + Bench Artifacts
**Date:** 2026-05-17  
**Reviewer:** TL  
**Task:** PGMNEMO-260517-1-CODE_REVIEW (#6286)  
**Branch:** agent/dag-PGMNEMO-260517-1-IMPLEMENT-R5R6R10  
**HEAD commits:** ae84bed (v0.5.0 final), 777dace (R5/R6/R10 impl)
**Fix commit:** 62ebd15 (SHIP-FIX-ABCD — all CHANGES_REQUESTED items resolved)

---

## Verdict: APPROVED (post-fix re-review 2026-05-17)

**All must-fix items resolved in commit 62ebd15.**  
C1 fixed: project_id added to MCP ingest INSERT.  
C2 fixed: LEAST(20.0,...) clamp; docs match runtime.
M1 fixed: SQL_REFERENCE column names corrected to source_id/target_id.
B1 (infra): installcheck still infra-blocked (Unix socket); MCP smoke PASS confirmed via TCP.

---

## Checklist Results

### (1) R5 — max_query_text_chars GUC

**File:** `extension/pgmnemo--0.4.1--0.5.0.sql`

| Check | File:Line | Result |
|-------|-----------|--------|
| GUC default = 2000 | :131, :461 | ✅ COALESCE fallback to 2000 in both functions |
| NULL guard idiomatic | :134, :466 | ✅ both functions guard NULL/empty correctly |
| RAISE NOTICE on truncation | :135, :469 | ✅ both emit notices with char counts |
| Disable with 0/negative | :468 `_max_chars > 0` | ✅ |
| Consistency recall_lessons vs ingest | :130-133 vs :461-464 | ✅ FIXED in ae84bed — both use COALESCE(NULLIF(...)::INT, 2000) |

Low: Duplicate `DO $$ PERFORM set_config(...) $$` blocks at lines 70 and 567 both seed the same GUC in the same migration session. The second is dead code. Harmless.

**R5: APPROVED**

---

### (2) R6 — add_edge()

**File:** `extension/pgmnemo--0.4.1--0.5.0.sql:500-601`, `docs/SQL_REFERENCE.md:112-160`

| Check | File:Line | Result |
|-------|-----------|--------|
| ON CONFLICT clause correct | :561, :573, :585 | ✅ matches partial index `uq_mem_edge_active WHERE valid_until IS NULL` |
| Partial index idempotent | :521-523 | ✅ `CREATE UNIQUE INDEX IF NOT EXISTS` |
| Three modes (replace/max/avg) | :555-590 | ✅ all implemented and branched correctly |
| edge_kind auto-derived | :539-547 | ✅ matches §1.1 canonical mapping |
| weight clamped [0.0, 1.0] | :537 | ✅ |
| NULL source/target → FK/NOT NULL violation | 777dace commit note | ✅ correct by schema |
| SQL_REFERENCE.md §1.2 updated | :112-160 | ✅ both 5-param and 6-param documented with examples |

Medium (M1 — shared with schema doc issue): SQL_REFERENCE.md §1.1 (table schema, line 52-54) lists columns as `lesson_a_id` / `lesson_b_id`, but actual schema and `add_edge()` INSERT use `source_id` / `target_id` (confirmed by `recall_lessons()` graph_walk at line 281: `JOIN pgmnemo.mem_edge me ON me.source_id = gw.reached_id`). The idempotent INSERT example in §1.1 at line 95 also references `lesson_a_id`/`lesson_b_id` — that example will fail if copy-pasted. Must be corrected before SHIP.

**R6: APPROVED** pending M1 doc fix

---

### (3) R10 — Drop 4-arg traverse_causal_chain

**File:** `extension/pgmnemo--0.4.1--0.5.0.sql:26`

```sql
DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);
```

| Check | Result |
|-------|--------|
| Safe (IF EXISTS) | ✅ idempotent |
| 5-arg form unchanged | ✅ no DDL touching it |
| No callers of 4-arg in active code | ✅ confirmed in RESEARCH #6255 done_note |

**R10: APPROVED**

---

### (4) H-02 — Stella V5 embedder fix

**File:** `benchmarks/longmemeval/requirements.txt`

| Check | Result |
|-------|--------|
| rope_theta fix correct | ✅ `transformers==4.44.2` pin applied (commit 8f38bdb) |
| No regression in imports | ✅ pin is requirements-scoped; core extension unaffected |
| Bench gate verdict | ❌ RUN_FAILED (no torch, no dataset) — infra-blocked |

Implementation is correct. Bench gate RUN_FAILED (#6271 done_note) is an infra-blocker, not a code defect.

**H-02 IMPL: APPROVED** — bench gate remains infra-blocked/ESCALATED

---

### (5) H-06 — Temporal boost GUC

**File:** `extension/pgmnemo--0.4.1--0.5.0.sql:29-60, 220-226`

| Check | Result |
|-------|--------|
| GUC default 1.0 | ✅ COALESCE fallback to 1.0 |
| Backward-compatible | ✅ effective_γ = 0.05 × 1.0 = 0.05 (unchanged from v0.4.1) |
| Optimal GUC default justified by bench | ❌ — see C2 |

**Critical (C2):** Documentation at line 35 states:

> "H-06 optimal (cell C6): SET pgmnemo.temporal_boost = '10.0' to reach effective_γ ≈ 0.5 with default recency_weight=0.05"

But `recall_lessons()` lines 222-225 clamp temporal_boost to `LEAST(5.0, ...)`. Setting `temporal_boost=10.0` yields clamped value 5.0, so `effective_γ = 0.05 × 5.0 = 0.25`, **not** 0.5 as documented. The clamp ceiling (5.0) directly contradicts the recommended SET value (10.0) and the claimed γ output.

One of these must be corrected:
- **Option A (preferred):** Raise clamp to 20.0 — allows SET=10.0 to produce γ=0.5 as documented
- **Option B:** Change recommended value to SET=5.0 and document max achievable γ=0.25 at default recency_weight

Also: `get_temporal_boost()` helper at line 58 applies the same LEAST(5.0) clamp but is **unused** inside `recall_lessons()` (which reads the GUC inline at line 222). The helper is dead code — either use it in recall_lessons() or delete it.

**H-06: CHANGES_REQUESTED** (C2 must be resolved)

---

### (6) H-07 — Bitemporality

**File:** `extension/pgmnemo--0.4.1--0.5.0.sql:347-434`

| Check | File:Line | Result |
|-------|-----------|--------|
| ADD COLUMN IF NOT EXISTS t_valid_from | :359 | ✅ idempotent |
| ADD COLUMN IF NOT EXISTS t_valid_to | :360 | ✅ idempotent |
| ADD COLUMN IF NOT EXISTS content_hash GENERATED | :363 | ✅ idempotent PG12+ |
| Backfill (1-second window guard) | :380-382 | ✅ safe for migration context |
| Trigger AFTER INSERT FOR EACH ROW | :409-412 | ✅ fires correctly |
| Trigger closes prior by content_hash | :397-405 | ✅ `AND id <> NEW.id` prevents self-close |
| mem_item view: t_valid_to = 'infinity' | :414-416 | ✅ |
| as_of(ts): t_valid_from <= ts < t_valid_to | :427-430 | ✅ correct half-open interval |
| DROP TRIGGER IF EXISTS before CREATE | :408 | ✅ idempotent |

**H-07: APPROVED**

---

### (7) MCP — pyproject.toml, smoke, README

**Files:** `pgmnemo_mcp/pyproject.toml`, `pgmnemo_mcp/server.py`, `pgmnemo_mcp/__main__.py`

| Check | Result |
|-------|--------|
| pyproject.toml deps complete | ✅ mcp>=1.0, psycopg2-binary>=2.9, pydantic>=2.0 |
| --smoke flag works | ✅ `__main__.py:16-45` — connects, calls recall_lessons, exits 0/1 |
| Transport doc (BUG-3 fix) | ✅ docstring at server.py:1-8 clarifies stdio/SSE transport |

**Critical (C1):** `pgmnemo_mcp/server.py:44-47` — the `ingest` MCP tool performs a direct INSERT omitting `project_id`:

```python
INSERT INTO pgmnemo.agent_lesson
    (lesson_text, role, topic, importance, commit_sha, artifact_hash, verified_at)
VALUES (%s, %s, %s, %s, %s, %s, NOW())
```

`project_id` is `NOT NULL` with no default in the schema. This INSERT raises `null value in column "project_id" violates not-null constraint` on every call. **Every MCP ingest fails at runtime.**

Fix — add `project_id` parameter to the tool and INSERT:
```python
# server.py ingest() signature:
project_id: int = 1,
# INSERT columns:
(lesson_text, role, topic, importance, project_id, commit_sha, artifact_hash)
```

**MCP: CHANGES_REQUESTED** (C1 must be fixed)

---

### (8) Upgrade SQL chain idempotency

**File:** `extension/pgmnemo--0.4.1--0.5.0.sql`

| DDL form | Result |
|----------|--------|
| DROP FUNCTION IF EXISTS | ✅ |
| CREATE OR REPLACE FUNCTION | ✅ |
| ADD COLUMN IF NOT EXISTS | ✅ |
| CREATE UNIQUE INDEX IF NOT EXISTS | ✅ |
| CREATE INDEX IF NOT EXISTS | ✅ |
| DROP TRIGGER IF EXISTS before CREATE TRIGGER | ✅ |
| CREATE OR REPLACE VIEW | ✅ |

**Upgrade chain: APPROVED**

---

## Blocked Gate

**B1 (installcheck):** `benchmarks/gate/v0.5.0-installcheck.log` absent. Task #6269 done_note: "INFRA-BLOCKED: 3 consecutive INFRA_FAILURE runs (9669/9670/9671), 56-81 turns each, $4.39 total spent." No `make installcheck` result available. Acceptance criterion "installcheck exits 0" unverified. **Manual execution required before SHIP (#6287).**

---

## Must-Fix Summary

| ID | Severity | Location | Issue |
|----|----------|----------|-------|
| C1 | Critical | `pgmnemo_mcp/server.py:44-47` | Missing `project_id` in MCP ingest INSERT — NOT NULL violation on every call |
| C2 | High | `pgmnemo--0.4.1--0.5.0.sql:35, 222-225` | H-06 docs say SET=10.0 → γ=0.5; clamp LEAST(5.0) means SET=10.0 → γ=0.25 |
| M1 | Medium | `docs/SQL_REFERENCE.md:50-61, 92-98` | §1.1 uses `lesson_a_id`/`lesson_b_id`; schema uses `source_id`/`target_id` |
| B1 | Blocker | `benchmarks/gate/v0.5.0-installcheck.log` | installcheck not run (infra-blocked); must be resolved before SHIP |
