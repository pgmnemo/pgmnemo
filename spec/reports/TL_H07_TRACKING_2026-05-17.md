---
task: PGMNEMO-V050-TRACKING-H07 — H-07 Bitemporality Primitive
date: 2026-05-17
priority: P1 (sprint), P2 (roadmap)
due: 2026-05-22
branch: agent/dag-PGMNEMO-260517-1-IMPLEMENT
subtasks:
  research: PGMNEMO-260517-1-H07-RESEARCH (id 6264) — DONE
  plan:     PGMNEMO-260517-1-H07-PLAN     (id 6268) — DONE
  implement: PGMNEMO-260517-1-H07-IMPLEMENT (id 6275) — DONE (partial)
  bench:    PGMNEMO-260517-1-H07-BENCH    (id 6276) — BLOCKED
---

# TL Report: H-07 — Bitemporality Primitive

**Tracking task:** PGMNEMO-V050-TRACKING-H07  
**Date:** 2026-05-17  
**Acceptance gate:** `significance_test.py` exit ≤ 1 on ALL benchmark cells (no recall regression); schema additive

---

## 1. Subtask Status

| Subtask | ID | Status | Blocker |
|---|---|---|---|
| RESEARCH | 6264 | **DONE** | — |
| PLAN | 6268 | **DONE** | — |
| IMPLEMENT | 6275 | **DONE (partial)** | installcheck not run — no PG server |
| BENCH | 6276 | **BLOCKED** | `scripts/run_bench.py` missing; PostgreSQL not running |

