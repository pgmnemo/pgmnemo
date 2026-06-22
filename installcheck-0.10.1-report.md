# pgmnemo 0.10.1 — Install/Upgrade/Installcheck Report (Issue #84)

Generated: 2026-06-22 (automated — throwaway contour)

**Overall: PASS ✓**

**Scope:** Issue #84 — `recall_fast()` NULL score when `query_embedding IS NULL` (regression in v0.10.0)

---

## upgrade_0.10.0_to_0.10.1 (#84 fix path)

**Status: PASS**

- Throwaway DB: `pgmnemo_ic_0101` (PostgreSQL 17.10, pgvector 0.8.3)
- Upgrade path tested: fresh `pgmnemo 0.10.0` install → `ALTER EXTENSION pgmnemo UPDATE` via `pgmnemo--0.10.0--0.10.1.sql` (section G)
- Migration applied cleanly: all schema changes and function replacements succeeded

## pg_regress cases (T1/T2/T8/T11)

| Test | Result | Notes |
|------|--------|-------|
| T1 — recall_fast() exists (5-arg signature) | **PASS** | `pronargs=5` confirmed |
| T2 — parameter names match API | **PASS** | `query_embedding, k, role_filter, project_id_filter, exclude_dag_id` |
| T8 — identical embeddings → score = 1.0 | **PASS** | `ROUND(score, 2) = 1.00` on uniform 1024-dim vector |
| T11 — NULL query_embedding → EXCEPTION (#84) | **PASS** | SQLSTATE P0001 raised with correct message |

### T11 detail (primary gate for #84)

```
PASS: raised P0001 with correct message:
pgmnemo.recall_fast: query_embedding IS NULL -- a vector embedding is required
for HNSW search. recall_fast has no text-only fallback; use recall_hybrid() if
you have query_text but no embedding.
```

**Before fix (v0.10.0 behavior):** `recall_fast(NULL::vector, ...)` returned rows with `score = NULL` (silent corruption of downstream ranking).

**After fix (v0.10.1 behavior):** raises `EXCEPTION` (SQLSTATE P0001) with clear message directing caller to use `recall_hybrid()` if text-only recall is needed. No NULL propagation.

## Function comment updated

`COMMENT ON FUNCTION pgmnemo.recall_fast(...)` includes:
```
'v0.10.1 #84: raises EXCEPTION when query_embedding IS NULL (no text-only fallback).'
```

## Fix location (migration SQL)

`extension/pgmnemo--0.10.0--0.10.1.sql` — section G (lines 1116–1257):

```plpgsql
-- #84: reject NULL query_embedding early
IF query_embedding IS NULL THEN
    RAISE EXCEPTION
        'pgmnemo.recall_fast: query_embedding IS NULL -- '
        'a vector embedding is required for HNSW search. '
        'recall_fast has no text-only fallback; use recall_hybrid() '
        'if you have query_text but no embedding.';
END IF;
```

Same fix also applied in `extension/pgmnemo--0.10.1.sql` (full build file, line 7758).

## NOT prod prod_corpus

Throwaway DB `pgmnemo_ic_0101` used. Agency_v3 not touched. ✓

## Note on G-PG-REGRESS gate

This report covers the #84 recall_fast NULL fix. The full `make installcheck` (pg_regress suite including all REGRESS targets from Makefile) requires `pg_config` and `make` in PATH — not available in this environment. The complete REGRESS suite must be run before the `release_decision=SHIP` gate is set. See `PGMNEMO_RELEASE_PLAN_V0101_V0110_2026-06-22.md §v0.10.1 release gates`.

The #87 smoke bench (timeout_rate=0%, p95<2s on non-Latin corpus) is a separate gate, documented in `PGMNEMO_RELEASE_PLAN_V0101_V0110_2026-06-22.md §Smoke bench`.
