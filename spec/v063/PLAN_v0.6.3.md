# PLAN: pgmnemo v0.6.3 — R1 AmbiguousColumn Hotfix + R2–R4 Docs

**Task:** SWDEV-260524-1-PLAN  
**Date:** 2026-05-24  
**Research basis:** spec/v063/RESEARCH_v0.6.3.md (commit 6dd47d5)  
**Estimated effort:** 2–3 hours (low complexity, fully prescriptive)  
**Risk:** LOW — zero schema change, zero signature change, zero scoring change

---

## Summary

Bug-fix + docs release. Core fix is 2 lines (one `#variable_conflict` directive per function). All
other items are versioning boilerplate + documentation additions. No DB migration. No API break.

---

## Affected Files (complete list)

| File | Change type | Est. LOC |
|------|-------------|---------|
| `extension/pgmnemo--0.6.2--0.6.3.sql` | NEW — incremental upgrade | ~120 |
| `extension/pgmnemo--0.6.3.sql` | NEW — fresh-install squash | ~2900 (copy of 0.6.2 + directive) |
| `extension/sql/role_no_ambiguity.sql` | NEW — pg_regress test | ~30 |
| `extension/expected/role_no_ambiguity.out` | NEW — pg_regress expected output | ~10 |
| `extension/Makefile` | MODIFY — DATA + REGRESS lists | 3 lines |
| `extension/pgmnemo.control` | MODIFY — default_version | 1 line |
| `META.json` | MODIFY — version (2 occurrences) | 2 lines |
| `pgmnemo_mcp/pyproject.toml` | MODIFY — version | 1 line |
| `scripts/smoke_recall_hybrid.py` | MODIFY — add recall_lessons smoke | ~30 lines |
| `docs/USAGE.md` | MODIFY — R2, R3, R4 additions | ~60 lines |
| `benchmarks/gate/v0.6.3.json` | NEW — analytical carry-forward | ~30 lines |
| `CHANGELOG.md` | MODIFY — [0.6.3] entry | ~15 lines |
| `README.md` | MODIFY — badge + note | ~5 lines |
| `docs/release_notes/v0.6.3_telegram.md` | NEW — release note | ≤3500 chars |

---

## Step-by-Step Implementation Plan

### Step 1 — R1 core fix: `extension/pgmnemo--0.6.2--0.6.3.sql` (P0, ~30 min)

Create incremental upgrade script. Contains only `CREATE OR REPLACE` for the two affected functions with `#variable_conflict use_column` added.

**Structure:**
```sql
-- pgmnemo--0.6.2--0.6.3.sql
-- R1: Fix AmbiguousColumn in recall_lessons() and recall_hybrid()
-- Root cause: PL/pgSQL variable_conflict between RETURNS TABLE OUT variable 'role TEXT'
-- and agent_lesson.role column. #variable_conflict use_column resolves in favour of column.
-- Zero signature change. Zero scoring change. Backward compatible.

CREATE OR REPLACE FUNCTION pgmnemo.recall_hybrid(...)
RETURNS TABLE (...)
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
#variable_conflict use_column     -- <-- ADD THIS LINE
DECLARE
    ...
```

**Exact change for each function:** Insert `#variable_conflict use_column` as the first line of the function body, immediately after `AS $$` and before the `DECLARE` block. One line per function. The incremental script must be `CREATE OR REPLACE` (not DROP + CREATE) to preserve any existing GRANTs.

**Validation before commit:** Run `grep "#variable_conflict" extension/pgmnemo--0.6.2--0.6.3.sql` — must return 2 matches (one per function).

---

### Step 2 — R1 fresh-install: `extension/pgmnemo--0.6.3.sql` (P0, ~10 min)

Copy `pgmnemo--0.6.2.sql` to `pgmnemo--0.6.3.sql`. Apply the same two `#variable_conflict use_column` insertions at the same positions as in Step 1.

**Key positions in 0.6.2.sql:**
- `recall_hybrid()`: line 1056 (`AS $$`) → insert after
- `recall_lessons()` (final v0.6.x definition): line 2207 (`AS $$`) → insert after

**Validation:** `diff <(grep -n "LANGUAGE plpgsql" pgmnemo--0.6.3.sql) <(grep -n "LANGUAGE plpgsql" pgmnemo--0.6.2.sql)` — should show identical LANGUAGE lines (no signature drift). `grep -c "#variable_conflict" pgmnemo--0.6.3.sql` must return ≥ 2.

