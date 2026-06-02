# RESEARCH: pgmnemo v0.6.3 — R1–R4 Analysis

**Task:** SWDEV-260524-1-RESEARCH  
**Author:** principal_investigator (77)  
**Date:** 2026-05-24  
**Scope:** AmbiguousColumn root-cause analysis + alternatives (R1), GUC semantics (R2), BM25 threshold (R3), psycopg2 calling convention (R4)

---

## R1 — AmbiguousColumn: Root Cause Analysis + ≥3 Alternatives

### Root Cause

Both `recall_lessons()` and `recall_hybrid()` declare `RETURNS TABLE (role TEXT, ...)`.  
In PL/pgSQL, `RETURNS TABLE` OUT variables are **first-class PL/pgSQL variables** — they live in the function's DECLARE scope alongside `_include_unverified`, `_ef_search`, etc.

When the PL/pgSQL parser encounters any reference to `role` (bare or even table-qualified as `r.role`, `s.role`, `al.role`) inside a `RETURN QUERY` expression, it must disambiguate between:
1. The OUT variable `role TEXT` (PL/pgSQL variable scope)
2. A column named `role` from a CTE or table alias in the SQL query

PostgreSQL table-qualification (`al.role`, `r.role`) resolves the SQL-layer ambiguity but **does not** resolve the PL/pgSQL variable-scope ambiguity. The error fires because the SQL planner, invoked by PL/pgSQL, sees an expression that could bind to either the OUT variable or the column. This is not a v0.6.2 regression — the same body structure existed from v0.5.0 onward; the error manifests on specific PostgreSQL builds/versions where variable-conflict detection is stricter.

**Confirmed affected locations in pgmnemo--0.6.2.sql:**

| Function | Location | Expression | Issue |
|----------|----------|------------|-------|
| `recall_hybrid()` | line 1141 (`raw_candidates` CTE) | `al.role,` | bare `role` column name in SELECT list — becomes column `role` in CTE |
| `recall_hybrid()` | line 1195 (`scored` CTE) | `r.role,` | references CTE column `role` from `rrf_ranked` |
| `recall_hybrid()` | line 1272 (final SELECT) | `s.role,` | references CTE column `role` from `scored` |
| `recall_lessons()` | line 2361 (WHERE clause) | `al.role = role_filter` | bare `role_filter` param resolved via function-qualification; `al.role` table-qualified |
| `recall_lessons()` | line 2399 (final SELECT) | `c.cand_role AS role` | output alias `role` binds to OUT variable — safe due to cand_role aliasing |

The `recall_lessons()` vector-only path already uses `cand_role` CTE aliasing (safe). The `recall_hybrid()` path carries bare `role` through three CTEs without aliasing — this is the primary trigger.

---

### Alternative Fixes

#### Option A — `#variable_conflict use_column` directive (RECOMMENDED)

**Change:** Add one line immediately after `AS $$` in both function bodies:
```sql
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    ...
```

**Semantics:** Tells PL/pgSQL: when a name matches both a variable and a column, always prefer the column. This is a PL/pgSQL compile-time directive — zero runtime cost, zero SQL-level change.

**Pros:**
- Zero signature change — fully backward compatible
- One line per function (2 LOC total)
- Idiomatic PostgreSQL fix for this exact class of error (documented in PG manual §43.12)
- No CTE rewrite needed
- Works regardless of which `role` reference actually triggers the error
- Eliminates the class of bug for any future OUT variable added with a name matching a column

**Cons:**
- Globally changes name resolution for the entire function — if a future developer adds a PL/pgSQL variable with a name that *should* shadow a column, this directive silently changes behavior
- Requires `#variable_conflict` knowledge to maintain (not obvious to casual contributors)
- Doesn't make the naming conflict *visible* to the reader — the code still looks like it has ambiguity

**Risk level:** LOW. Both functions are pure `RETURNS TABLE` readers with no side effects. All local variables use `_` prefix convention (`_include_unverified`, `_ef_search`, etc.), so there is no actual naming conflict to resolve in the wrong direction.

---

#### Option B — CTE column aliasing in `recall_hybrid()` (pure SQL fix, no PL/pgSQL directive)

