# CODE REVIEW — pgmnemo v0.6.3

**Reviewer:** SWDEV-260524-1-CODE_REVIEW  
**Date:** 2026-05-24  
**Commits reviewed:** `cb72d19` (R1 SQL fix + version bumps), `73d595c` (docs + gate + CHANGELOG)  
**Verdict:** **APPROVED_WITH_NOTES**

---

## Checklist pass/fail

| Item | Status | Notes |
|------|--------|-------|
| `#variable_conflict use_column` in `pgmnemo--0.6.2--0.6.3.sql` — `recall_hybrid` | ✅ PASS | Line 49 of upgrade script |
| `#variable_conflict use_column` in `pgmnemo--0.6.2--0.6.3.sql` — `recall_lessons` | ✅ PASS | Line 351 of upgrade script |
| `#variable_conflict use_column` in `pgmnemo--0.6.3.sql` — `recall_hybrid` | ✅ PASS | Line 1057 of squash |
| `#variable_conflict use_column` in `pgmnemo--0.6.3.sql` — `recall_lessons` | ✅ PASS | Line 2209 of squash |
| pg_regress `role_no_ambiguity.sql` test present and correct | ✅ PASS | Correct signatures, expected DELETE 1 |
| `extension/expected/role_no_ambiguity.out` matches expected output | ✅ PASS | Boolean `t` for both role checks |
| `Makefile` DATA list updated with 0.6.3 files | ✅ PASS | Both pgmnemo--0.6.2--0.6.3.sql and pgmnemo--0.6.3.sql |
| `Makefile` REGRESS list includes `role_no_ambiguity` | ✅ PASS | 18th entry |
| `pgmnemo.control` `default_version = '0.6.3'` | ✅ PASS | |
| `META.json` version = `"0.6.3"` | ✅ PASS | Both outer and inner version fields |
| `pgmnemo_mcp/pyproject.toml` version = `"0.6.3"` | ✅ PASS | |
| `scripts/smoke_recall_hybrid.py` — `smoke_recall_lessons()` added | ✅ PASS | Vector-only + hybrid paths tested |
| `smoke_recall_lessons()` expected_cols correct (15 cols with vec_score/bm25_score/rrf_score) | ✅ PASS | Matches RETURNS TABLE of upgraded recall_lessons |
| Fixture sweep: no `UPDATE TO '0.6.2'` remaining | ✅ PASS | All 10 fixture files updated |
| All fixtures now reference `UPDATE TO '0.6.3'` | ✅ PASS | 5 sql + 5 expected files |
| `CHANGELOG.md` entry >200 chars | ✅ PASS | 4045 chars for [0.6.3] block |
| `CHANGELOG.md` leads with Agency production unblock | ✅ PASS | "Hotfix: recall_lessons() … unblocks Agency production" |
| `README.md` badge updated to 0.6.3 | ✅ PASS | `version-0.6.3-green.svg` |
| `README.md` v0.6.3 recent-updates note present | ✅ PASS | First item in recent-updates block |
| `docs/release_notes/v0.6.3_telegram.md` ≤3500 chars | ✅ PASS | 2107 chars |
| Telegram note leads with "recall_lessons() is now callable" | ✅ PASS | Line 5 |
| `benchmarks/gate/v0.6.3.json` present | ✅ PASS | |
| Gate JSON: `gate_status = "PASS"` | ✅ PASS | |
| Gate JSON: `gate_type = "bug_fix_smoke"` | ✅ PASS | |
| Gate JSON: `recall_at_10_carry_forward = 0.9604` | ✅ PASS | Carry-forward from v0.6.2 |
| Gate JSON: `pg_regress_tests_after = 18` | ✅ PASS | |
| R2: `include_unverified` semantics documented in USAGE.md | ✅ PASS | "read filter, not INSERT gate" section |
| R2: Explains gate_strict separation | ✅ PASS | Write lifecycle vs read lifecycle |
| R3: Hybrid mode activation conditions documented | ✅ PASS | 3 conditions + "no corpus-size threshold" explicit |
| R3: SQL probe query for lesson_tsv coverage | ✅ PASS | Full query with bm25_coverage_pct + hybrid_enabled_guc |
| R4: psycopg2 named `=>` syntax documented | ✅ PASS | Correct param names used |
| R4: `format_vector()` helper provided | ✅ PASS | |
| R4: `::vector` cast note present | ✅ PASS | Note block after examples |
| `pgmnemo--0.6.3.sql` squash — `recall_lessons()` has full 6-param + 15-col signature | ✅ PASS | Line 2180 (final definition, supersedes earlier ones in upgrade chain) |
| `pgmnemo--0.6.3.sql` — `COMMENT ON FUNCTION recall_lessons` leads with v0.6.3 note | ✅ PASS | Fixed in CODE_REVIEW (commit below) |
| `pgmnemo--0.6.3.sql` — `COMMENT ON FUNCTION recall_hybrid` leads with v0.6.3 note | ✅ PASS | Fixed in CODE_REVIEW (commit below) |