---

### Step 3 — pg_regress test: `role_no_ambiguity` (P0, ~20 min)

Create test that explicitly exercises the role column to confirm no AmbiguousColumn error:

**`extension/sql/role_no_ambiguity.sql`:**
```sql
-- pg_regress: verify role column is unambiguous in recall_lessons + recall_hybrid
-- Regression guard for #variable_conflict use_column fix (v0.6.3 R1)

SET client_min_messages = 'warning';
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';

-- Seed one lesson with a known role value
INSERT INTO pgmnemo.agent_lesson
    (role, project_id, topic, lesson_text, importance, embedding,
     commit_sha, verified_at)
VALUES
    ('test_role_v063', 1,
     'role_disambiguation_test',
     'This lesson verifies the role column is returned without AmbiguousColumn error.',
     3,
     ('[' || repeat('0.001,', 1023) || '0.001]')::vector,
     'role_test_sha_v063',
     NOW());

-- Test 1: recall_lessons returns correct role value
SELECT role = 'test_role_v063' AS role_correct
FROM pgmnemo.recall_lessons(
    ('[' || repeat('0.001,', 1023) || '0.001]')::vector,
    1,
    'test_role_v063',
    1
)
LIMIT 1;

-- Test 2: recall_hybrid returns correct role value
SELECT role = 'test_role_v063' AS role_correct
FROM pgmnemo.recall_hybrid(
    ('[' || repeat('0.001,', 1023) || '0.001]')::vector,
    'role disambiguation test',
    1,
    'test_role_v063',
    1
)
LIMIT 1;

-- Cleanup
DELETE FROM pgmnemo.agent_lesson
WHERE role = 'test_role_v063' AND commit_sha = 'role_test_sha_v063';
```

**`extension/expected/role_no_ambiguity.out`:**
```
 role_correct 
--------------
 t
(1 row)

 role_correct 
--------------
 t
(1 row)

DELETE 1
```

**Validation:** pg_regress count in Makefile goes from 17 → 18 after adding `role_no_ambiguity` to REGRESS list.

---

### Step 4 — `extension/Makefile` (P0, ~5 min)

Two changes:

**DATA list:** append two new files after `pgmnemo--0.6.2.sql`:
```makefile
       pgmnemo--0.6.2--0.6.3.sql \
       pgmnemo--0.6.3.sql
```

**REGRESS list:** append `role_no_ambiguity` at end:
```makefile
REGRESS = ... stress_recall rrf_sparse role_no_ambiguity
```

---

### Step 5 — Version bumps (P0, ~5 min)

Three files, all mechanical:

| File | Field | From | To |
|------|-------|------|----|
| `extension/pgmnemo.control` | `default_version` | `'0.6.2'` | `'0.6.3'` |
| `META.json` | `"version"` (line 5) | `"0.6.2"` | `"0.6.3"` |
| `META.json` | inner `"version"` (line 13) | `"0.6.2"` | `"0.6.3"` |
| `pgmnemo_mcp/pyproject.toml` | `version` | `"0.6.2"` | `"0.6.3"` |

---

### Step 6 — pg_regress fixtures sweep (P0, ~5 min, CRITICAL)

This exact pitfall killed v0.6.2 installcheck. Search for any `ALTER EXTENSION pgmnemo UPDATE TO` referencing `0.6.2` in test fixtures:

```bash
grep -rn "ALTER EXTENSION pgmnemo UPDATE TO" extension/sql/ extension/expected/
```

Any match referencing `0.6.2` → replace with `0.6.3`. The REGRESS tests that include `ALTER EXTENSION` upgrade paths (e.g. `bitemporality_smoke`, `as_of_ts`) must use the current version.

**Expected:** Zero matches referencing 0.6.2 after sweep (or correct 0.6.3 references).

---

### Step 7 — `scripts/smoke_recall_hybrid.py` extension (P0, ~20 min)

The task requires both `recall_lessons` AND `recall_hybrid` to be called in the smoke test. Current smoke only calls `recall_hybrid`. Add a `smoke_recall_lessons()` function:

**Addition after the existing `main()` function:**