**Change:** Mirror the `recall_lessons()` `cand_role` pattern in `recall_hybrid()`: rename `al.role` → `al.role AS rh_role` in `raw_candidates`, carry `rh_role` through `rrf_ranked` and `scored`, and alias back to `role` only in the final output SELECT.

**Affected lines:** 1141, 1195, 1272 (plus `rrf_ranked` SELECT * would need explicit columns).

**Pros:**
- No PL/pgSQL-level directive needed — fix is purely SQL
- Makes the naming intention explicit and readable to SQL developers
- Consistent with the existing `recall_lessons()` pattern
- `SELECT *` in `rrf_ranked` CTE must be replaced by explicit column list anyway (good hygiene)

**Cons:**
- ~15 LOC change in `recall_hybrid()` (replace `SELECT *` in `rrf_ranked` with 10+ explicit columns)
- Does not protect against future OUT variables with column-conflicting names
- More invasive diff makes code review harder for a hotfix
- Requires verifying every CTE that inherits `role` column (3 CTEs in the chain)
- Still leaves `recall_lessons()` relying on the existing `cand_role` pattern inconsistently with `recall_hybrid()`

**Risk level:** MEDIUM for hotfix (more code to touch). Appropriate as v0.7.0 cleanup.

---

#### Option C — Function-qualify all OUT variable references

**Change:** Replace bare `role` references with `recall_hybrid.role` (function-qualified) and `recall_lessons.role` (function-qualified) in all ambiguous positions.

**Pros:**
- No directive change
- No CTE restructure
- Explicitly documents the ambiguity at the point of use

**Cons:**
- Does not fix the ambiguity — it specifies which side of the ambiguity to resolve, but does not tell PL/pgSQL which to use for *column* references
- Actually worsens the situation: `recall_hybrid.role` inside a `RETURN QUERY` refers to the OUT variable, not the CTE column; the SELECT would return NULL for all `role` output
- This approach addresses the wrong side of the variable_conflict: for a `RETURNS TABLE` function outputting rows, we want columns, not the OUT variable
- **NOT viable** for this use case

**Risk level:** HIGH — semantically incorrect, would cause silent data corruption (NULL roles in output).

---

#### Option D — Rename OUT variable in RETURNS TABLE signature

**Change:** Rename `role TEXT` → `lesson_role TEXT` in `RETURNS TABLE (...)` for both functions.

```sql
RETURNS TABLE (
    lesson_id     BIGINT,
    score         DOUBLE PRECISION,
    lesson_role   TEXT,    -- renamed from role
    ...
)
```

**Pros:**
- Eliminates the variable/column name clash permanently
- No directive needed
- No CTE restructure needed
- Clear and explicit in the API contract

**Cons:**
- **BREAKING API CHANGE** — callers doing `SELECT role FROM pgmnemo.recall_lessons(...)` must change to `SELECT lesson_role`
- Production adopter code references the `role` column by name
- All existing SQL using these functions breaks
- Column renamed in incremental upgrade script; psycopg2 `cursor.description` column index shifts
- Not acceptable for a hotfix; deferred to a v1.0 semantic major

**Risk level:** CRITICAL for backward compatibility — NOT viable as hotfix.

---

### Verdict

**Option A is the correct fix** for v0.6.3. Option B is the right long-term hygiene fix (post-hotfix, v0.7.0 or alongside). Option C is semantically wrong. Option D is a breaking change.

**Implementation plan for R1:**
1. Add `#variable_conflict use_column` to `recall_hybrid()` body in `pgmnemo--0.6.2--0.6.3.sql`
2. Add `#variable_conflict use_column` to `recall_lessons()` body in `pgmnemo--0.6.2--0.6.3.sql`
3. Same change applied in `pgmnemo--0.6.3.sql` (fresh-install squash)
4. New pg_regress test `role_no_ambiguity.sql`: call both functions with a role_filter matching inserted data, verify `role` column in output matches expected value

---

## R2 — `include_unverified` GUC Semantics

### Source analysis (pgmnemo--0.6.2.sql)

The GUC is read in three functions: `recall_lessons()` (line 2298–2304), `recall_hybrid()` (line 1097–1103), and older pooled variants (lines 437–462, 842–848).