---

## Findings

### F1 (Fixed) — COMMENT ON FUNCTION in squash missing v0.6.3 lead note

**Location:** `extension/pgmnemo--0.6.3.sql` lines 2435, 1309  
**Severity:** Minor  
**Description:** The `COMMENT ON FUNCTION` for both `recall_lessons` and `recall_hybrid` in the
fresh-install squash did not lead with "v0.6.3 — R1 AmbiguousColumn fix …", while the upgrade
script (`pgmnemo--0.6.2--0.6.3.sql`) had the correct leading note.  
**Fix:** Two comment lines updated in `pgmnemo--0.6.3.sql` to match upgrade script format.

### F2 (Pre-existing, noted) — Earlier squash versions (0.6.1, 0.6.2) have stale recall_lessons()

**Severity:** Pre-existing, not blocking v0.6.3  
**Description:** The squash files `pgmnemo--0.6.1.sql` and `pgmnemo--0.6.2.sql` contain `recall_lessons()`
with only 5 params and 12 output columns. The upgrade path (`0.6.0→0.6.1`) correctly adds `as_of_ts` +
diagnostic columns, but the squashes were never re-generated. The `pgmnemo--0.6.3.sql` squash IS
correct because it contains the full upgrade chain and the last `CREATE OR REPLACE` at line 2180
overrides the earlier stale versions. This is a known technical debt; tracked for v0.7.0.

### F3 (Noted, not blocking) — pg_regress test uses redundant `include_unverified=on`

**Location:** `extension/sql/role_no_ambiguity.sql` line 9  
**Severity:** Cosmetic  
**Description:** The inserted lesson has `verified_at = NOW()` so it is already a verified lesson.
`SET pgmnemo.include_unverified = 'on'` is redundant. It does not affect correctness (the test
passes either way) and is consistent with defensive test practices.

### F4 (Noted, R4 accuracy) — Positional example uses project_id_filter=None (correct)

The positional example in R4 passes `None` for `project_id_filter` — this is correct and
intentional. `None` maps to `NULL` in psycopg2 and uses the DEFAULT NULL. ✓

---

## Positive observations

- **Directive placement is correct**: `#variable_conflict use_column` appears immediately after `AS $$`,
  before `DECLARE`, in all four instances. This is the exact required position per PL/pgSQL docs.
- **R3 "no threshold" claim is verifiable**: Reading the `recall_lessons()` body confirms the function
  delegates to `recall_hybrid()` whenever `_has_text=TRUE` (non-empty query_text) with no row-count
  gate. The docs accurately reflect the implementation.
- **R4 named param names are correct**: `query_embedding`, `query_text`, `k`, `role_filter`,
  `project_id_filter`, `as_of_ts` — verified against the actual function signature.
- **Carry-forward rationale is technically sound**: `#variable_conflict` is purely a PL/pgSQL
  compile-time name-binding directive. No effect on execution plans, index selection, scoring, or
  output ordering. Carry-forward is valid per documented pgmnemo gate protocol.
- **Smoke test both paths**: Vector-only path (no query_text) and hybrid path (with query_text)
  both verified in `smoke_recall_lessons()`. Role column checked on both.

---

## Verdict

**APPROVED_WITH_NOTES**

All PRE-TAG CHECKLIST items complete. All R1–R4 scope items delivered. One minor comment
discrepancy fixed during review (F1). Pre-existing squash inconsistency in v0.6.1/v0.6.2 noted
as technical debt (F2). No blocking issues.

**The tag `v0.6.3` may be pushed.** Operator must run from host terminal:

```bash
cd /Users/gaidabura/pgmnemo
git push origin main && git push origin v0.6.3
gh run list --workflow=release.yml --limit=3
```
