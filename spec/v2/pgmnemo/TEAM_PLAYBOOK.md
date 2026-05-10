# pgmnemo Team Playbook

**Status:** CANONICAL  
**Effective:** 2026-05-10  
**Owner:** Project Lead (PI, assignee 77)  
**Purpose:** Executable checklist guide — what each role does and when. Not a charter description. If you need the "why", see PGMNEMO_WG_CHARTER_2026-05-10.md and PGMNEMO_ITERATION_WORKFLOW.md.

---

## 1. Weekly Rhythm

Every week the team runs the same three check-ins, regardless of release phase.

### Monday — Iteration Status Sync (async, GitHub issue)

PI (77) posts a status comment on the current iteration proposal issue:

```
Week N / vX.Y cycle
────────────────────
In flight: [task titles]
Blocked: [anything requiring WG input]
Bench status: [last run date, pass/fail]
Risk: [green/amber/red] — [one line reason]
Decision needed this week: [yes/no — what]
```

All WG members acknowledge within 24h or it's treated as no objection.

### Wednesday — Benchmark Pulse

Experiment Designer (84) runs at minimum:
```bash
python scripts/significance_test.py \
  --base benchmarks/locomo/results/v<last_tag>_*/metrics.json \
  --new  benchmarks/locomo/results/current/metrics.json \
  --output spec/reports/BENCH_PULSE_$(date +%Y-%m-%d).md
```

If the pulse shows any regression ≥ 1pp on recall@10: immediate WG ping + hold new merges.

### Friday — Week Close

TL (5) files a 5-line summary comment on the active task:
- what was committed this week (SHA or "nothing")
- what's blocked
- expected state by next Monday

Process Guardian (78) checks for phantom-DONE: any task marked DONE/COMPLETED without a commit SHA in done_note → reopen immediately, file PI notification.

---

## 2. Iteration Start Checklist (PI runs this)

Triggered when: previous release tagged, or PI declares new iteration.

