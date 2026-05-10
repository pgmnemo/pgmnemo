# pgmnemo Agent Prompt Template
**Effective:** 2026-05-10  
**Authors:** prompt_master (76) + ACM methodology team (PI 77, Process Guardian 78)  
**Applies to:** All pgmnemo implementation tasks (RESEARCH → IMPL → SHIP pipeline)

---

## 1. Purpose

This template defines the standard structure and quality gates for every agent-executed pgmnemo task. Agents must follow this structure. WG sign-off requirements per stage are defined in §3.

---

## 2. Standard Task Structure

Every task spec MUST follow this six-stage pipeline:

```
RESEARCH → PLAN → IMPL → REVIEW → BENCH → SHIP
```

Stages may be collapsed for trivial tasks (≤0.5 day effort) but the collapse must be declared explicitly in the task spec.

---

## 3. Stage Definitions and Quality Gates

### Stage R — RESEARCH

**Objective:** Establish the evidence base before any implementation starts.

**Required outputs:**
- Literature / prior art scan (competitor approaches, relevant papers, existing pgmnemo code)
- Baseline metrics (current recall@K, MRR) from pinned benchmark run
- Hypothesis statement: `If [mechanism], then [metric] improves by [delta] on [benchmark] because [theory]`
- Risk list: at least 1 downside / threat to validity

**Quality gate:**
- [ ] Hypothesis is falsifiable (states a metric, a dataset, a direction)
- [ ] Baseline numbers are from a real benchmark run (not estimated)
- [ ] Risk list is non-empty
- [ ] No implementation code written at this stage

**WG sign-off required:** PI (77) approves hypothesis before PLAN begins.

---

### Stage P — PLAN

**Objective:** Produce a concrete implementation plan with rollback criteria.

**Required outputs:**
- Design decision: what will change (SQL, C extension, Python, config)
- Files to be created or modified (exhaustive list)
- Schema migration plan (if any SQL schema change)
- Rollback criterion: the condition under which this change is reverted
- Effort estimate: engineering-days
- Bench re-run plan: which benchmarks, how many queries, dataset SHA

**Quality gate:**
- [ ] Design decision is specific enough that a different engineer could implement it
- [ ] Schema migration covers upgrade AND rollback path
- [ ] Rollback criterion is a testable statement (metric below X, or test failure)
- [ ] Effort estimate is provided

**WG sign-off required:** TL (5) approves plan before IMPL begins (implementation authority).

---

### Stage I — IMPL

**Objective:** Implement the plan. No scope creep.

**Required outputs:**
- All files listed in PLAN, created or modified
- `make check` passing locally (or documented exception with reason)
- No new compiler warnings
- Migration script applied against real schema (not phantom — verified by `installcheck`)

**Quality gate:**
- [ ] All planned files are committed (no phantom-DONE: verify with `git status`)
- [ ] `make check` result recorded (pass / fail + output snippet)
- [ ] No files created outside the PLAN scope without TL approval
- [ ] If schema change: migration applied and `SELECT COUNT(*) FROM [table] WHERE [new_column] IS NULL = 0` verified

**WG sign-off required:** TL (5) reviews diff before REVIEW stage begins.

**Phantom-DONE prevention:** The DELIVERY REPORT must list every file path. Process Guardian (78) spot-checks that each path exists in the repo with non-trivial content.

---

### Stage V — REVIEW

**Objective:** Independent review for correctness, methodology, and scope compliance.

**Reviewers (by change type):**

| Change type | Required reviewers |
|-------------|-------------------|
| SQL schema / migration | TL (5) + Process Guardian (78) |
| Benchmark harness | Experiment Designer (84) + ResSup (85) |
| Public docs / release notes | Growth Lead (92) + Startup Mentor (91) |
| Agent prompt / task spec | Prompt Master (76) + PI (77) |
| Statistical analysis | ResSup (85) (mandatory) |

**Quality gate:**
- [ ] At least 2 reviewers from the table above have approved
- [ ] No open "must-fix" comments
- [ ] Statistical claims include 95% CI and significance test (see `docs/RELEASE_PROCESS.md §3`)
- [ ] No prohibited claims (see `docs/RELEASE_PROCESS.md §5.2`)