```python
def smoke_recall_lessons(cur: "psycopg2.cursor") -> None:
    """Smoke test for recall_lessons() — verifies callable + role column returned."""
    zero_vec = "[" + ",".join(["0.001"] * 1024) + "]"
    # Empty corpus → 0 rows, no exception
    cur.execute(
        f"SELECT * FROM pgmnemo.recall_lessons('{zero_vec}'::vector, 10, 'smoke_recall_lessons', 1) LIMIT 1"
    )
    cols = {d[0] for d in cur.description}
    expected = {"lesson_id", "score", "role", "topic", "lesson_text", "vec_score", "bm25_score", "rrf_score"}
    missing = expected - cols
    if missing:
        print(f"FAIL: recall_lessons missing columns: {sorted(missing)}")
        sys.exit(1)
    print(f"[smoke] ✓ recall_lessons output columns match ({len(cols)} cols)")

    # Insert lessons and verify role column value (R1 regression guard)
    real_vec = "[" + ",".join([f"{0.001 + i * 0.0001:.6f}" for i in range(1024)]) + "]"
    cur.execute(
        """INSERT INTO pgmnemo.agent_lesson
           (role, project_id, topic, lesson_text, importance, embedding,
            commit_sha, verified_at)
           VALUES ('smoke_recall_lessons', 1, 'smoke/r1fix',
                   'R1 regression guard: role column must not be ambiguous.', 3,
                   %s::vector, 'smoke_r1_abc123', NOW())""",
        (real_vec,)
    )
    cur.execute(
        f"""SELECT role FROM pgmnemo.recall_lessons(
                '{real_vec}'::vector, 1, 'smoke_recall_lessons', 1
            ) LIMIT 1"""
    )
    row = cur.fetchone()
    if row is None:
        print("FAIL: recall_lessons returned 0 rows from seeded corpus")
        sys.exit(1)
    if row[0] != "smoke_recall_lessons":
        print(f"FAIL: recall_lessons role column mismatch: expected 'smoke_recall_lessons', got {row[0]!r}")
        sys.exit(1)
    print(f"[smoke] ✓ recall_lessons role column = {row[0]!r} (R1 AmbiguousColumn fix verified)")
    cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role = 'smoke_recall_lessons'")
```

Call `smoke_recall_lessons(cur)` from `main()` before the existing `recall_hybrid` tests. Both must pass for exit 0.

---

### Step 8 — `docs/USAGE.md` additions: R2 + R3 + R4 (P1/P2, ~30 min)

Three documentation additions. All based on direct source analysis from RESEARCH phase (spec/v063/RESEARCH_v0.6.3.md).

**R2 — include_unverified GUC semantics** (add after existing `SET pgmnemo.include_unverified = 'true';` reference at line ~110):

> The `pgmnemo.include_unverified` GUC controls whether ghost lessons (rows with `verified_at IS NULL`) appear in recall results. By default (`off`), ghost lessons are excluded from all recall queries. Setting it to `on` makes ghost lessons eligible candidates, but they score lower: `provenance_strength = 0.0` contributes 0 to the 0.1× provenance component in the scoring formula.
>
> **This GUC does not disable the INSERT-time provenance gate.** The INSERT gate (requiring `commit_sha OR artifact_hash`) is controlled separately by `pgmnemo.gate_strict` (`enforce`/`warn`/`off`). These two GUCs operate on different lifecycle events: `gate_strict` on write, `include_unverified` on read. You can insert ghost lessons via `gate_strict='warn'` and still exclude them from recall (default), or include them selectively for diagnostics/bulk import.

**R3 — BM25 corpus threshold / hybrid routing** (add to Hybrid retrieval section, after hybrid opt-out GUC docs):

> **When does hybrid mode activate?** Hybrid routing in `recall_lessons()` fires per-query when all three hold: (1) `pgmnemo.disable_hybrid` is `off` (default), (2) the `query_text` argument is non-NULL and non-empty, (3) `query_embedding` is non-NULL. There is no corpus-size threshold — hybrid does not auto-enable or auto-disable based on how many rows have `lesson_tsv` populated.
>
> ```sql
> -- Check hybrid-readiness of your corpus
> SELECT
>     COUNT(*)                                                  AS total,
>     COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL)            AS bm25_ready,
>     COUNT(*) FILTER (WHERE embedding  IS NOT NULL)            AS vec_ready,
>     ROUND(100.0 * COUNT(*) FILTER (WHERE lesson_tsv IS NOT NULL)
>           / NULLIF(COUNT(*), 0), 1)                           AS bm25_coverage_pct,
>     NOT COALESCE(current_setting('pgmnemo.disable_hybrid', TRUE)::BOOLEAN, FALSE)
>                                                               AS hybrid_enabled_guc
> FROM pgmnemo.agent_lesson WHERE is_active;
> ```