**Code pattern (identical in all locations):**
```sql
BEGIN
    _include_unverified := COALESCE(
        current_setting('pgmnemo.include_unverified', TRUE)::BOOLEAN,
        FALSE
    );
EXCEPTION WHEN OTHERS THEN
    _include_unverified := FALSE;
END;
```

Applied in WHERE clause:
```sql
AND (_include_unverified OR al.verified_at IS NOT NULL)
```

**Provenance gate is a separate INSERT trigger** (`_enforce_provenance_gate()`, line 38):
- Controlled by `pgmnemo.gate_strict` GUC (values: `enforce` / `warn` / `off`)
- `gate_strict` applies to **writes** (INSERT), not reads
- `include_unverified` applies to **reads** (recall queries)

### Findings for docs

`include_unverified` **does not disable the provenance gate** — it only affects the recall query WHERE filter. Setting it to `on` allows rows with `verified_at IS NULL` (ghost lessons) to appear in recall results. The INSERT-time provenance gate (requiring `commit_sha OR artifact_hash`) is controlled separately by `pgmnemo.gate_strict`.

**Documentation for R2 (to add to docs/USAGE.md or docs/GUC_REFERENCE.md):**

> ### `pgmnemo.include_unverified`
>
> **Default:** `off` (false) | **Scope:** session/transaction-local
>
> Controls whether ghost lessons — rows with `verified_at IS NULL` — appear in `recall_lessons()` and `recall_hybrid()` output. The default (`off`) excludes ghost lessons from all recall queries, ensuring only lessons that have passed provenance verification are surfaced.
>
> Setting `pgmnemo.include_unverified = 'on'` affects **only the recall query filter**: ghost lessons become eligible candidates in vector search and BM25 matching. However, their `score` will be lower because `provenance_strength = 0.0` for rows with neither `commit_sha` nor `artifact_hash` — they score 0 on the 0.1× provenance component in the scoring formula.
>
> **This GUC does not disable the provenance gate on INSERT.** The INSERT-time gate (which rejects or warns on lessons with no `commit_sha` AND no `artifact_hash`) is controlled separately by `pgmnemo.gate_strict`. You can have ghost lessons in the table (e.g. inserted via `gate_strict='warn'` or `'off'`) and still exclude them from recall (default), or include them selectively for debugging.
>
> ```sql
> -- Include ghost lessons in this session's recall queries (debugging / bulk import)
> SET pgmnemo.include_unverified = 'on';
> SELECT topic, lesson_text, score, verified_at
> FROM pgmnemo.recall_lessons(<embedding>, 10);
> -- Ghost lessons will appear with lower scores than verified rows
>
> -- Restore default before production queries
> SET pgmnemo.include_unverified = 'off';
> ```

---

## R3 — BM25 Corpus Threshold / Hybrid Auto-Flip

### Source analysis

There is **no corpus-size-based hybrid_enabled auto-flip** in the current implementation.

The routing decision in `recall_lessons()` (line 2244–2282) is purely deterministic:

```sql
IF NOT _disable_hybrid
   AND _query_text IS NOT NULL
   AND length(trim(_query_text)) > 0
   AND query_embedding IS NOT NULL THEN
    -- Route to recall_hybrid()
    RETURN QUERY SELECT ... FROM pgmnemo.recall_hybrid(...);
    RETURN;
END IF;
```

Four conditions determine hybrid routing — all structural, none dependent on corpus size:
1. `pgmnemo.disable_hybrid` GUC is `false` (or unset → defaults to false)
2. `query_text` argument is non-NULL
3. Trimmed `query_text` has length > 0
4. `query_embedding` argument is non-NULL

The `recall_diagnostics()` function (line 1624–1689) computes a `hybrid_enabled` boolean from condition #1 only:
```sql
NOT COALESCE(current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE) AS hybrid_enabled
```

**No threshold logic exists for:**
- Minimum corpus size before enabling BM25
- `lesson_tsv` coverage ratio
- BM25 document count threshold
- Automatic hybrid_enabled flip based on corpus state

### Findings for docs

There is no "BM25 corpus threshold" — the feature request may have been based on a misreading of the `recall_diagnostics()` output. The `hybrid_enabled` column in `recall_diagnostics()` is a GUC-driven boolean, not a corpus-size computation.

