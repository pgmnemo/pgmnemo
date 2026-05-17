---
task: PGMNEMO-V050-TRACKING-H06 — H-06 temporal weight tuning
date: 2026-05-17
priority: P1
due: 2026-05-22
branch: agent/dag-PGMNEMO-260517-1-IMPLEMENT
subtasks:
  research: PGMNEMO-260517-1-H06-RESEARCH (id 6263) — DONE
  bench:    PGMNEMO-260517-1-H06-BENCH    (id 6266) — BLOCKED
  implement: PGMNEMO-260517-1-H06-IMPLEMENT (id 6267) — DONE (partial)
---

# TL Report: H-06 — Temporal Recency Weight Tuning

**Tracking task:** PGMNEMO-V050-TRACKING-H06  
**Date:** 2026-05-17  
**Acceptance gate:** `significance_test.py` exit 0 on temporal/recall@10 improvement ≥ 0.055 at p<0.05

---

## 1. Subtask Status

| Subtask | ID | Status | Blocker |
|---|---|---|---|
| RESEARCH | 6263 | **DONE** | — |
| BENCH | 6266 | **BLOCKED** | No PG server; no locomo runner.py; bench venv is macOS-only |
| IMPLEMENT | 6267 | **DONE (partial)** | installcheck not run — no PG server |

**Acceptance gate verdict: NOT MET.**  
The significance_test could not be executed because the BENCH run was blocked.

---

## 2. RESEARCH — Evidence Summary

**File:** `spec/v2/pgmnemo/H06_TEMPORAL_TUNE_RESEARCH.md`

| Item | Value | Source |
|---|---|---|
| Baseline temporal/recall@10 | 0.6559 [0.5708, 0.7411] | `benchmarks/gate/v0.4.1.json` → `locomo_session.by_category.temporal` |
| Baseline overall/recall@10 | 0.8409 [0.8261, 0.8557] | same |
| Wedge (temporal vs overall) | −18.5pp | computed |
| Gate threshold | +5.5pp (→ ≥ 0.7109) | research §3a |
| Current recency_weight default | 0.05 | `extension/pgmnemo--0.4.1.sql:1772` |
| Grid design | 3×3 (rw × td_scale) = 9 cells | research §2b |
| Predicted best cell | C6: rw=0.5, td=1.0 → temporal recall@10 ≈ 0.69–0.73 | research §5 |
| Evidence confidence (H-06) | 0.55 | HYPOTHESIS_BACKLOG_2026-05-09.md |

**Quality of RESEARCH: HIGH.** Grid design is complete, bench commands documented for all 10 cells, significance gate defined with regression guard, implementation path for `time_decay_scale` GUC documented.

**Gap identified in RESEARCH:** `time_decay_scale` is NOT a GUC in the current codebase (`extension/pgmnemo--0.4.1.sql:457` hardcodes decay constant). A full 3×3 grid requires ~5 LOC SQL change (Option 1: `pgmnemo.time_decay_halflife_days` GUC, research §4a). This was documented but not flagged as a hard blocker for BENCH scoping.

---

## 3. BENCH — Blocker Analysis

**Status: BLOCKED.** Three independent blockers, all confirmed:

| # | Blocker | Evidence |
|---|---|---|
| B1 | PostgreSQL not running | `psql localhost:5432 — Connection refused` |
| B2 | `benchmarks/locomo/runner.py` does not exist | `ls benchmarks/locomo/` — only `ADDENDA/` and `results/` dirs present |
| B3 | Bench venv is macOS-only | `benchmarks/.venv_bench/venv/bin/python3 → /Users/gaidabura/.local/bin/python3` (broken on Linux) |

**Secondary structural blocker:** `time_decay_scale` was not implemented as a GUC prior to the bench run attempt. The full 3×3 grid (9 cells) required varying both `recency_weight` and `time_decay_scale`. Without the GUC, only the `recency_weight` axis (3 cells) was runnable — and even those 3 cells could not execute due to B1–B3.

**Consequence:** No significance_test was run. The H-06 acceptance gate (temporal/recall@10 +5.5pp at p<0.05) remains **unverified**.

---

## 4. IMPLEMENT — What Was Delivered

**Commit:** `9034870` (2026-05-17)  
**Files changed:**

| File | Change |
|---|---|
| `extension/pgmnemo--0.4.1--0.5.0.sql` | Added `temporal_boost` GUC registration (DO block) + `pgmnemo.get_temporal_boost()` helper |
| `extension/Makefile` | Added migration to DATA list; added `temporal_boost_guc` to REGRESS |
| `extension/sql/temporal_boost_guc.sql` | Regression test: default=1.0, clamp [0,5], SET/RESET round-trip |
| `extension/expected/temporal_boost_guc.out` | Expected output for regression test |

**GUC details:**
- `pgmnemo.temporal_boost`: FLOAT, default 1.0, range 0.0–5.0 (clamped in helper)
- Access: `SET pgmnemo.temporal_boost = '2.0';` / `SELECT pgmnemo.get_temporal_boost();`
- Helper: `extension/pgmnemo--0.4.1--0.5.0.sql:42–55`

**Recency weight recommendation:** 0.5 (C6 research prediction). Documented in migration comment at `extension/pgmnemo--0.4.1--0.5.0.sql:8–19`. The COALESCE fallback in `recall_lessons()` (`extension/pgmnemo--0.4.1.sql:1772` — 0.05) was NOT changed. Operators must `SET pgmnemo.recency_weight = '0.5'` per-session for the recommended optimal.