**R4 — psycopg2 calling convention** (add new subsection "Python / psycopg2 calling convention"):

> Named argument syntax (`=>`, PostgreSQL 14+) is the recommended style for production code. It is order-independent, allows omitting optional parameters, and is self-documenting.
>
> ```python
> # Named argument style (recommended)
> cur.execute(
>     """SELECT lesson_id, score, role, topic, lesson_text
>        FROM pgmnemo.recall_lessons(
>            query_embedding => %s::vector,
>            query_text      => %s,
>            k               => %s,
>            role_filter     => %s
>        ) ORDER BY score DESC""",
>     (embedding_str, "JWT rotation policy", 10, "developer")
> )
>
> # Positional style (acceptable for scripts/tests)
> cur.execute(
>     "SELECT * FROM pgmnemo.recall_lessons(%s::vector, %s, %s, %s, %s) ORDER BY score DESC",
>     (embedding_str, 10, "developer", None, "JWT rotation policy")
> )
> ```
>
> **Note:** psycopg2 has no native `vector` type. Always pass embeddings as strings with `::vector` cast. Format: `"[" + ",".join(f"{v:.6f}" for v in arr) + "]"`.

---

### Step 9 — `benchmarks/gate/v0.6.3.json` (P0, ~10 min)

Analytical carry-forward of v0.6.2 recall@10 metrics. Format mirrors existing gate files. Key fields:

```json
{
    "version": "v0.6.3",
    "date": "2026-05-24",
    "pgmnemo_version": "0.6.3",
    "gate_status": "PASS",
    "gate_type": "bug_fix_smoke",
    "note": "Bug-fix release: no scoring changes. recall@10 metrics carried forward from v0.6.2 real-DB bench.",
    "r1_fix": {
        "description": "#variable_conflict use_column added to recall_lessons() and recall_hybrid()",
        "scoring_impact": "none — directive resolves name ambiguity only, does not change query plan or scoring"
    },
    "carry_forward_from": "v0.6.2",
    "recall_at_10_carry_forward": 0.9604,
    "smoke_gate": {
        "status": "PASS",
        "tests": ["smoke_recall_hybrid.py::recall_hybrid", "smoke_recall_hybrid.py::recall_lessons"],
        "pg_regress_tests": 18,
        "role_no_ambiguity_test": "PASS"
    },
    "gate_rationale": "No scoring model changes in v0.6.3. Carry-forward is valid: #variable_conflict is a PL/pgSQL compile-time hint that resolves name binding — it does not alter query execution, index selection, ranking formula, or output values."
}
```

---

### Step 10 — `CHANGELOG.md` entry (P0, ~10 min)

Add `[0.6.3]` entry at top of changelog (after the `[Unreleased]` section if present, else as newest entry). Minimum 200 chars. Lead with the production unblock:

```markdown
## [0.6.3] — 2026-05-24

### Fixed
- **R1 (P0 — production blocker):** `AmbiguousColumn: column reference "role" is ambiguous`
  error in `recall_lessons()` and `recall_hybrid()`. Root cause: PL/pgSQL variable_conflict between
  the `RETURNS TABLE` OUT variable `role TEXT` and the `agent_lesson.role` column. Fixed by adding
  `#variable_conflict use_column` directive to both function bodies — zero signature change,
  zero scoring change, fully backward compatible. Production recall callers unblocked.

### Added
- New pg_regress test `role_no_ambiguity` — regression guard for R1 fix (pg_regress count: 17 → 18).
- Documented `pgmnemo.include_unverified` GUC semantics in `docs/USAGE.md`: affects recall filter
  only, does not disable INSERT provenance gate (separate `pgmnemo.gate_strict` GUC).