**Documentation for R3 (to add to docs/USAGE.md BM25 section):**

> ### When does hybrid mode activate?
>
> Hybrid retrieval activates per-query when **all three** of the following hold:
> 1. `pgmnemo.disable_hybrid` is `off` (default) — the opt-out GUC is not set
> 2. The `query_text` argument passed to `recall_lessons()` is non-NULL and non-empty
> 3. The `query_embedding` argument is non-NULL
>
> There is no automatic corpus-size threshold. Hybrid mode does not auto-enable or auto-disable based on how many rows have `lesson_tsv` populated. If your corpus has rows with `lesson_tsv IS NULL`, those rows simply score 0 on the BM25 component and may not appear in BM25-based candidates.
>
> **SQL probe — check hybrid-readiness of your corpus:**
> ```sql
> SELECT
>     COUNT(*)                                              AS total_lessons,
>     COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL)        AS bm25_ready,
>     COUNT(*) FILTER (WHERE embedding  IS NOT NULL)        AS vec_ready,
>     COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL
>                        AND embedding  IS NOT NULL)        AS hybrid_ready,
>     ROUND(
>         100.0 * COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL)
>         / NULLIF(COUNT(*), 0), 1
>     )                                                     AS bm25_coverage_pct,
>     NOT COALESCE(
>         current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN,
>         FALSE
>     )                                                     AS hybrid_enabled_guc
> FROM pgmnemo.agent_lesson
> WHERE is_active;
> ```
>
> **Interpretation:** `bm25_coverage_pct < 50%` means most candidates will not participate in BM25 ranking, reducing hybrid benefit. Consider running `UPDATE pgmnemo.agent_lesson SET lesson_tsv = to_tsvector('english', lesson_text) WHERE lesson_tsv IS NULL` to backfill coverage.

---

## R4 — psycopg2 Calling Convention for `recall_lessons()`

### Source analysis

The `recall_lessons()` signature in v0.6.2:
```sql
CREATE OR REPLACE FUNCTION pgmnemo.recall_lessons(
    query_embedding   vector(1024),
    k                 INT           DEFAULT 10,
    role_filter       TEXT          DEFAULT NULL,
    project_id_filter INT           DEFAULT NULL,
    query_text        TEXT          DEFAULT NULL,
    as_of_ts          TIMESTAMPTZ   DEFAULT NULL  -- v0.6.1 F2
)
RETURNS TABLE (...)
```

The existing `smoke_recall_hybrid.py` uses **positional literal embedding strings** embedded in the SQL string (f-string format), bypassing psycopg2 parameter substitution for the vector:
```python
cur.execute(
    f"SELECT * FROM pgmnemo.recall_hybrid('{zero_vec}'::vector, 'test query', 10, 'smoke_recall_hybrid', 1, 0.4, 0.4) LIMIT 1"
)
```

### Calling conventions compared

#### Convention 1: Positional `%s` parameters (psycopg2 standard)

```python
cur.execute(
    "SELECT * FROM pgmnemo.recall_lessons(%s::vector, %s, %s, %s, %s) ORDER BY score DESC",
    (embedding_str, 10, 'developer', None, 'JWT rotation policy')
)
```

**Pros:** Standard psycopg2 idiom; SQL injection safe; works with all psycopg2 versions  
**Cons:** `vector` type requires explicit `::vector` cast; positional order must match signature; defaults not usable (must supply NULL explicitly)

#### Convention 2: Named parameters via psycopg2 `%(name)s` style

```python
cur.execute(
    """SELECT * FROM pgmnemo.recall_lessons(
         %(emb)s::vector, %(k)s, %(role)s, %(proj)s, %(text)s
       ) ORDER BY score DESC""",
    {"emb": embedding_str, "k": 10, "role": "developer",
     "proj": None, "text": "JWT rotation policy"}
)
```

**Pros:** Named placeholders improve readability in multi-param calls  
**Cons:** Same as Convention 1 — no server-side named parameter binding; defaults still unusable; still positional at the PostgreSQL level

#### Convention 3: SQL-level named argument call (PostgreSQL 14+ `=>` syntax)