---

### Stage B — BENCH

**Objective:** Run the mandatory benchmarks on the implemented change and produce a comparison report.

**Required outputs:**
- `benchmarks/*/results/[version]_[date]/report.md` — full benchmark report
- `metrics.json` with pinned dataset SHA256
- `scripts/significance_test.py` output: current vs. previous `metrics.json`
- Per-category breakdown (not just aggregate recall@10)
- 95% Wilson CI on all proportion metrics

**Quality gate:**
- [ ] Both mandatory benchmarks run: LoCoMo + LongMemEval-S (see `docs/RELEASE_PROCESS.md §2.1`)
- [ ] Dataset SHA256 matches the pinned version
- [ ] Significance test run and output appended to report
- [ ] No cherry-picked metrics: all recall@K, MRR, per-category reported
- [ ] Experiment Designer (84) approves benchmark report

**WG sign-off required:** Experiment Designer (84) GO/NO-GO on benchmark validity before SHIP.

**GO/NO-GO format:**
```
BENCH GO/NO-GO — [experiment_designer_84]
Decision: GO | NO-GO
Evidence: [specific metric, CI, p-value cited]
Concern (if NO-GO): [specific issue]
```

---

### Stage S — SHIP

**Objective:** Tag, publish, and communicate the release.

**Required outputs:**
- Git tag following semver (`v0.X.Y`)
- CHANGELOG.md entry following `docs/RELEASE_PROCESS.md §6` structure
- Public release notes with only `p_corrected < 0.05` claims in "Significant Improvements"
- Benchmark progression table updated in `benchmarks/HISTORY.md`
- GitHub release created (Growth Lead 92)

**Quality gate:**
- [ ] All 4 WG signatures collected (see `docs/RELEASE_PROCESS.md §4.2`)
- [ ] Decision matrix applied and documented (see `docs/RELEASE_PROCESS.md §5`)
- [ ] No prohibited claims in any public-facing text
- [ ] CHANGELOG entry follows §6 structure exactly
- [ ] `benchmarks/HISTORY.md` progression table updated

**WG sign-off required:** PI (77) final ship/hold authority. All 4 core WG signatures required (PI, TL, ResSup, StatAnalyst) per `docs/RELEASE_PROCESS.md §4.2`.

---

## 4. Task Spec Format

Every task spec must begin with this header block:

```markdown
## Task: [SHORT-ID] [Title]
**Stage:** RESEARCH | PLAN | IMPL | REVIEW | BENCH | SHIP
**Hypothesis:** [H-XX from HYPOTHESIS_BACKLOG, or N/A for infra tasks]
**Effort:** [days]
**WG owner:** [agent_id]
**Iteration:** v0.X.Y
**Rollback criterion:** [testable statement]

## RESEARCH output
[...]

## PLAN output
[...]

## IMPL output (files created/modified)
[...]

## BENCH output
[...]

## DELIVERY REPORT
status: complete | blocked
files_created: path1, path2 | none
files_modified: path1, path2 | none
summary: one line, facts only
```

---

## 5. Quality Gate Failure Handling

| Gate failure | Action | Authority |
|-------------|--------|-----------|
| Phantom-DONE detected (file missing or empty) | Status reverted to IMPL; Process Guardian notified | Process Guardian (78) |
| `make check` failing | IMPL blocked; TL must fix | TL (5) |
| Significance test not run | BENCH blocked; Experiment Designer flags | Experiment Designer (84) |
| Prohibited claim in release notes | SHIP blocked; Growth Lead revises | PI (77) + Growth Lead (92) |
| WG signature missing | SHIP blocked | PI (77) |

---

## 6. Collapsed-Stage Exception

For tasks with effort ≤ 0.5 days (config changes, doc fixes, trivial patches):

- RESEARCH and PLAN may be combined into a single section
- REVIEW is still required (at least 1 reviewer)
- BENCH is required if any retrieval-path code changes; waived for pure doc/config changes
- DELIVERY REPORT is always required

Declare the collapse explicitly: `**Collapsed stages:** RESEARCH+PLAN (≤0.5 day effort)`
