# pgmnemo v0.6.0 — Code Review

**Verdict:** CHANGES_REQUESTED  
**Reviewer:** chief_architect (id=86)  
**Date:** 2026-05-22  
**Branch reviewed:** `release/v0.6.0` (merged to `main` at commit `c725e12`)  
**Files reviewed:** `git diff HEAD~3 HEAD --name-only` (12 changed files, 2286 insertions)

---

## Checklist Results

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | `pgmnemo--0.5.2--0.6.0.sql` idempotent | ✅ PASS | All DDL uses `CREATE OR REPLACE` or `DROP FUNCTION IF EXISTS` |
| 2 | No breaking public function signatures | ⚠️ PARTIAL | `recall_hybrid()` unchanged ✓; `recall_lessons()` 5→6 args — technically drops old overload (see §3.4) |
| 3 | ORDER BY normalization divisor correct | ✅ PASS | `(0.4+0.4)/(60+1) = 0.8/61 ≈ 0.013115` verified; test T1 confirms |
| 4 | `as_of_ts IS NULL` path unchanged | ✅ PASS | Dual-condition WHERE preserves v0.5.1 active filter exactly |
| 5 | `ghost_count` matches Agency Q4 spec | ⚠️ PARTIAL | Implementation correct but deviates from spec text (see §3.3) |
| 6 | NOTICE format parseable (Q5) | ✅ PASS | Token "bitemporal close+create fired" present; test verifies indirectly (see §3.5) |
| 7 | All 4 test files syntactically sound | ✅ PASS | Cannot run live against PG17+pgvector 0.7.0 in review; SQL logic verified manually |
| 8 | CHANGELOG customer-readable | ❌ FAIL | Incomplete bench verdict placeholder + jargon terms (see §3.1, §3.2) |
| 9 | No `DROP TABLE`/`DELETE FROM` in migration | ✅ PASS | Verified by `grep -n "DROP TABLE\|DELETE FROM"` — zero matches |

---

## Verdict: CHANGES_REQUESTED

**Required before release tag:**
- §3.1 — Remove/replace incomplete bench verdict placeholder in CHANGELOG.md
- §3.2 — Reduce customer-facing jargon in CHANGELOG.md

**Recommended (acceptable in v0.6.1):**
- §3.3 — Document `ghost_count` spec deviation (`is_active` vs `t_valid_to`)
- §3.4 — Clarify MIGRATION.md wording on `recall_lessons()` signature drop
- §3.5 — NOTICE test coverage note

---

## §1 — Approved items (detail)

### §1.1 Idempotency

`pgmnemo--0.5.2--0.6.0.sql` and `pgmnemo--0.5.1--0.6.0.sql` are functionally identical
(differ only in 4-line header comment block). All DDL:

| Function | Strategy | Idempotent? |
|----------|----------|-------------|
| `recall_hybrid()` | `CREATE OR REPLACE` | ✅ Re-running replaces in place |
| `recall_lessons()` | `DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE` | ✅ `IF EXISTS` = no error if absent |
| `stats()` | `DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE` | ✅ Same |
| `ingest()` | `CREATE OR REPLACE` | ✅ Replaces in place |

No `DROP TABLE`, `DELETE FROM`, or `TRUNCATE` anywhere in migration. ✅

### §1.2 RRF normalization formula

`extension/pgmnemo--0.5.1--0.6.0.sql` line 71:
```sql
_rrf_norm_denom := (vec_weight + bm25_weight) / (_rrf_k_f + 1.0);
```

Default params: `vec_weight=0.4`, `bm25_weight=0.4`, `rrf_k=60` → `_rrf_k_f=60.0`

```
_rrf_norm_denom = (0.4 + 0.4) / (60.0 + 1.0) = 0.8 / 61.0 ≈ 0.013115
```

rrf_diag at rank-1 in both dimensions = `0.4/61 + 0.4/61 = 0.8/61 = 0.013115`  
→ `rrf_diag / norm_denom = 1.0` at joint rank-1 ✅ (per Cormack 2009 normalization)

ORDER BY at line 240 uses `(s.rrf_diag / _rrf_norm_denom)` — identical expression to SELECT
score (lines 213–229). No ORDER BY / SELECT mismatch. ✅

Test `test_v060_rrf_norm.sql` T1–T5 verify:
- T1: `rrf_diag_rank1_both = norm_denom = 0.013115`, `rrf_norm_rank1 = 1.000000`
- T2: Scale-invariant across asymmetric weights
- T3: `rrf_norm ≤ 1.0` for any rank ≥ 1
- T5: Invariant across `rrf_k=30` and `rrf_k=120`

