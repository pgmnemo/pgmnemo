# QA REPORT — pgmnemo 0.8.0 (SWDEV-260603-1)

**Date**: 2026-06-03
**QA Engineer**: Memory Systems Agent
**Branch**: agent/dag-SWDEV-260603-1-SHIP
**Migration commit**: 5973cdf (implement: pgmnemo 0.8.0)
**Test file**: tests/sql/test_v080.sql (17 tests)

---

## Verdict: **PASS — 17/17 tests pass**

All new functions and schema additions behave as specified. Zero failures. Zero execution errors.

---

## Test Environment

| Item | Value |
|------|-------|
| PostgreSQL | 16.x (container: postgres:5432) |
| pgvector | 0.8.2 |
| pgmnemo baseline | 0.7.1 |
| Migration applied | pgmnemo--0.7.2--0.8.0.sql (15 statements, 0 errors) |
| Test runner | Python 3 + psycopg2 (psql unavailable in this environment) |
| Database | prod_corpus |

**Migration method**: SQL file executed via psycopg2 with dollar-quote-aware statement splitter.  
All 15 migration statements succeeded (2× ALTER TABLE, 1× UPDATE backfill, 2× COMMENT ON COLUMN, 5× CREATE OR REPLACE FUNCTION, 5× COMMENT ON FUNCTION).

---

## Test Results

| Test | Description | Result | Evidence |
|------|-------------|--------|----------|
| T1 | source_type default + CHECK constraint | **PASS** | `t1_source_type_default = TRUE`; NOTICE: CHECK constraint rejects invalid source_type |
| T2 | embedding_at NULL before reembed() | **PASS** | `t2_embedding_at_null_before_reembed = TRUE` |
| T3 | navigate_locate — column shape | **PASS** | `t3_has_id=TRUE`, `t3_score_nonneg=TRUE`, `t3_tokens_positive=TRUE`, `t3_has_nav_path=TRUE` |
| T4 | navigate_locate — token budget cap | **PASS** | `t4_at_least_one_result=TRUE`, `t4_tokens_within_budget_plus_one=TRUE`, `t4_first_tokens_positive=TRUE` |
| T5 | navigate_locate — JSONB pushdown | **PASS** | `t5_has_results=TRUE`, `t5_all_results_match_filter=TRUE` |
| T6 | navigate_locate — navigation_path without filter | **PASS** | `t6_nav_path_is_signal_based=TRUE` (vector or bm25) |
| T7 | navigate_locate — navigation_path = jsonb_gate | **PASS** | `t7_nav_path_jsonb_gate=TRUE` |
| T8 | navigate_expand — returns lesson content | **PASS** | `t8_has_content=TRUE`, `t8_content_nonempty=TRUE`, `t8_nav_path_content=TRUE` |
| T9 | navigate_expand — expand_fields projection | **PASS** | `t9_has_expand_detail=TRUE`, `t9_has_env_key=TRUE`, `t9_has_priority_key=TRUE` |
| T10 | navigate_expand — graph expansion (causal edge) | **PASS** | `t10_two_rows_returned=TRUE`, `t10_has_content_row=TRUE`, `t10_has_graph_expand_row=TRUE` |
| T11a | reembed() preserves lesson_text | **PASS** | NOTICE: reembed() preserves lesson_text |
| T11b | reembed() sets embedding_at | **PASS** | NOTICE: reembed() sets embedding_at |
| T12 | reembed_batch() returns correct count | **PASS** | NOTICE: reembed_batch() returned 2 |
| T13a | recompute_content() preserves id | **PASS** | NOTICE: recompute_content() preserves id |
| T13b | recompute_content() updates lesson_text | **PASS** | NOTICE: recompute_content() updated lesson_text |
| T14 | recompute_content() bitemporal-safe (no new row) | **PASS** | NOTICE: did not create new row (cnt=1) |
| T15 | reembed() rejects wrong-dim vector | **PASS** | NOTICE: reembed() rejects wrong-dim vector |
| T16 | reembed_batch() rejects mismatched array lengths | **PASS** | NOTICE: reembed_batch() rejects mismatched array lengths |
| T17 | recompute_content() rejects empty text | **PASS** | NOTICE: recompute_content() rejects empty text |

**Total**: 17/17 PASS · 0 FAIL · 0 execution errors

---

## Migration Verification

```
Stmt [0]  OK: ALTER TABLE ... ADD COLUMN IF NOT EXISTS source_type TEXT CHECK(...)
Stmt [1]  OK: ALTER TABLE ... ADD COLUMN IF NOT EXISTS embedding_at TIMESTAMPTZ
Stmt [2]  OK: UPDATE agent_lesson SET embedding_at = updated_at WHERE embedding IS NOT NULL AND embedding_at IS NULL
Stmt [3]  OK: COMMENT ON COLUMN agent_lesson.source_type
Stmt [4]  OK: COMMENT ON COLUMN agent_lesson.embedding_at
Stmt [5]  OK: CREATE OR REPLACE FUNCTION pgmnemo.navigate_locate(...)
Stmt [6]  OK: COMMENT ON FUNCTION navigate_locate
Stmt [7]  OK: CREATE OR REPLACE FUNCTION pgmnemo.navigate_expand(...)
Stmt [8]  OK: COMMENT ON FUNCTION navigate_expand
Stmt [9]  OK: CREATE OR REPLACE FUNCTION pgmnemo.reembed(...)
Stmt [10] OK: COMMENT ON FUNCTION reembed
Stmt [11] OK: CREATE OR REPLACE FUNCTION pgmnemo.reembed_batch(...)
Stmt [12] OK: COMMENT ON FUNCTION reembed_batch
Stmt [13] OK: CREATE OR REPLACE FUNCTION pgmnemo.recompute_content(...)
Stmt [14] OK: COMMENT ON FUNCTION recompute_content
```

---

## Regression Notes

- Existing functions (`recall_lessons`, `recall_hybrid`, `ingest`, `reinforce`, `stats`, etc.) were not touched by the migration and are unaffected.
- No signature changes to existing functions.
- Additive columns (`source_type`, `embedding_at`) both use `IF NOT EXISTS` — idempotent.
- `source_type` defaults to `'auto_captured'` — existing rows get the default automatically.
- `embedding_at` backfill UPDATE ran successfully (no rows affected on fresh test DB).

---

## Known Gaps (non-blockers, from CODE_REVIEW.md)

| Gap | Impact |
|-----|--------|
| T_miss_1: navigate_locate with NULL embedding (text-only path) | Low — footgun shared with recall_hybrid; not new |
| T_miss_2: navigate_expand with empty expand_fields → NULL expand_detail | Low — by design |
| T_miss_3: reembed_batch SKIP LOCKED (concurrent sessions) | Low — requires 2 concurrent sessions |
| T_miss_4: navigate_locate with as_of_ts time-travel | Low — bitemporal path exercised by existing v0.7.1 tests |

---

## QA Sign-off

**Result**: PASS — pgmnemo 0.8.0 is ready for SHIP phase.

All 5 new functions (`navigate_locate`, `navigate_expand`, `reembed`, `reembed_batch`, `recompute_content`) are correctly implemented, tested, and produce expected output. Schema additions (`source_type`, `embedding_at`) are correctly constrained and backfilled. No regressions observed.