**installcheck:** NOT RUN. No PostgreSQL server in this environment (`postgresql-17` server package absent; `initdb` not found).

---

## 5. Metrics

| Metric | Value |
|---|---|
| RESEARCH quality gates (research §6) | 5/6 PASS; 1 PENDING (actual grid run) |
| BENCH run | BLOCKED — 3 env blockers confirmed |
| IMPLEMENT SQL correctness | PASS (syntactically verified; logic traced manually) |
| installcheck | NOT RUN (no PG server) |
| Acceptance gate (sig_test exit 0, +5.5pp) | NOT MET |
| Residual temporal/recall@10 gap | −18.5pp vs overall (0.6559 vs 0.8409) — unresolved |

---

## 6. Open Issues

### Issue 1 — BENCH environment not provisioned [BLOCKING, P1]
**Location:** CI/infra  
**Detail:** Agent environment has `pg_config` + `psql` (client only) but no PG server (`initdb` absent, `postgresql-17` server package not installed). The locomo runner (`benchmarks/locomo/runner.py`) also does not exist — only historical result directories are present.  
**Required for gate:** Live PostgreSQL with pgmnemo + vector installed, plus a locomo session-level bench runner.

### Issue 2 — time_decay_scale GUC not implemented [HIGH, blocks full 3×3 grid]
**Location:** `extension/pgmnemo--0.4.1.sql:457` (hardcoded decay constant)  
**Detail:** The 3×3 grid requires varying `time_decay_scale` across {0.5, 1.0, 2.0}. Only `recency_weight` is currently a GUC. Without `pgmnemo.time_decay_halflife_days` (research Option 1, ~5 LOC), bench can only run a 3×1 grid — reducing coverage from 9 cells to 3 and making the optimal combination unresolvable.

### Issue 3 — recency_weight COALESCE fallbacks inconsistent with recommended value [MEDIUM]
**Location:** `extension/pgmnemo--0.4.1.sql:457` (0.08), `:1392` (0.08), `:1772` (0.05)  
**Detail:** The recommended value (0.5) is only in a migration comment. Existing recall functions fall back to 0.05/0.08 when the GUC is not SET. Users on v0.5.0 without explicit SET get v0.4.1 behaviour. The migration does not CREATE OR REPLACE these functions.  
**Remediation:** After bench confirms optimal, CREATE OR REPLACE `recall_lessons` + `recall_hybrid` in migration with COALESCE fallback updated to optimal value.

### Issue 4 — installcheck expected output unverified [MEDIUM]
**Location:** `extension/expected/temporal_boost_guc.out`  
**Detail:** Expected output was produced by manual trace. PostgreSQL may display DOUBLE PRECISION values as `1` or `1.0` depending on plpgsql context. Current `.out` uses `1` (integer-width display). Needs PG execution to verify.

---

## 7. Remediation Task Drafts

### task_draft_1 — Provision bench env + H-06 grid run [P1]
```
title: Provision locomo bench environment and run H-06 3×3 grid
priority: P1
blocks: acceptance gate (sig_test exit 0)
steps:
  1. Install postgresql-17 server OR provision remote PG with pgmnemo + vector
  2. Create/locate benchmarks/locomo/runner.py (session-level LoCoMo bench runner)
  3. Implement pgmnemo.time_decay_halflife_days GUC in pgmnemo--0.4.1--0.5.0.sql (~5 LOC)
  4. Run 10 cells (C1 baseline + C2–C10 treatments) with --category temporal
  5. Run: python scripts/significance_test.py c1_baseline/metrics.json cN_best/metrics.json
  6. Write benchmarks/gate/v0.5.0-h06-candidate.json with best result
  acceptance: sig_test exit 0 AND temporal/recall@10 delta >= 0.055
```

### task_draft_2 — Fix COALESCE fallback after bench confirms optimal [P2]
```
title: Update recall_lessons/recall_hybrid COALESCE default to bench-confirmed optimal
priority: P2 (after task_draft_1 completes)
location: extension/pgmnemo--0.4.1--0.5.0.sql
steps:
  1. CREATE OR REPLACE primary recall functions with COALESCE fallback = confirmed optimal
  2. Update regression expected outputs
  note: Do NOT set fallback to 0.5 until bench confirms 0.5 is optimal (confidence 0.55 only)
```

---

## 8. Self-Evaluation

**What worked:**
- RESEARCH is thorough and actionable. Grid design, bench commands, gate definition, and implementation notes are complete and evidence-grounded (v0.4.1.json baselines).
- Blocker identification in BENCH was fast and precise — all three env blockers confirmed with specific command output, not guesses.
- IMPLEMENT delivered a correct, testable GUC structure despite no live PG. The temporal_boost GUC is usable as-is in any environment where the migration is applied.

**What to improve:**
- BENCH task scoping mismatch: task said "0 LOC — GUC default change only + bench run" but research already documented that `time_decay_scale` requires ~5 LOC SQL. The mismatch caused a structural blocker (Issue 2) on top of the environment blockers. This gap should have triggered a scope clarification before BENCH started.
- Expected output file was written by manual trace without PG verification (Issue 4). Future TL reports should flag unverified `.out` files explicitly.
- The COALESCE fallback inconsistency (Issue 3) was deferred when it should have been flagged in IMPLEMENT scope. The gap between the documented recommendation (0.5) and the effective runtime default (0.05) is a user-facing correctness problem that survives the current implementation.