**Agent success rate:** 3/4 subtasks completed (75%). 1 ESCALATED (BENCH).  
**ESCALATED count:** 1 (BENCH #6276)  
**Stalled runs:** 0  
**Acceptance gate verdict: NOT MET** — significance_test.py not run.

---

## 2. RESEARCH — Evidence Summary

**File:** `spec/v2/pgmnemo/H07_BITEMPORALITY_RESEARCH.md`

| Item | Value | Source |
|---|---|---|
| Target table | `pgmnemo.agent_lesson` (not `mem_item` — clarified) | pgmnemo--0.4.1.sql:75 |
| `mem_item` resolution | View alias: `agent_lesson WHERE t_valid_to = 'infinity'` | Research §1a |
| `content_hash` | Does not exist pre-H-07; GENERATED ALWAYS AS MD5(role\|topic\|commit_sha/artifact_hash) STORED | Research §1b |
| `mem_edge` pattern | Already has `valid_from`/`valid_until` (pgmnemo--0.4.1.sql:278-280) — H-07 consistent | Research §1c |
| Recall-path impact | Zero — additive schema; `recall_lessons()` unchanged | Research §3a |
| Rollback risk | LOW — all additions new in v0.5.0; FK ON DELETE CASCADE preserved | Research §5 |

**Quality of RESEARCH: HIGH.** All 9 quality gates PASS; 1 PENDING (live PG verification).

---

## 3. PLAN — Evidence Summary

**File:** `spec/v2/pgmnemo/H07_BITEMPORALITY_PLAN.md`  
**ICE score:** Impact=7, Confidence=8, Ease=7 → composite **7.3**

| Gate | Status |
|---|---|
| ICE computed | PASS |
| DDL target confirmed | PASS — `agent_lesson` |
| `content_hash` designed | PASS — MD5 GENERATED ALWAYS AS STORED; NULL-safe |
| Idempotency verified (11 statements) | PASS — table in Plan §4 |
| Rollback SQL complete | PASS — DROP sequence in dependency order |
| Recall-path impact | PASS — additive; scoring path unmodified |
| Acceptance gate defined | PASS — sig_test exit ≤ 1; smoke test in §6c |
| Live PG verification | PENDING |

---

## 4. IMPLEMENT — What Was Delivered

**Commits:** `e4a49c1` (plan doc initial), `30871be` (DDL + regression test), `ca4c852` (plan update)

### 4a. Migration SQL (extension/pgmnemo--0.4.1--0.5.0.sql)

**CRITICAL: Duplicate DDL block detected — see Issue 1.**

The migration file (520 LOC total) contains two complete H-07 DDL blocks:

| Block | Lines | Source |
|---|---|---|
| Block A (PLAN edit) | 312–399 | Agent `Edit` during PLAN task |
| Block B (IMPLEMENT hook) | 401–520 | Pre-commit hook from IMPLEMENT commit `30871be` |

Both blocks are idempotent-guarded (`IF NOT EXISTS` / `OR REPLACE`). On migration run, Block A executes first; Block B is a complete no-op. **No runtime error occurs.** Block B is the authoritative version (richer COMMENTs, `COMMENT ON COLUMN` statements, step labels).

DDL objects present (in Block B, the keeper):

| Object | Location | Idempotent guard |
|---|---|---|
| `t_valid_from` column | line 419 | `ADD COLUMN IF NOT EXISTS` |
| `t_valid_to` column | line 420 | `ADD COLUMN IF NOT EXISTS` |
| `content_hash` generated column | line 421 | `ADD COLUMN IF NOT EXISTS` |
| Backfill UPDATE | line 447 | time-window condition |
| `ix_agent_lesson_valid_range` index | line 451 | `CREATE INDEX IF NOT EXISTS` |
| `ix_agent_lesson_content_hash_active` index | line 455 | `CREATE INDEX IF NOT EXISTS` |
| `pgmnemo._bitemporal_close_prior()` trigger fn | line 461 | `CREATE OR REPLACE FUNCTION` |
| `trg_agent_lesson_bitemporal_close` trigger | line 485 | `DROP IF EXISTS` + `CREATE` |
| `pgmnemo.mem_item` view | line 491 | `CREATE OR REPLACE VIEW` |
| `pgmnemo.as_of(TIMESTAMPTZ)` function | line 503 | `CREATE OR REPLACE FUNCTION` |

### 4b. Regression test files

| File | LOC | Status |
|---|---|---|
| `extension/sql/bitemporality_smoke.sql` | 74 | PRESENT |
| `extension/expected/bitemporality_smoke.out` | 107 | PRESENT |
| `extension/Makefile` REGRESS | `bitemporality_smoke` added | PRESENT |

**installcheck:** NOT RUN — PostgreSQL server not installed (`initdb` absent).

---

## 5. BENCH — Blocker Analysis

| Blocker | Evidence |
|---|---|
| `scripts/run_bench.py` missing | `ls scripts/run_bench.py` → `No such file or directory` |
| PostgreSQL not running | `psql localhost:5432` → `Connection refused` |

This is the **4th consecutive BENCH task** blocked by these same two root causes (H-02, H-06, H-07 all blocked identically). The underlying infra gap must be resolved as a one-time systemic fix.

**Expected result if bench ran:** Exit ≤ 1 — no significant change expected. The `recall_lessons()` / `recall_hybrid()` scoring path is unmodified. The AFTER INSERT trigger fires only on INSERT, not on SELECT. The partial index `WHERE t_valid_to = 'infinity'` keeps query planning unchanged for the recall path.

---

## 6. Metrics

| Metric | Value |
|---|---|
| RESEARCH quality gates | 9/9 design gates PASS; 1 PENDING (live PG) |
| PLAN ICE score | 7.3 (I=7, C=8, E=7) |
| IMPLEMENT: migration DDL present | PASS — but duplicated (Issue 1) |
| IMPLEMENT: idempotency | PASS — all 11 statements guarded in both blocks |
| IMPLEMENT: regression test | PASS — SQL + expected output + Makefile present |
| installcheck | NOT RUN (no PG server) |
| BENCH run | BLOCKED (2 independent blockers) |
| Acceptance gate (sig_test exit ≤ 1) | NOT MET |
| Recall regression risk | LOW — additive schema; trigger on INSERT path only |

---

## 7. Open Issues

### Issue 1 — Duplicate H-07 DDL block in migration [HIGH, pre-release blocker]
**Location:** `extension/pgmnemo--0.4.1--0.5.0.sql:312–399` (Block A, PLAN edit) and `:401–520` (Block B, hook IMPLEMENT)  
**Detail:** Both blocks are idempotent so the migration runs without error, but the file is 260 LOC larger than necessary. Block A has minimal comments; Block B is the complete authoritative version with COMMENT ON COLUMN statements.  
**Fix:** Delete lines 310–399 (Block A). Block B (lines 401–520, hook IMPLEMENT commit `30871be`) is the authoritative keeper.  
**Priority:** HIGH — must fix before v0.5.0 release review.

### Issue 2 — installcheck expected output unverified [MEDIUM]
**Location:** `extension/expected/bitemporality_smoke.out`  
**Detail:** The 107-line expected output was produced by the hook without running against live PostgreSQL. The `ALTER EXTENSION pgmnemo UPDATE TO '0.5.0'` upgrade path, DOUBLE PRECISION display format, and `information_schema` query results all need live PG confirmation.  
**Priority:** MEDIUM — after bench infra is provisioned (Issue 4).

### Issue 3 — `mem.as_of` naming discrepancy vs `pgmnemo.as_of` [LOW]
**Location:** Task spec says `mem.as_of()`; `extension/pgmnemo--0.4.1--0.5.0.sql:501–502` says `pgmnemo.as_of()`  
**Detail:** `extension/pgmnemo.control` sets `schema = pgmnemo`. The `mem.as_of` in the spec is documentation shorthand, not a valid PostgreSQL schema reference. Implementation is correct. Migration comment at line 501–502 documents the discrepancy.  
**Priority:** LOW — no code change needed; clarify in ROADMAP.md.

### Issue 4 — BENCH infrastructure systemic gap [P1, systemic across all hypotheses]
**Location:** `scripts/run_bench.py` (absent); `localhost:5432` (no PG server)  
**Detail:** 4th consecutive BENCH block. H-02, H-06, H-07, and H-07 BENCH all fail on the same two root causes. No individual hypothesis can reach its acceptance gate.  
**Priority:** P1 — must resolve before any v0.5.0 acceptance gate can be verified.

---

## 8. Remediation Task Drafts

### task_draft_1 — Remove duplicate H-07 DDL block [HIGH, ~5 min]
```
title: Remove Block A (duplicate) H-07 DDL from pgmnemo--0.4.1--0.5.0.sql
priority: HIGH
file: extension/pgmnemo--0.4.1--0.5.0.sql
action: Delete lines 310–399 (the PLAN-task-appended block);
        keep lines 401–520 (hook IMPLEMENT block — authoritative)
verify: grep -c "ADD COLUMN IF NOT EXISTS t_valid_from" extension/pgmnemo--0.4.1--0.5.0.sql
        should return 1 after deletion
acceptance: single occurrence of each DDL object; migration runs without error on fresh PG
```

### task_draft_2 — Provision bench infrastructure [P1, systemic]
```
title: Provision bench environment — create scripts/run_bench.py + PG server
priority: P1
blocks: H-02, H-06, H-07 acceptance gates
steps:
  1. Install postgresql-17 server + initdb OR provision remote PG
  2. Install pgvector; CREATE EXTENSION pgmnemo; run 0.4.1→0.5.0 migration
  3. Create scripts/run_bench.py wrapping longmemeval/runner.py and locomo runners
     with --output flag writing gate-format JSON to benchmarks/gate/
  4. Rebuild bench venv on Linux (current venv has macOS python3 symlink)
acceptance: psql localhost/pgmnemo_bench -c "SELECT pgmnemo.version()" returns '0.5.0'
            python scripts/run_bench.py --dry-run exits 0
```

### task_draft_3 — Verify + fix installcheck for bitemporality_smoke [P2]
```
title: Run make installcheck; update bitemporality_smoke.out if needed
priority: P2 (after task_draft_2)
file: extension/expected/bitemporality_smoke.out
action: cd extension && make installcheck;
        diff extension/expected/bitemporality_smoke.out extension/results/bitemporality_smoke.out;
        update expected if diff non-empty
acceptance: make installcheck exits 0; regression.diffs empty
```

---

## 9. Self-Evaluation

**What worked:**
- RESEARCH delivered all 9 design-level gates: `mem_item` table discrepancy resolved (view alias, not migration), `content_hash` designed from scratch, `mem_edge` consistency verified, NULL-safe trigger edge cases documented. This is the correct level of pre-implementation analysis.
- PLAN produced a complete ICE score (7.3), 11-statement idempotency proof table, and dependency-ordered rollback SQL in one document before any migration code was written — correct sequencing.
- IMPLEMENT DDL is functionally correct: all `IF NOT EXISTS` / `CREATE OR REPLACE` guards present, trigger is NULL-safe (`IF NEW.content_hash IS NOT NULL`), backfill UPDATE is time-bounded (`WHERE t_valid_from >= now() - INTERVAL '1 second'`), `as_of()` uses correct half-open interval (`t_valid_from <= ts AND t_valid_to > ts`). The hook IMPLEMENT commit produced richer, better-commented DDL.

**What to improve:**
- **PLAN tasks should not write migration SQL.** The PLAN task's `Edit` that appended DDL to `pgmnemo--0.4.1--0.5.0.sql` was a scope violation — PLAN tasks should only output plan documents. This created the duplicate block (Issue 1). IMPLEMENT tasks should have exclusive write authority over migration files.
- **Pre-commit should lint for duplicate SQL objects.** A `grep -c "ADD COLUMN IF NOT EXISTS t_valid_from" extension/pgmnemo--0.4.1--0.5.0.sql > 1` check in the pre-commit hook would have caught the duplicate immediately.
- **BENCH pre-flight check must be mandatory.** Adding `ls scripts/run_bench.py && psql -c 'SELECT 1'` as the first two lines of every BENCH task body would fail fast in 2 seconds instead of consuming a full agent turn reporting the same blockers for the 4th time.
- **Systemic infra task should be P0 blocker.** After H-02 BENCH was blocked, task_draft_2 (bench infra provisioning) should have been created and tracked as a dependency for H-06 and H-07 BENCH tasks. Instead, each BENCH task independently discovered and reported the same blockers.