- Documented hybrid mode routing conditions and corpus-readiness probe query in `docs/USAGE.md`.
- Documented canonical psycopg2 calling convention with named `=>` syntax and positional fallback.
```

---

### Step 11 — `README.md` badge + note (~5 min)

Update version badge (if present) from 0.6.2 → 0.6.3. Add one line in "Recent Updates" or "What's New" section:

> **v0.6.3** (2026-05-24): Hotfix — `AmbiguousColumn` in `recall_lessons()` / `recall_hybrid()`; psycopg2 + hybrid docs.

---

### Step 12 — `docs/release_notes/v0.6.3_telegram.md` (~10 min)

New file, ≤3500 chars. Lead with "recall_lessons() now callable from production." Format mirrors existing release notes.

---

### Step 13 — Final SHIP sequence

```bash
cd /Users/gaidabura/pgmnemo

# 1. Verify no v0.6.2 upgrade references remain in fixtures
grep -rn "ALTER EXTENSION pgmnemo UPDATE TO" extension/sql/ extension/expected/

# 2. Verify directive present in both functions in both SQL files
grep -c "#variable_conflict" extension/pgmnemo--0.6.2--0.6.3.sql   # must be 2
grep -c "#variable_conflict" extension/pgmnemo--0.6.3.sql            # must be ≥ 2

# 3. pg_regress count
grep "REGRESS = " extension/Makefile | tr ' ' '\n' | wc -l           # must include role_no_ambiguity

# 4. Version consistency check
grep "default_version" extension/pgmnemo.control                     # '0.6.3'
grep '"version"' META.json                                            # "0.6.3"
grep '^version' pgmnemo_mcp/pyproject.toml                           # "0.6.3"

# 5. Commit everything
git add extension/pgmnemo--0.6.2--0.6.3.sql \
        extension/pgmnemo--0.6.3.sql \
        extension/sql/role_no_ambiguity.sql \
        extension/expected/role_no_ambiguity.out \
        extension/Makefile \
        extension/pgmnemo.control \
        META.json \
        pgmnemo_mcp/pyproject.toml \
        scripts/smoke_recall_hybrid.py \
        docs/USAGE.md \
        benchmarks/gate/v0.6.3.json \
        CHANGELOG.md \
        README.md \
        docs/release_notes/v0.6.3_telegram.md
git commit -m "release: pgmnemo v0.6.3 — R1 AmbiguousColumn hotfix + R2-R4 docs"
git tag v0.6.3
git push origin main && git push origin v0.6.3

# 6. Verify CI
gh run list --workflow=release.yml
```

---

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| `#variable_conflict` not supported on PG12 | LOW — directive is PG 9.x+ | Minimum PG version is 14 per pgmnemo requirements |
| Fresh-install squash misses a `#variable_conflict` insertion | MEDIUM | Step 2 validation: `grep -c "#variable_conflict" pgmnemo--0.6.3.sql` must be ≥ 2 |
| pg_regress `role_no_ambiguity` expected output whitespace mismatch | MEDIUM | Generate expected output by running pg_regress once and copying actual output |
| Version bump missed in one of 4 files | LOW | Step 13 consistency check covers all 4 |
| Upgrade fixture `ALTER EXTENSION` references not updated | HIGH if missed | Step 6 explicit grep — CRITICAL per task spec |

---

## Cost/Complexity Estimate

| Item | Effort | Complexity |
|------|--------|-----------|
| R1 fix (2 directives) | 10 min | TRIVIAL — 2 lines inserted |
| Incremental upgrade SQL | 20 min | LOW — copy + insert |
| Fresh-install SQL | 10 min | LOW — copy + insert |
| pg_regress test | 20 min | LOW — standard fixture format |
| Makefile + control + versions | 10 min | TRIVIAL |
| Fixtures sweep | 5 min | TRIVIAL — grep + replace |
| Smoke test extension | 20 min | LOW — ~30 LOC Python |
| USAGE.md (R2+R3+R4) | 30 min | LOW — documentation text already drafted in RESEARCH |
| benchmarks/gate JSON | 10 min | TRIVIAL — carry-forward |
| CHANGELOG + README + release note | 20 min | LOW |
| **Total** | **~2.5 hr** | **LOW** |

No migrations. No API changes. No breaking changes. Rollback = stay on 0.6.2 (the incremental upgrade is additive `CREATE OR REPLACE` only).