### §1.3 `as_of_ts IS NULL` path — zero regression

`recall_hybrid()` line 117–122:
```sql
AND (
    _as_of_ts IS NULL
    OR (al.t_valid_from <= _as_of_ts AND al.t_valid_to > _as_of_ts)
)
AND (_as_of_ts IS NOT NULL OR al.t_valid_to = 'infinity'::TIMESTAMPTZ)
```

When `_as_of_ts IS NULL` (GUC not set):
- Clause 1: `(TRUE OR ...)` → always passes
- Clause 2: `(FALSE OR al.t_valid_to = 'infinity')` → **identical to v0.5.1 filter** ✅

Same dual-condition pattern appears in `recall_lessons()` vector-only path (lines 461–465).
The `_as_of_ts` in `recall_hybrid()` is populated from GUC (line 74–76); GUC is unset unless
`recall_lessons(as_of_ts)` is called with non-NULL → path is strictly additive. ✅

### §1.4 NOTICE format (Q5)

`extension/pgmnemo--0.5.1--0.6.0.sql` lines 709–713:
```sql
RAISE NOTICE 'pgmnemo.ingest: bitemporal close+create fired — closed % prior version(s) '
             '(content_hash=%). New lesson_id=%. '
             'Prior row(s) now have t_valid_to=NOW().',
             _prior_count, _content_hash, new_id;
```

Parseable token: `"bitemporal close+create fired"`. Structured fields: N, hash, new id.  
Agency Q5 requested `RAISE NOTICE` or second return value. ✅ (NOTICE chosen, documented in Q5 answer.)  
Manual parse command documented in test header: `grep "NOTICE.*bitemporal"`.

### §1.5 Q6 Rollback documentation

`docs/MIGRATION.md §0.5.1→0.6.0 §Rollback` (lines 40–96):
- States explicitly: "PostgreSQL does not support `ALTER EXTENSION pgmnemo UPDATE TO '0.5.1'`" ✅
- Provides COPY backup + pg_dump procedure ✅
- Documents `ACCESS EXCLUSIVE` lock caveat ✅
- Notes "Zero-downtime rollback: not available" ✅

Addresses all three Agency Q6 sub-requests. ✅

### §1.6 Q7 temporal_boost documentation

`docs/USAGE.md` added with recency×boost calibration table matching Agency Q7 request. ✅

---

## §2 — Architecture-level assessment

**Temporal filter implementation:** `pgmnemo.as_of_timestamp` GUC is set as
`transaction-local` via `set_config(TRUE)`. Cleared automatically at COMMIT/ROLLBACK —
no connection pool leakage risk. `PARALLEL UNSAFE` declared on `recall_lessons()` due to
`set_config()`. ✅ Correct.

**`recall_hybrid()` PARALLEL SAFE declared despite reading GUC:** The function uses
`current_setting()` (read-only), not `set_config()`. `current_setting()` is safe in
parallel workers (GUC is visible process-wide). ✅ Correct — the COMMENT documents this.

**DROP + RECREATE of `recall_lessons()` and `stats()`:** Necessary because PostgreSQL
cannot change a function's return type or argument count via `CREATE OR REPLACE`. Using
`DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE` is the correct idiomatic pattern within
extension upgrade scripts. Within `ALTER EXTENSION pgmnemo UPDATE`, grants on functions
owned by the extension are re-granted from `pg_init_privs` — no privilege loss for
extension-managed grants. ✅

---

## §3 — Changes Required / Recommended

### §3.1 ❌ REQUIRED — CHANGELOG: Incomplete bench verdict

**File:** `CHANGELOG.md` line 18–19

```markdown
### Bench verdict

*To be completed in QA_TEST phase. Gate: p < 0.05 AND Δrecall@10 ≥ +1pp on LME-S.*
```

This placeholder is visible to all users who read the changelog. A shipped release must not
contain unfulfilled internal process notes. The benchmark gate belongs in internal ADR /
spec, not the public-facing changelog.

**Required fix:**

Replace lines 18–20 with one of:
```markdown
### Bench verdict

Benchmark gate (p < 0.05, Δrecall@10 ≥ +1 pp on held-out eval set) to be published
in the v0.6.1 QA report.
```

Or remove the section entirely if benchmark results will not be published.

### §3.2 ❌ REQUIRED — CHANGELOG: Customer-unfriendly jargon

**File:** `CHANGELOG.md` lines 22–46

