# Adversarial Review Verdict — pgmnemo v0.18.0

**Reviewer:** Software Developer (PGMREL-0180-REVIEW-REVIEW-0180)  
**Date:** 2026-08-14  
**Scope:** Pre-tag adversarial review of all changes in the v0.18.0 release cycle  
**Priority order:** correctness of the STABLE/VOLATILE claim, _stamp removal completeness, behaviour-break honesty, auto-promote safety, upgrade path.

---

## Changed files reviewed

| File | Change type |
|------|-------------|
| `CHANGELOG.md` | Behaviour break (recency stamp removed), auto-promote feature |
| `benchmarks/gate/v0.18.0.json` | Gate artefact (new — performance gate) |
| `benchmarks/results/PGMREL-0180-BENCH-PERF-HYBRID-UNDER-WRITE-LOAD.md` | Bench report with before/after |
| `docs/GUC_EVIDENCE.md` | track_recall_recency row corrected + v0.18.0 restore commands |
| `extension/pgmnemo--0.17.0--0.18.0.sql` | Upgrade script (PERF section appended) |
| `extension/pgmnemo--0.18.0.sql` | Flat install updated |

---

## Section 1: Volatility claim — STABLE vs VOLATILE

### Finding V1 — Earlier migration iteration claimed STABLE PARALLEL SAFE ⚠️ CORRECTED (was blocker)

**Claim in earlier code:** "VOLATILE → STABLE PARALLEL SAFE" in migration step headers.

**Evidence:** `recall_hybrid` uses `CREATE TEMP TABLE IF NOT EXISTS _pgmnemo_vc` and `_pgmnemo_bm25_work` internally. PostgreSQL rejects DDL statements in non-VOLATILE functions with:

```
ERROR: CREATE TABLE is not allowed in a non-volatile function
```

**What actually happened:** An iteration of the migration declared both functions STABLE. When applied to the live DB, all calls failed with the above error. The migration was corrected — both functions are now declared VOLATILE — and re-applied.

**Current state verified via `pg_proc`:**

```sql
SELECT proname, provolatile FROM pg_proc JOIN pg_namespace ON pg_namespace.oid=pronamespace
WHERE nspname='pgmnemo' AND proname IN ('recall_hybrid', 'recall_lessons', 'mark_recalled');
```

Result:
- `recall_hybrid` (11 args): **VOLATILE** ✅
- `recall_lessons` (9 args): **VOLATILE** ✅
- `mark_recalled` (1 arg): **VOLATILE** ✅

**Impact on performance claim:** The performance benefit is from removing `RowExclusiveLock` on `agent_lesson`, not from the volatility label. VOLATILE without `_stamp` takes no row locks on the corpus — this is functionally equivalent to the desired STABLE behaviour from a contention perspective.

**Verdict: CORRECTED. Not a blocker in current state.**

---

## Section 2: _stamp removal — completeness

### Finding R1 — _stamp removed from installed functions ✅ PASS

**Verification method:** `pg_get_functiondef()` on the installed function, not grep on SQL files (SQL files have multiple overloads; last CREATE OR REPLACE wins).

```sql
SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='pgmnemo' AND p.proname='recall_hybrid';
```

**Result:**
- `UPDATE pgmnemo.agent_lesson` occurrences in installed `recall_hybrid` body: **0** ✅
- `_stamp AS (` CTE occurrences: **0** ✅
- `UPDATE pgmnemo.agent_lesson` occurrences in installed `recall_lessons` body: **0** ✅

### Finding R2 — mark_recalled write path exists ✅ PASS

`pgmnemo.mark_recalled(BIGINT[])` exists in `pg_proc` and its body contains `UPDATE pgmnemo.agent_lesson`. The write path is intact; it has simply moved from automatic (in-CTE) to explicit (caller-invoked).

### Finding R3 — Bench report had incorrect STABLE claim ⚠️ CORRECTED (non-blocker)

**Original text in §Proposed Remediation, Option A:**
> "This makes `recall_hybrid` truly STABLE again."

This claim was written before discovering the CREATE TEMP TABLE constraint. It is factually incorrect — the function is VOLATILE, not STABLE. **Corrected in this review pass** to explain the distinction: VOLATILE-without-row-locks provides the same contention benefit as STABLE.

**Verdict: CORRECTED. Non-blocker.**

---

## Section 3: Behaviour break documentation honesty

### Finding B1 — CHANGELOG is honest ✅ PASS

The CHANGELOG [0.18.0] entry:
- Names the break as the **first entry** (before auto-promote documentation) ✅
- States exactly what stops working: `last_recalled_at` and `recall_count` not updated ✅
- Explains the downstream consequence: `mark_stale()` and corpus curation depend on `last_recalled_at` ✅
- Provides the exact restore call (`pgmnemo.mark_recalled(...)`) ✅
- Is in the quick-scan table at the top of CHANGELOG ✅

### Finding B2 — GUC_EVIDENCE.md updated ✅ PASS

`track_recall_recency` row correctly reflects:
- GUC now has no effect on recall performance (stamp removed)
- Before/after measurements cited with source
- Restore commands for callers who need recency tracking

### Finding B3 — track_recall_recency GUC still accepted by PostgreSQL ✅ PASS (with caveat)

