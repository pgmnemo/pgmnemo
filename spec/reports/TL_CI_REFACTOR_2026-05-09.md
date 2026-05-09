---
task: CI-REFACTOR — Switch CI from service-container PG to host-PG install
date: 2026-05-09
priority: P3
due: 2026-05-16
---

# TL Report: CI-REFACTOR

## Findings

### Pre-existing state (before this run)

The CI workflow (`.github/workflows/ci.yml`) had already been partially refactored in a prior commit: the pgvector/pgvector:pg17 service container was removed and replaced with apt-install of `postgresql-17` + `postgresql-17-pgvector`. Host PG on port 5433 (via `pg_createcluster`) was already in use.

**Remaining problem:** `continue-on-error: true` on the `Run installcheck` step (line 35 before this change) caused GitHub Actions to emit a yellow warning icon rather than a hard failure when tests failed. The complex 4-step baseline-reset scaffold (auto-commit expected files, re-run) also depended on `continue-on-error` to function correctly, and the `permissions: contents: write` was only needed for that git-push path.

**Secondary finding:** `release.yml` (lines 11–19) still uses `pgvector/pgvector:pg17` service container and installs only `postgresql-server-dev-17` (no pgvector apt package). This is out of scope for this task but is a latent parity gap.

### DB metrics (tasks, 2026-05-09)

| Metric | Value |
|---|---|
| Total tasks | 5,013 |
| DONE | 2,313 |
| CANCELED | 1,716 |
| INBOX | 627 |
| ESCALATED | 38 |
| DELEGATED | 12 |
| Agent success rate (DONE / total) | **46.1%** |
| Stalled (ESCALATED) | **38** |

### Top ESCALATED (P1, due soonest)

| ID | Title | Due |
|---|---|---|
| 5206 | [ACTIVATE-2] Hyperparameter calibration — grid search | 2026-05-11 |
| 4651 | [INCIDENT:dag_master_burn] 4 dag_master FAILED — $3.90 burn | 2026-05-10 |
| 5247 | [UI-TASK-CARD-RUNS] Surface run aggregates on TaskCard | 2026-05-13 |
| 5243 | [INFRA-PHANTOM-DELEGATED] Fix auto_complete_task race | 2026-05-16 |
| 5358 | [INFRA-SDK-HANG-1] Diagnose + fix SDK_HANG_PATTERN flood | 2026-05-14 |

## Changes made

**File:** `.github/workflows/ci.yml`

1. Removed `permissions: contents: write` (no longer needed; git-push path removed)
2. Removed `id: installcheck` and `continue-on-error: true` from "Run installcheck" step → now **blocking**
3. Removed 3 downstream steps that depended on continue-on-error:
   - "Update expected files from PG 17 output (baseline reset)"
   - "Re-run installcheck after baseline update"
   - "Fail if installcheck failed and no baseline update"

Net: workflow reduced from 71 lines to 44 lines. All 6 remaining steps are hard-blocking. Next push to main will show green checkmarks or a clean red failure — no yellow warnings.

## Problems identified → task_drafts

**[RELEASE-YML-HOST-PG]** `release.yml` still uses pgvector/pgvector:pg17 service container (lines 11–19) and does not install pgvector apt package. On a tag push, `make installcheck` runs against service-container PG while `make install` targets runner host dirs — same root cause as the CI bug fixed here. Recommend identical apt-install refactor. Priority: P3.

## Self-evaluation

**What worked:** The root cause was clear from reading the YAML — `continue-on-error: true` masked installcheck failures as warnings. The baseline-reset scaffold was a bootstrapping-era mechanism, safe to remove now that expected files are committed. The simplification is correct and reduces fragility.

**What to improve:** The `pg_createcluster` approach puts PG on port 5433 (non-standard). If any tool assumes port 5432, connections will silently fail. A follow-up task could standardize on `sudo systemctl start postgresql` (default port 5432) as the original task spec suggested, and update all PGPORT references accordingly. This was not changed in this run to minimize diff scope.

**Confidence:** High. The workflow logic is now straightforward; the evidence threshold (all green checkmarks on next push) is achievable assuming extension SQL tests pass against PG 17.
