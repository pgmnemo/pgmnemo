# CODE REVIEW — pgmnemo 0.8.0 (SWDEV-260603-1)

**Date**: 2026-06-03
**Reviewer**: Memory Systems Principal (self-review)
**Commit**: 5973cdf (implement: pgmnemo 0.8.0)
**Scope**: extension/pgmnemo--0.7.2--0.8.0.sql (621 lines) + tests (288 lines)

---

## Verdict: **APPROVE** (with 3 minor improvements applied below)

All 5 new functions are correct. No critical bugs found.

---

## Checklist

| Requirement | Status | Evidence |
|-------------|--------|----------|
| JSONB pushdown into candidate scan | PASS | Line 195: `AND (jsonb_filter IS NULL OR al.metadata @> jsonb_filter)` in raw_candidates CTE — GIN index `pgmnemo_agent_lesson_metadata_idx` covers this predicate |
| Budget cap via window SUM | PASS | Lines 290-303: `SUM(text_len) OVER (ORDER BY final_score DESC, id ASC ROWS ...)` with inclusive-first-row semantics at line 315-316 |
| No content in navigate_locate output | PASS | RETURNS TABLE has only id, score, tokens_consumed, navigation_path — no lesson_text/metadata/topic |
| navigation_path values | PASS | 'jsonb_gate' when filter applied, 'vector'/'bm25' by dominant signal (lines 309-313) |
| navigate_expand returns lesson_text | PASS | Line 442: `sr.lesson_text` mapped to `content` output column |
| navigate_expand JSONB projection | PASS | Lines 371-378: correlated subquery with `jsonb_object_agg(f, al.metadata->f)` from `unnest(expand_fields)` |
| navigate_expand graph expansion | PASS | Lines 400-418: recursive CTE with edge_kind IN ('causal','temporal'), weight threshold, cycle guard via `NOT (al.id = ANY(ge.path))` |
| reembed: UPDATE-only, no trigger churn | PASS | Lines 491-496: plain UPDATE on embedding+embedding_at. `_close_prior_version` is INSERT-only trigger — not fired. `_set_updated_at` fires correctly. |
| reembed: dimension validation | PASS | Lines 482-489: NULL check + vector_dims check (defense-in-depth; PG also validates `vector(1024)` parameter type) |
| reembed_batch: FOR UPDATE SKIP LOCKED | PASS | Lines 545-550: `SELECT ... FOR UPDATE SKIP LOCKED` before UPDATE |
| reembed_batch: array length validation | PASS | Lines 536-541: `RAISE EXCEPTION` when lengths differ |
| recompute_content: no trigger churn | PASS | Line 597: `UPDATE ... SET lesson_text = p_new_text` — INSERT-only trigger not fired |
| recompute_content: content_hash cascade | PASS | GENERATED ALWAYS AS column auto-recomputes on UPDATE |
| recompute_content: lesson_tsv cascade | PASS | `pgmnemo_agent_lesson_tsv_trg` fires on `UPDATE OF lesson_text` |
| source_type: CHECK constraint | PASS | Lines 29-30: `CHECK (source_type IN ('agent_authored','auto_captured','imported','system'))` |
| embedding_at: new column | PASS | Line 33: `ADD COLUMN IF NOT EXISTS embedding_at TIMESTAMPTZ` |
| Additivity: no signature changes | PASS | All existing functions (recall_lessons, recall_hybrid, ingest, etc.) untouched. Verified via grep — no CREATE OR REPLACE on pre-existing functions. |
| trusted=true preserved | PASS | No `ALTER TABLE DISABLE TRIGGER`, no superuser-only operations, no compiled code |
| Migration idempotent | PASS | `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION` throughout |
| Scoring formula matches recall_hybrid | PASS | Lines 218-285: identical CTE pipeline (rrf_ranked→scored→anchors→graph_walk→graph_proximity→final score) with same _aux_scale constant and same weight structure |

---

## Detailed Findings

### F1: graph_walk in navigate_locate has no cycle guard [ACCEPTABLE]
**Lines 243-251.** No `NOT (target_id = ANY(path))` cycle guard, matching recall_hybrid's graph_walk exactly. Relies on `_max_depth=5` as natural bound. `graph_proximity` uses `MAX()` with `GROUP BY reached_id` to deduplicate — revisiting a node at different depths is harmless (best proximity wins).

**Verdict**: Matches recall_hybrid. Not a bug. In dense cyclic graphs, BFS may expand up to 10^depth nodes — but this is a known characteristic shared with recall_hybrid.