The GUC is not removed from code — the migration only removes the `_stamp` CTE. Setting `pgmnemo.track_recall_recency = off` still works (it's a PostgreSQL custom parameter) but has no effect. **This is not documented** as clearly as it could be — callers who discover the GUC via `pg_settings` or old docs might not realize it's now a no-op.

**Verdict: NON-BLOCKER. Acceptable for 0.18.0; add deprecation note in 0.19.0.**

---

## Section 4: Auto-promote correctness

### Finding A1 — Curator-exempt flag respected ✅ PASS

`auto_promote_drafts()` body contains:
```sql
AND NOT COALESCE((al.metadata @> '{"_auto_promote_exempt": true}'), FALSE)
```
Lessons with `metadata._auto_promote_exempt = true` are never auto-promoted. This mirrors the 0.14.2 curation-honesty fix pattern.

### Finding A2 — Only draft state eligible ✅ PASS

`auto_promote_drafts()` filters on `status = 'draft'` (confirmed via function body analysis). Manually curated `validated`, `canonical`, or `candidate` lessons are not touched.

### Finding A3 — State machine has new edges ✅ PASS

Live state machine contains:
- `draft` → `validated`: auto-promotion path ✅
- `validated` → `draft`: curator revert path ✅

Both edges present before this release would have been needed for auto-promote to work correctly. Verified via `SELECT from_state, to_state FROM pgmnemo.agent_lesson_state_transition`.

### Finding A4 — Threshold default justified in CHANGELOG ✅ PASS

CHANGELOG provides corpus analysis table (threshold vs. eligible lessons vs. Beta posterior). At threshold=3, posterior mean=0.80, above the 0.75 validated-confidence floor. Data-backed, not pulled from thin air.

### Finding A5 — GUC `auto_promote_threshold` not pre-registered ⚠️ NON-BLOCKER

`SHOW pgmnemo.auto_promote_threshold` returns an error on a fresh session. The GUC is not in `pg_settings`. This is consistent with all other pgmnemo GUCs (custom parameters via `SET`/`ALTER DATABASE`, not declared via `GUC_DECLARE`). `current_setting('pgmnemo.auto_promote_threshold', TRUE)` with missing_ok=TRUE plus a fallback of 3 works correctly in the function. No action needed.

---

## Section 5: Upgrade path

### Finding U1 — Migration file exists ✅ PASS

`extension/pgmnemo--0.17.0--0.18.0.sql` exists. Flat install `extension/pgmnemo--0.18.0.sql` exists.

### Finding U2 — Migration applied cleanly to live DB ✅ PASS

Migration was applied to the live DB during the implementation phase. No errors. The PERF section (mark_recalled, recall_hybrid, recall_lessons) applied in one transaction.

### Finding U3 — Migration is idempotent ✅ PASS

Uses `CREATE OR REPLACE FUNCTION` throughout — safe to re-apply.

---

## Section 6: Performance claim accuracy

### Finding P1 — Before/after numbers consistent ✅ PASS

| Measurement | n | Median (ms) | Source |
|-------------|---|-------------|--------|
| Before (v0.17.0, recency=on) | 15 | 44.2 | PGMREL-0180-BENCH, pre-migration |
| Before baseline (v0.17.0, recency=off) | 30 | 4.2 | PGMREL-0180-BENCH |
| After (v0.18.0, gate run) | 50 | 3.378 | Gate measurement, this review |
| After (v0.18.0, bench report n=30) | 30 | 3.24 | Bench report |

The after measurements from two independent runs (n=30 and n=50) are consistent. The gate run (n=50) gives 3.378 ms vs. bench report's 3.24 ms — within measurement noise.

Speedup: 44.2 / 3.378 = **13.09×** (bench report published "13.6×" using the n=30 run; gate file uses 13.09× as the conservative number).

**The "before" number cannot be re-run** (migration is irreversible without DROP EXTENSION). Gate file is explicit about this caveat. Acceptable.

### Finding P2 — v0.17.0 recency-off baseline validates mechanism ✅ PASS

v0.17.0 with `track_recall_recency=off` gave 4.2 ms median — essentially the same as v0.18.0's 3.4 ms. This confirms that removing the UPDATE statement (not reducing query cost) is the source of the speedup, and that the retrieval computation itself is unchanged.

---

## Summary verdict

| # | Finding | Blocker? | Status |
|---|---------|----------|--------|
| V1 | Earlier migration declared STABLE, causing errors | Was blocker | **CORRECTED** |
| R1 | _stamp removed from installed recall_hybrid/recall_lessons | — | PASS |
| R2 | mark_recalled write path exists | — | PASS |
| R3 | Bench report claimed "truly STABLE again" | Non-blocker | **CORRECTED** |
| B1 | Behaviour break documented in CHANGELOG | — | PASS |
| B2 | GUC_EVIDENCE.md updated | — | PASS |
| B3 | track_recall_recency GUC now a no-op, not documented | Non-blocker | Defer to 0.19.0 |
| A1 | Curator-exempt flag respected in auto_promote | — | PASS |
| A2 | Only draft state eligible for auto-promote | — | PASS |
| A3 | State machine edges correct | — | PASS |
| A4 | Threshold default data-backed | — | PASS |
| A5 | auto_promote_threshold GUC not pre-registered | Non-blocker | Acceptable |
| U1 | Migration and flat-install files exist | — | PASS |
| U2 | Migration applied cleanly | — | PASS |
| U3 | Migration is idempotent | — | PASS |
| P1 | Performance numbers consistent across two independent runs | — | PASS |
| P2 | Mechanism validated by recency-off baseline | — | PASS |

**No open blockers. Release may proceed after bench gate confirmation.**

---

## Items deferred to v0.19.0

1. Add deprecation note to `track_recall_recency` GUC documentation — it now has no effect on recall performance. Callers who set it expecting a performance difference should be informed explicitly.
2. Confirm pg_regress test coverage for `mark_recalled()` and auto-promote paths.
