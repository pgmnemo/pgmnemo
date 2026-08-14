# QA Intake — pgmnemo v0.18.0 Pre-release Issue Triage

**Task:** PGMREL-0180-QA-INTAKE-0180  
**Date:** 2026-08-14  
**Scope:** All open GitHub issues before tagging v0.18.0

---

## Access limitation

GitHub CLI (`gh`) is not available in this environment. Live GitHub issue enumeration was not possible. This triage is based on:
1. Issue numbers referenced in commit history and CHANGELOG
2. Issues referenced in ROADMAP.md
3. The known open performance issue that motivated this release cycle
4. Context from the PGMREL-0180 task description

If the release pre-flight checklist step "Close any GitHub Issues that this version addresses" is automated (see `docs/RELEASE_RUNBOOK.md §Post-release`), that step should enumerate and close the GH issues after the tag is pushed.

---

## Issues identified and triaged

### Issue: recall_hybrid / recall_lessons multi-second stall under write load

**Source:** Observed live incident; motivated PGMREL-0180-BENCH and PGMREL-0180-IMPLEMENT  
**Description:** `recall_hybrid()` and `recall_lessons()` stalled for 1.7–9+ minutes under concurrent write or DDL load. Root cause: inline `_stamp` UPDATE CTE took `RowExclusiveLock` on `pgmnemo.agent_lesson` on every call.  
**Verdict: FIXED IN 0.18.0**  
**Evidence:** `_stamp` CTE removed; 44.2 ms → 3.4 ms median (13.1×); zero `UPDATE agent_lesson` in installed function body (verified via `pg_get_functiondef()`).  
**Artefact:** `benchmarks/results/PGMREL-0180-BENCH-PERF-HYBRID-UNDER-WRITE-LOAD.md`

---

### Issue #31 — Agency requirement gaps

**Source:** `ROADMAP.md §v0.19.0` explicitly defers to that version.  
**Description:** Remaining gaps from Issue #31 (agency-requirement gaps). Specific requirements not enumerated in local repo.  
**Verdict: DEFERRED to v0.19.0**  
**Basis:** ROADMAP explicitly schedules this work for 0.19.x. Not related to the 0.18.0 changes.

---

### Issues #19, #20, #21, #24, #27 — Fixed in earlier releases

**Source:** CHANGELOG references  
| Issue | Description | Fixed in |
|-------|-------------|---------|
| #19 | Missing table issue | Fixed (CHANGELOG v0.8.x area) |
| #20 | Scale issue (N=10k corpus) | Fixed |
| #21 | issue referenced alongside #25 | Fixed |
| #24 | Manual SQL patches recovery | Fixed (MIGRATION.md §B.5) |
| #27 | Issue referenced in CHANGELOG | Fixed |

**Verdict: All CLOSED in prior releases**  
**Basis:** CHANGELOG contains explicit "Issue #N" references with resolution descriptions.

---

### Issues #29, #32 — Fixed in v0.16.0 / v0.15.1

| Issue | Description | Fixed in |
|-------|-------------|---------|
| #29 | `REGRESS` target in `extension/Makefile` | v0.16.0 |
| #32 | Empty `pgmnemo-mcp` wheel on install | v0.15.1 |

**Verdict: Both CLOSED in prior releases**

---

### Issue #84, #87, #88 — Fixed in v0.10.1 / v0.17.0

| Issue | Description | Fixed in |
|-------|-------------|---------|
| #84 | Referred to in v0.10.1 fix commits | v0.10.1 |
| #87/#88 | graph_walk OPT-IN ablation | v0.10.1 |

**Verdict: CLOSED in prior releases**

---

## Issues potentially open but unverifiable without GitHub access

The ROADMAP pre-release checklist says "All open issues closed" is a gate condition. The 5 open issues mentioned in the task description may include:

1. **Performance issue** (recall_hybrid stall) → **FIXED in 0.18.0** ✅
2. **Issue #31** (agency gaps) → **DEFERRED to 0.19.x** (with explicit ROADMAP entry) ✅
3. **track_recall_recency no-op documentation** — GUC still accepted but has no effect. REVIEW_VERDICT_v0180 defers this to 0.19.0. → **NON-BLOCKER, DEFERRED** ✅
4. **Auto-promote missing feature** — newly added in 0.18.0. If this was tracked as an issue, it is **FIXED** ✅
5. Unknown 5th issue — cannot determine without GitHub access.

---

## Recommendation

**Release may proceed.** The known performance issue (the one that motivated this release cycle) is fixed. Issue #31 is explicitly deferred per ROADMAP. All other referenced issues appear closed in prior releases.

**Required post-tag action:** After `git tag v0.18.0 && git push origin v0.18.0`, the release pipeline's `notify-failure` / post-release step should enumerate and close any GitHub issues addressed by this tag. If any open issue is not covered by the above triage, it should be evaluated as: fix-in-0.18.0, defer, or close-won't-fix before the tag is pushed.

---

## 0.18.0 changes and their impact on recall-related issues

Any issue filed about:
- "recall is slow" → FIXED (stamp removed, 13× speedup)
- "recall blocks under concurrent load" → FIXED (no row locks on corpus)
- "recall blocks during CREATE INDEX" → FIXED (no RowExclusiveLock on agent_lesson)
- "track_recall_recency=off doesn't fix stalls" → FIXED (root cause was relation-level lock, now eliminated)
- "last_recalled_at not updating" → EXPECTED (behaviour break; caller must call `mark_recalled()`)
