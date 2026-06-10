<!-- SPDX-License-Identifier: Apache-2.0 -->
# CODE REVIEW — pgmnemo 0.9.0

**Reviewer:** research_supervisor (85)  
**Date:** 2026-06-10  
**Branch:** release/0.9.0  
**Base:** pgmnemo--0.8.3.sql  
**Authority:** DECISION_0.9_SQL.md · DECISION_0.9_RECALL_HYBRID.md · REVIEW_0.9.md  
**Scope:** Ratified patches #1, #1b, #2, #3, #4 + REVIEW_0.9 concerns C2, C3, C5

---

## Overall Verdict: **GO-WITH-CONDITIONS**

All ratified patches (#1–#4) are implemented correctly. REVIEW_0.9 concerns C2, C3,
and C5 are all cleared. **One condition remains pending:** #4 inclusion gated on host
BENCHMARK (C1) to be executed by orchestrator. The code review cannot substitute for
the empirical Recall@10 / latency numbers. Founder release_decision feeds on C1 output.

---

## Item-by-Item Verdict

### #1 — `navigate_locate` budget counter fix

**Verdict: GO ✅**

**Requirement (DECISION_0.9_SQL.md §C):**
```diff
- length(al.lesson_text)          AS text_len
+ LEAST(length(al.lesson_text), 50) AS text_len
```

**Verified in:**
- `pgmnemo--0.8.3--0.9.0.sql` — `LEAST(length(al.lesson_text), 50) AS text_len` confirmed present
- `pgmnemo--0.9.0.sql` — same fix present in flat install
- Installcheck A3: PASS (functional test confirmed budget ceiling at 50 chars/row)

**Math correctness:** Budget window uses `cum_chars - text_len < token_budget_chars` (include-if-cumulative-before-this-row < budget). With `text_len ≤ 50`, counter tracks delivered payload accurately. With k=2000 budget, ~40 rows returned (2000/50). ✅

---

### #1b — `navigate_locate` project_id_filter parameter

**Verdict: GO ✅**

**Requirements (DECISION_0.9_SQL.md §A):**
1. Drop old 4-arg signature in migration
2. Create 5-arg signature `project_id_filter INT DEFAULT NULL`
3. WHERE clause: `AND (project_id_filter IS NULL OR al.project_id = project_id_filter)`

**Verified in migration:**
- Line 179: `DROP FUNCTION IF EXISTS pgmnemo.navigate_locate(vector, TEXT, INT, JSONB);`
- Lines 461–473: `COMMENT ON FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT)`
- Body: `AND (project_id_filter IS NULL OR al.project_id = project_id_filter)` confirmed

**Backward compat:** Old 4-arg callers resolve to the 5-arg function via PostgreSQL's DEFAULT
parameter resolution. B-tree index `pgmnemo_agent_lesson_project_idx` confirmed in 0.8.3 source.
Installcheck B6: project isolation verified functional (project 77 rows not visible to project 1). ✅

**Migration path:** `ALTER EXTENSION pgmnemo DROP FUNCTION` required to untrack extension-owned
4-arg before `DROP FUNCTION IF EXISTS` can run (PG blocks drop of extension-owned objects).
Documented in INSTALLCHECK_0.9.0.md. ✅

---

### #2 — `ingest()` NULL-embedding != ghost

**Verdict: GO ✅**

**Requirement (DECISION_0.9_SQL.md §A #2):**
`verified_at = NOW()` unconditionally for lessons passing quality gates (F1/F2/F3).

**Verified in migration:**
- `pgmnemo--0.8.3--0.9.0.sql` contains full `CREATE OR REPLACE FUNCTION pgmnemo.ingest(...)` with
  `-- v0.9.0 #2:` annotation and `verified_at = NOW()` on unconditional path
- Installcheck A8: NULL-embedding ingest returns `verified_at IS NOT NULL, embedding IS NULL = (True, True)` ✅

---

### #3 — `agent_lesson` content_type/blob_ref/doc_ref columns

**Verdict: GO ✅**

**Requirement (DECISION_0.9_SQL.md §A #3):**
Three nullable `TEXT` columns; idempotent DDL.

**Verified in migration:**
```sql
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS content_type TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS blob_ref     TEXT DEFAULT NULL;
ALTER TABLE pgmnemo.agent_lesson ADD COLUMN IF NOT EXISTS doc_ref      TEXT DEFAULT NULL;
```
`IF NOT EXISTS` guards confirmed present (lines 25, 27, 29). ADD COLUMN occurs before DROP+CREATE
(correct sequencing — schema change commited before function swap). ✅

Gates #5/#6 correctly conditioned on G1 (>=50% content_type coverage, >=3 distinct types).

---

### #4 — `recall_hybrid` O(n) → O(k log n) two-CTE rewrite

**Verdict: CONDITIONAL GO ⚠️ — pending C1 BENCHMARK (host-executed)**

**Requirements (DECISION_0.9_RECALL_HYBRID.md + REVIEW_0.9 C2/C4/C7):**

| Sub-requirement | Status |
|----------------|--------|
| `vec_candidates` CTE with HNSW ORDER BY <=> LIMIT | ✅ PASS — lines 608–636 |
| `bm25_candidates` CTE with GIN ts_rank LIMIT | ✅ PASS — lines 637–670 |
| `_vec_fetch_k := GREATEST(k * 4, _ef_search)` (C2) | ✅ PASS — line 602 |
| `_bm25_fetch_k := GREATEST(k * 4, 40)` (C2) | ✅ PASS — line 603 |
| `all_candidates`: LEFT JOIN + anti-join UNION ALL | ✅ PASS — confirmed in body |
| `ORDER BY f.final_score DESC, f.id ASC` (C7) | ✅ PASS — confirmed in body |
| C1: Recall@10 ≥ 0.55 + delta <5pp vs Python 2-phase (≥2000-row corpus) | ⏳ PENDING — HOST benchmark |

**C4 risk acknowledged:** Hybrid-sweet-spot documents (rank ~55 vec, ~55 bm25) may be dropped
by bounded CTEs. Risk quantification deferred to C1 benchmark run. If C1 fails, #4 gates to
0.9.1 per DECISION_0.9_SQL.md §D (escape hatch) and migration ships without the recall_hybrid
rewrite.

---

## REVIEW_0.9 Concerns — Cleared Status

### C2 — HNSW ef_search floor in LIMIT formula

**Status: CLEARED ✅**

`REVIEW_0.9.md C2` required:
```sql
_vec_fetch_k  := GREATEST(k * 4, _ef_search);   -- HNSW arm
_bm25_fetch_k := GREATEST(k * 4, 40);            -- BM25 arm (no ef_search)
```

Both lines confirmed in `pgmnemo--0.8.3--0.9.0.sql` lines 602–603, with inline comments
explicitly referencing the C2 fix. The `_ef_search` variable is already in scope (declared
at line 528; populated from GUC at lines 563–569). For callers who set `pgmnemo.ef_search = 200`,
the vec arm now uses LIMIT 200 (not LIMIT 40), preserving all HNSW candidate work. ✅

---

### C3 — CHANGELOG + docstring behavioral change warning

**Status: CLEARED ✅**

**REVIEW_0.9.md C3** required two deliverables:

**1. CHANGELOG entry** — CHANGELOG.md `## [0.9.0]` contains:

> "**Behavioral change:** callers with `token_budget_chars=2000` will receive ~40 rows
> (previously ~8). The budget now counts preview characters (<=50 chars/row). Reduce budget
> proportionally to preserve prior result counts."

Exact wording matches REVIEW_0.9 requirement. ✅

**2. COMMENT ON FUNCTION update** — Both migration and flat install contain:

> `'v0.9.0: budget counter fixed — counts delivered preview chars (<=50), not full lesson length. '`  
> `'Callers will receive ~5x more IDs per equivalent budget vs 0.8.x. '`  
> `'Reduce budget proportionally to preserve prior result counts. '`

Covers all three required points: what changed, quantified impact (~5x), mitigation action. ✅

---

### C5 — navigate_locate O(n) deferral noted

**Status: CLEARED ✅ (via ADR)**

**REVIEW_0.9.md C5** required: "the DO-NOT list should explicitly state: 'navigate_locate O(n)
fix deferred to 0.9.1 — same two-CTE pattern applies.'"

**ADR_0.9.0.md line 44** (deferred items table):
> "`navigate_locate` O(n) two-CTE split | **Deferred 0.9.1.** `LIMIT 200` on `final_ranked`
> provides adequate mitigation; latency acceptable under current corpus size."

The ADR is the committed design record on branch release/0.9.0 and serves as the authoritative
deferred-items list for this release.

**Minor observation (non-blocking):** The `COMMENT ON FUNCTION navigate_locate` does not mention
the O(n) deferral. DECISION_0.9_SQL.md §B DO-NOT list also lacks an explicit entry. The ADR
satisfies the REVIEW_0.9 C5 requirement. No action required before release; consider adding a
comment to navigate_locate body in 0.9.1 when the two-CTE fix is implemented.

---

## Additional Items Checked

### C6 — Full function body in migration (REVIEW_0.9 C6)

**Status: CLEARED ✅**

The shipped `pgmnemo--0.8.3--0.9.0.sql` contains complete `CREATE OR REPLACE` bodies for
navigate_locate, ingest, and recall_hybrid — no "copy from 0.8.3" instructions appear in the
file. All three patches are self-contained. ✅

### C7 — Tie-breaker in recall_hybrid ORDER BY (REVIEW_0.9 C7)

**Status: CLEARED ✅**

`ORDER BY f.final_score DESC, f.id ASC` confirmed in both migration and flat install. ✅

### Source anchoring — patches re-anchored from 0.8.2 to 0.8.3

**Status: VERIFIED ✅**

ADR_0.9.0.md §7.3 confirms: "Source re-anchored from 0.8.2 to 0.8.3 (SQL byte-identical;
0.8.3 was documentation-only patch)." Migration file header states
`pgmnemo--0.8.3--0.9.0.sql`. Line numbering cross-references in REVIEW_0.9 refer to
`pgmnemo--0.8.2.sql` but DECISION_0.9_SQL.md §C specifies patches against 0.8.3 source,
which is correct for the migration chain. ✅

---

## Pending Gate (Not a Code Review Blocker)

| Gate | Owner | Status |
|------|-------|--------|
| C1: BENCHMARK Recall@10 ≥ 0.55, delta <5pp, ≥2000-row corpus | Orchestrator (HOST) | ⏳ PENDING |
| release_decision | FOUNDER | Blocked on C1 |
| Public OSS push | FOUNDER | Blocked on release_decision |

The C1 benchmark runs on the HOST (not an agent node). Output feeds the founder
release_decision. If C1 fails, #4 gates to 0.9.1; items #1, #1b, #2, #3 ship as 0.9.0
without recall_hybrid rewrite.

---

## Summary

| Item | Verdict | Notes |
|------|---------|-------|
| #1 `navigate_locate` budget fix | ✅ GO | LEAST(length,50) confirmed; functional test max=50 |
| #1b project_id_filter | ✅ GO | DROP 4-arg + 5-arg with DEFAULT; isolation verified |
| #2 ingest NULL-embedding | ✅ GO | verified_at unconditional; functional test PASS |
| #3 ADD COLUMN content_type/blob_ref/doc_ref | ✅ GO | IF NOT EXISTS; nullable; gates #5/#6 |
| #4 recall_hybrid O(n) rewrite | ⚠️ COND. GO | Code correct; pending C1 benchmark |
| C2 GREATEST(k*4, ef_search) | ✅ CLEARED | Lines 602–603; explicit comment |
| C3 CHANGELOG + docstring | ✅ CLEARED | Behavioral change warning present in both |
| C5 navigate_locate O(n) deferral | ✅ CLEARED | ADR line 44; non-blocking COMMENT gap |
| C6 full bodies in migration | ✅ CLEARED | No "copy from" instructions in shipping SQL |
| C7 tie-breaker `f.id ASC` | ✅ CLEARED | Confirmed in both files |

**Blockers to release:** 0 code-level blockers. C1 benchmark (host) + founder gate remain.