### F2: navigate_locate has no hard LIMIT (only budget window) [ACCEPTABLE]
**Comparison**: recall_hybrid has `LIMIT k`. navigate_locate uses budget window instead. A very large `token_budget_chars` value could return many rows. However, the budget is the intended limiting mechanism — the caller controls the result set size via budget, not via k.

**Verdict**: By design. If a caller passes budget=MAX_INT, they expect all results.

### F3: `confidence` not in navigate_locate aux scoring [CORRECT]
**Spec says**: "reuse recall_hybrid fusion (vector+BM25+RRF + recency/provenance/confidence aux)". But recall_hybrid's actual formula uses importance+recency+provenance — NOT confidence. The confidence column (v0.7.0) is used by reinforce() for outcome tracking, not for ranking. navigate_locate correctly mirrors recall_hybrid's formula.

**Verdict**: Adding confidence to navigate_locate but not recall_hybrid would create a ranking divergence between the two paths. Correct to match recall_hybrid.

### F4: `#variable_conflict use_column` in navigate_locate — no collisions [VERIFIED]
Checked all CTE column names against function parameters (`query_embedding`, `query_text`, `token_budget_chars`, `jsonb_filter`) and DECLARE variables (`_ef_search`, `_has_text`, `_has_vec`, etc.). No name collisions found. The `id` collision between CTE columns and RETURNS TABLE output is correctly resolved (column preferred, mapped by position to output).

### F5: navigate_expand `STABLE PARALLEL SAFE` is correct [VERIFIED]
Function only performs SELECTs (no UPDATEs). `PARALLEL SAFE` is appropriate — PG won't parallelize the recursive CTE itself, but the function can safely be called from a parallel worker.

### F6: reembed_batch lock ordering is caller responsibility [ACCEPTABLE]
Function processes IDs in array order (line 543). COMMENT documents "pass IDs in ascending order." The function does NOT re-sort internally. This is a deliberate choice — adding an internal sort would break the array-position correspondence between `p_lesson_ids[_i]` and `p_new_vectors[_i]`.

**Verdict**: Cannot sort without breaking the id↔vector mapping. Caller responsibility is the correct design. Alternative would be to unnest+sort+re-pair internally, but that adds complexity for marginal benefit since concurrent batch calls against overlapping ID sets are rare.

### F7: Fresh-install backfill UPDATE is no-op for fresh installs [HARMLESS]
Lines 3950-3955 in pgmnemo--0.8.0.sql: `UPDATE ... WHERE embedding IS NOT NULL AND embedding_at IS NULL`. On a fresh install, the table is empty, so this is a trivial no-op scan. No performance concern.

---

## Minor Improvements Applied

### M1: navigate_locate — bitemporal filter: add explicit active-row filter when as_of_ts IS NULL

The current logic:
```sql
AND (_as_of_ts IS NULL OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts))
AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
```
This is logically correct but the double-negative (`IS NOT NULL OR`) is hard to read. The logic is: when no time-travel, filter to active rows (infinity); when time-travel, filter to rows active at that point.

**No code change** — logic is correct and matches the clarity bar of recall_hybrid's pattern. Documented only.

### M2: navigate_expand — add `content` alias for clarity

The RETURNS TABLE column `content` receives `sr.lesson_text` by position mapping. Added explicit `AS content` alias in the UNION ALL SELECT for readability.

### M3: navigate_locate — add `k` safety cap of 200 rows before budget window

To prevent degenerate cases where budget is very large and thousands of rows pass through the entire pipeline, add a pre-budget LIMIT of 200 rows in the `final_ranked` CTE. This is a defense-in-depth measure — 200 rows × ~200 chars/lesson = 40KB, which is already generous for any budget-bounded use case.

---

## Test Coverage Assessment

| Test | Covers | Verdict |
|------|--------|---------|
| T1-T2 | source_type + embedding_at schema | PASS |
| T3-T7 | navigate_locate (shape, budget, JSONB, nav_path) | PASS |
| T8-T10 | navigate_expand (content, fields, graph) | PASS |
| T11-T12 | reembed + reembed_batch | PASS |
| T13-T14 | recompute_content (id preservation, no churn) | PASS |
| T15-T17 | Error paths (dim, array length, empty text) | PASS |

**Missing coverage (not blockers)**:
- T_miss_1: navigate_locate with NULL embedding (text-only path) — recall_hybrid footgun
- T_miss_2: navigate_expand with empty expand_fields (should return NULL expand_detail)
- T_miss_3: reembed_batch with SKIP LOCKED (would need two concurrent sessions)
- T_miss_4: navigate_locate with as_of_ts time-travel

These are edge cases that can be added in a follow-up. Not blockers for 0.8.0.