**Step 1 — Refresh hypothesis backlog** (PI, 1–2h)
- [ ] Open `spec/v2/pgmnemo/HYPOTHESIS_BACKLOG_<date>.md`
- [ ] Update evidence column for every open hypothesis based on last iteration's bench results
- [ ] Re-score ICE/RICE for changed items
- [ ] Mark dropped hypotheses as `[DROPPED — reason]`
- [ ] Select Top-1 to Top-3 hypotheses for this iteration (default: 1 per iteration unless they're small)
- [ ] Create new iteration proposal issue on GitHub (template: `spec/v2/pgmnemo/iteration_proposal.md`)

**Step 2 — Scope declaration** (PI + TL, 1h)
- [ ] PI posts iteration proposal; TL reviews for implementation feasibility within 24h
- [ ] TL flags any migration risks (schema changes require rollback branch named `rollback/<version>`)
- [ ] Finalize scope: "this iteration ships X, explicitly defers Y and Z"

**Step 3 — Task spawn** (TL, 2–4h)
- [ ] Create one Agency task per hypothesis using stage labels: `stage:RESEARCH`, `stage:PLAN`, `stage:IMPL`, `stage:BENCH`, `stage:SHIP`
- [ ] Each task gets label `version:vX.Y` and `pgmnemo`
- [ ] Process Guardian reviews task specs for completeness: evidence threshold, rollback criteria, acceptance criteria present
- [ ] Prompt Master (76) approves task description quality (no vague outcomes)

**Step 4 — Rollback branch** (TL)
- [ ] `git checkout -b rollback/v<current>` from the current release tag
- [ ] Push to origin — this branch is frozen until the version after the target ships

---

## 3. Release Gate Checklist (TL + ExpDesigner run this)

Run this before cutting any tag. All gates must be green. A single red gate = HOLD.

### Code gates
- [ ] `make check` passes with zero failures
- [ ] `pg_regress` passes for all SQL fixtures
- [ ] Migration script applied to clean DB (no errors, no warnings)
- [ ] Migration script idempotent (running twice has no error, no duplicate-object warnings)
- [ ] All new functions have `CREATE OR REPLACE` guards
- [ ] CHANGELOG.md entry written (includes upgrade instructions)
- [ ] `META.json` `version` updated, PGXN bundle validates: `pgxnclient check dist/pgmnemo-<version>.zip`

### Benchmark gates
- [ ] LoCoMo full dataset (≥1982 questions) run completed
- [ ] LongMemEval-S (≥500 items) run completed
- [ ] `scripts/significance_test.py` run vs. previous tag's `metrics.json`
- [ ] No primary metric (recall@10 or MRR) regresses by ≥2pp (p < 0.05)
- [ ] Per-category breakdown in bench report (not aggregate-only)
- [ ] Bench report filed in `benchmarks/*/results/v<version>_<date>/`
- [ ] ExpDesigner (84) signs off with explicit GO/NO-GO verdict

### Release notes gate
- [ ] Public claims are honest: only p_corrected < 0.05 results in "Significant Improvements" section
- [ ] Simulation/proxy results labeled `(simulation, <proxy-method>)`
- [ ] Competitor comparisons absent (honest positioning only: what pgmnemo does, not "better than X")
- [ ] ResSup (85) signs off on statistical claims in release notes

### Community gate
- [ ] GitHub release draft created
- [ ] PGXN bundle uploaded to manager.pgxn.org (Project Lead uploads manually — no CLI support)
- [ ] `docs/USAGE.md` updated if new functions/parameters added
- [ ] Growth Lead (92) has approved launch post (if minor or major release)

---

## 4. Benchmark Run Protocol

Before every bench run, confirm setup:

```bash
# Confirm DB is reachable
psql $TEST_PG_URL -c "SELECT pgmnemo.version()"

# Run LoCoMo (full, ~20 min)
python benchmarks/locomo/run_locomo_eval.py \
  --pg-url $TEST_PG_URL \
  --out benchmarks/locomo/results/v<version>_$(date +%Y%m%d)/metrics.json

# Run LongMemEval-S (~10 min)
python benchmarks/longmemeval/run_longmemeval.py \
  --pg-url $TEST_PG_URL \
  --split S \
  --out benchmarks/longmemeval/results/v<version>_$(date +%Y%m%d)/metrics.json

# Significance test
python scripts/significance_test.py \
  --base benchmarks/locomo/results/v<prev>_*/metrics.json \
  --new  benchmarks/locomo/results/v<version>_*/metrics.json
```

**Never report bench results without the significance test output.** If the DB is unreachable, mark all results as `(simulation)` and do not claim real numbers.

---

## 5. Hypothesis Research Protocol

When a hypothesis is selected for an iteration, TL spawns a RESEARCH task with this outcome spec:

```
Outcome: A bench report in spec/reports/<HYPO_ID>_bench_<date>.md showing:
1. Baseline recall@10 / MRR / latency (must match last official metrics.json)
2. Implementation output (SQL function, index, config)
3. Post-change recall@10 / MRR / latency
4. Significance test result (scripts/significance_test.py output)
5. Recommendation: MERGE / DROP / DEFER with evidence
```

A RESEARCH task that produces a recommendation without a bench report is NOT complete.

---

## 6. Competitive Watch Protocol (monthly, Project Lead)

First Monday of each month:

1. Check Mem0, Zep, MemGPT, MAGMA GitHub releases and changelogs
2. Update `spec/v2/pgmnemo/WG_COMPETITOR_CAPABILITY_MATRIX.md`:
   - New capability → add row, score gap severity (High/Medium/Low)
   - Existing capability shipped → update `Released` column
3. If any competitor ships a capability with gap severity = High and pgmnemo has no roadmap item for it → file `roadmap-candidate` GitHub issue within 48h
4. Post one-line competitive update in Monday status sync

---

## 7. Community Response SLA

| Channel | SLA | Owner |
|---------|-----|-------|
| GitHub Issue `bug` or `needs-maintainer` | 5 business days | Project Lead (PI) |
| GitHub Issue `question` or `enhancement` | 10 business days | Growth Lead (92) → escalate to PI if technical |
| PGXN reviews / install problems | 3 business days | TL (5) |
| External integration requests (Agency, cogos) | 2 business days | PI direct |
| Paper co-authorship requests | 10 business days | PI → WG vote if required |

---

## 8. Phantom-DONE Prevention

Every task that claims DONE must have all of the following:
1. `done_note` contains a commit SHA (7+ chars)
2. That commit exists on `main` (not a worktree branch)
3. The commit contains a `.sql` file (for implementation tasks) or a `.py` bench script (for bench tasks) or a `.md` report (for research tasks)

Process Guardian (78) audits the previous iteration's tasks at the start of every new iteration. Any task failing these checks is reopened immediately — the iteration is not closed until all prior tasks pass.

---

## 9. Escalation Paths

| Situation | Who acts | Deadline |
|-----------|----------|----------|
| P0 regression post-ship | TL patches + PI hold decision | 6 hours |
| Migration bug found pre-release | TL fixes + Process Guardian re-validates | 48 hours |
| WG vote deadlock (no majority) | PI breaks tie | 24 hours |
| Bench results contradict each other | ResSup (85) variance investigation | 72 hours |
| External user reports data loss / corruption | TL + PI + ResSup | 4 hours |

---

## 10. When to Invoke the WG vs. Act Unilaterally

**PI acts unilaterally on:**
- Minor scope trims (removing a feature from a release, not adding)
- Benchmark run scheduling
- Community responses
- Release date adjustments ≤1 week

**WG vote required for:**
- Any breaking API change (even if "users can migrate easily")
- Adding a new required GUC or mandatory config
- Changing benchmark methodology or scoring formula
- Promoting EXPERIMENTAL feature to default
- Dropping a shipped feature
- Charter or process amendments

**Default rule:** when uncertain, PI posts a 24h async review and proceeds if no veto.