Terms used without explanation:
- `rrf_diag` — internal variable name; customers don't see this
- `fusion_score` — internal; not part of any public API
- `LME-S` — internal benchmark dataset name, unexplained
- `bitemporal close+create` — technical; needs one-sentence explanation

**Required fix (minimal):** Replace or parenthesize internal terms:

| Current | Suggested replacement |
|---------|----------------------|
| `rrf_diag normalized to [0,1]` | `rank-based fusion score normalized to [0,1]` |
| `replacing weighted linear fusion_score` | `replacing the previous weighted linear combination` |
| `LME-S` | `internal evaluation set` |
| `bitemporal close+create` | `dedup trigger (close-and-replace)` |

### §3.3 ⚠️ RECOMMENDED — ghost_count: document spec vs implementation deviation

**File:** `extension/pgmnemo--0.5.1--0.6.0.sql` line 622–626

Agency Q4 spec says: `COUNT(*) WHERE verified_at IS NULL AND is_active = TRUE`

Implementation uses: `WHERE verified_at IS NULL AND t_valid_to = 'infinity'::TIMESTAMPTZ`

These are **not equivalent** because `_bitemporal_close_prior()` trigger (`pgmnemo--0.5.1.sql`
line 2451–2455) only updates `t_valid_to`; it does NOT update `is_active`. A closed row has
`is_active = TRUE` (stale) and `t_valid_to = <close_time>` (correct). The implementation
is **semantically correct** — `t_valid_to = 'infinity'` is the authoritative active-row
indicator. The spec's `is_active = TRUE` is imprecise (stale after bitemporal close).

**Recommended fix:** Add inline comment at line 622:

```sql
-- ghost_count (v0.6.0): active lessons without provenance (Agency RFC Q4)
-- Definition: t_valid_to = 'infinity' (authoritative active-row indicator).
-- NOTE: Agency Q4 spec says "is_active = TRUE"; implementation uses t_valid_to = 'infinity'
-- because _bitemporal_close_prior() does NOT update is_active when closing rows.
-- t_valid_to = 'infinity' is the correct semantic equivalent of "currently active".
```

### §3.4 ⚠️ RECOMMENDED — MIGRATION.md: Clarify recall_lessons() signature precision

**File:** `docs/MIGRATION.md` line 23

```markdown
**None.** All public function signatures remain backward compatible (see [PLAN §2](../spec/v060/PLAN_V060.md)).
```

This is accurate for callers using positional args. However, the old 5-arg overload
`pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT)` is explicitly dropped and recreated
as 6-arg. Any client code that:
- Grants EXECUTE on the old 5-arg form by explicit type signature
- References the function in a `RETURNS TABLE` or `SECURITY DEFINER` wrapper by exact signature

will encounter a break. This is unlikely but not impossible.

**Recommended fix:** Add after line 23:
```markdown
> **Note on `recall_lessons()` signature:** The 5-argument overload is dropped and
> replaced by a 6-argument form (`as_of_ts TIMESTAMPTZ DEFAULT NULL`). Callers using
> positional arguments are unaffected. Explicit GRANTs on the old 5-arg type signature
> must be re-applied to the new 6-arg form after upgrade.
```

### §3.5 ⚠️ RECOMMENDED — test_v060_dedup_notice.sql: NOTICE coverage note

**File:** `tests/sql/test_v060_dedup_notice.sql`

The NOTICE mechanism is never directly asserted — only row state transitions are tested.
The header comment (lines 5–9) correctly documents the pgregress limitation and the manual
verification command. This is acceptable.

**Recommended addition** at end of file (before cleanup):
```sql
-- ─── T8: document direct NOTICE verification command ─────────────────────────
-- To assert the NOTICE fires and format matches, run:
--   psql "$DSN" -v ON_ERROR_STOP=1 -f tests/sql/test_v060_dedup_notice.sql 2>&1 \
--     | grep -c "NOTICE.*bitemporal close+create fired"
-- Expected: ≥ 2 (fires for T2 and T5)
```

---

## §4 — Summary

**Core functionality:** Correct. Fix-A math verified, temporal filter is regression-free,
migration is idempotent, Q4/Q5/Q6/Q7 are addressed.

**Blocking for release tag:** 2 items (§3.1, §3.2) — CHANGELOG quality only.

**Non-blocking:** 3 items (§3.3, §3.4, §3.5) — documentation precision + test note.

None of the blocking items require SQL changes — CHANGELOG edits only. The SQL, tests,
and architecture are sound.

---

*Reviewed by chief_architect (id=86). Required §3.1+§3.2 edits must be committed before
the v0.6.0 release tag is created.*