```python
cur.execute(
    """SELECT * FROM pgmnemo.recall_lessons(
         query_embedding => %s::vector,
         query_text      => %s,
         k               => %s
       ) ORDER BY score DESC""",
    (embedding_str, 'JWT rotation policy', 5)
)
```

**Pros:** True named argument call at PostgreSQL level; allows omitting optional params; order-independent; self-documenting  
**Cons:** Requires PostgreSQL 14+ (pgmnemo's minimum); slightly more verbose; `%s` injection must still be used for psycopg2 parameter binding

### Recommendation for R4

**Convention 3 (named `=>` syntax) is canonical for production use.** It is self-documenting, order-independent, and allows callers to omit optional parameters like `as_of_ts` without supplying NULL explicitly. Convention 1 is acceptable for scripts and tests where brevity matters.

**Documentation for R4 (to add to docs/USAGE.md):**

> ### psycopg2 calling convention
>
> pgmnemo SQL functions use **PostgreSQL named argument syntax** (`=>`) when called from Python. This is the recommended style for production code — it is order-independent, allows omitting optional parameters, and is self-documenting.
>
> ```python
> import psycopg2
> import numpy as np
>
> def format_vector(arr: np.ndarray) -> str:
>     """Convert numpy array to pgvector literal string."""
>     return "[" + ",".join(f"{v:.6f}" for v in arr.tolist()) + "]"
>
> conn = psycopg2.connect(os.environ["DATABASE_URL"])
> cur = conn.cursor()
>
> embedding = np.random.randn(1024).astype(np.float32)
> embedding_str = format_vector(embedding)
>
> # Named argument style (recommended — omit optional params freely)
> cur.execute(
>     """SELECT lesson_id, score, role, topic, lesson_text
>        FROM pgmnemo.recall_lessons(
>            query_embedding => %s::vector,
>            query_text      => %s,
>            k               => %s,
>            role_filter     => %s
>        )
>        ORDER BY score DESC""",
>     (embedding_str, "JWT rotation policy", 10, "developer")
> )
> rows = cur.fetchall()
>
> # Positional style (acceptable for scripts / tests)
> cur.execute(
>     "SELECT * FROM pgmnemo.recall_lessons(%s::vector, %s, %s, %s, %s) ORDER BY score DESC",
>     (embedding_str, 10, "developer", None, "JWT rotation policy")
> )
> ```
>
> **Important:** psycopg2 does not natively support the PostgreSQL `vector` type. Always pass embeddings as strings with an explicit `::vector` cast in the SQL. The `%s` placeholder becomes a `TEXT` literal that PostgreSQL casts to `vector(1024)` at parse time.
>
> **Point-in-time recall (v0.6.1+):** Pass `as_of_ts` to restrict recall to lessons that existed at a given timestamp:
> ```python
> cur.execute(
>     """SELECT lesson_id, score, topic, lesson_text
>        FROM pgmnemo.recall_lessons(
>            query_embedding => %s::vector,
>            query_text      => %s,
>            as_of_ts        => %s::timestamptz
>        )""",
>     (embedding_str, "auth policy", "2026-05-01T00:00:00Z")
> )
> ```

---

## Summary of Decisions

| Item | Finding | Recommended action |
|------|---------|-------------------|
| R1 AmbiguousColumn | OUT variable `role TEXT` in RETURNS TABLE conflicts with CTE column `role` even when table-qualified; PL/pgSQL variable_conflict | **Option A**: add `#variable_conflict use_column` to both function bodies (2 LOC) |
| R2 include_unverified | GUC affects recall filter only (WHERE clause); does NOT disable INSERT-time provenance gate (`gate_strict`); ghost lessons score lower | Document both GUCs clearly; clarify that they operate on different lifecycle events |
| R3 BM25 corpus threshold | No auto-flip logic exists; hybrid routing is purely GUC + argument presence; `hybrid_enabled` in recall_diagnostics() is GUC-only | Add SQL probe query + coverage guidance; clarify there is no corpus-size threshold |
| R4 psycopg2 calling convention | Named `=>` syntax (PG14+) is canonical; positional `%s` acceptable for tests; vector must be passed as string with `::vector` cast | Add working examples for both styles to USAGE.md |
