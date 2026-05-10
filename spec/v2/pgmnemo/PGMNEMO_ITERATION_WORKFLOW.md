# pgmnemo Iteration Workflow

**Effective:** 2026-05-10  
**Author:** ACM methodology team (77, 78, 85) with TL (5), experiment_designer (84)  
**Status:** ACTIVE — governs all pgmnemo minor/major releases from v0.3.0 onward

---

## 1. Definition

An **iteration** = one minor release cycle (e.g., v0.2.x → v0.3.0, or v0.3.0 → v0.3.1). Each iteration:

- Starts from a PI-declared scope with ranked hypotheses
- Follows 6 fixed phases in order
- Ends with a version tag or an explicit Hold decision
- Produces a retrospective document

**Default iteration length:** 2–3 weeks. Extensions require PI approval with documented rationale.

---

## 2. Iteration Phases

### Phase A — Hypothesis Catalog Refresh + ICE/RICE Rank

**Lead:** principal_investigator (77)  
**Duration:** 1–2 days at iteration start

Activities:
1. PI refreshes `spec/v2/pgmnemo/HYPOTHESIS_BACKLOG_*.md` with new evidence from last iteration's benchmarks
2. PI re-scores all hypotheses using ICE and RICE rubric (defined in HYPOTHESIS_BACKLOG)
3. PI proposes Top-N hypotheses for this iteration (N = 1–3 per iteration)
4. experiment_designer (84) reviews bench impact estimates
5. startup_mentor (91) optional review for business framing

**Output:** Updated hypothesis backlog + PI iteration proposal (filed as GitHub issue using `iteration_proposal.md` template)

**Gate:** PI publishes iteration proposal. WG has 24h async review window. No veto = proceed.

---

### Phase B — Implementation Task Spawn

**Lead:** technical_lead (5) + PI (77)  
**Duration:** 1 day

Activities:
1. For each selected hypothesis, TL spawns one or more implementation tasks using the AGENT_PROMPT_TEMPLATE stage structure (RESEARCH → PLAN → IMPL → REVIEW → BENCH → SHIP)
2. process_guardian (78) reviews task specs for completeness (evidence threshold present, rollback criteria explicit)
3. prompt_master (76) approves task spec quality gate

**Output:** N implementation tasks in task system with `version:v0.X.Y` label

**Gate:** process_guardian confirms each task spec passes quality check. Incomplete specs are rejected and rewritten.

---

### Phase C — Implementation + Bench Validation Per Change

**Lead:** technical_lead (5)  
**Duration:** Bulk of iteration (1–2 weeks)

For each implementation task:
1. Agent or TL executes RESEARCH → PLAN → IMPL → REVIEW per AGENT_PROMPT_TEMPLATE
2. `make check` / `pg_regress` must pass before BENCH stage begins
3. experiment_designer (84) runs benchmarks per `docs/RELEASE_PROCESS.md §2`
4. `scripts/significance_test.py` produces comparison vs. previous `metrics.json`
5. Bench report filed with all metrics (no cherry-picking)

**Rollback criteria (any one triggers HOLD at Phase C):**
- Primary metric (recall@10) regresses significantly (p_corr < 0.05)
- `make check` / `pg_regress` fails with no fix path within 24h
- Migration script cannot be applied to real source schema
- Two consecutive bench runs show contradictory results (variance investigation required)

**Output:** Per-change bench reports in `benchmarks/*/results/`

**Gate:** experiment_designer GO/NO-GO verdict on each change's bench report before that change is included in release candidate.

---

### Phase D — WG Report Review

**Lead:** startup_mentor (91) + ACM methodology team  
**Duration:** 48h minimum

Activities:
1. TL assembles release candidate summary: what changed, bench delta for each change, combined effect
2. research_supervisor (85) independently re-derives key statistical claims
3. startup_mentor (91) reviews for business framing, launch readiness, prohibited claims
4. process_guardian (78) audits for phantom-DONE patterns (artifact present on disk for every DONE task)
5. WG members post review comments on GitHub PR or async channel

**Output:** WG review thread with explicit GO/NO-GO from each required reviewer

**Gate:** research_supervisor + startup_mentor + process_guardian must all post explicit review. Silent = abstain (does not block, but is noted in retrospective).

---

### Phase E — Release Decision: Ship / Hold / Drop

**Lead:** principal_investigator (77) — final authority

Decision matrix (from `docs/RELEASE_PROCESS.md §5`):

| Primary metric delta | Secondary metric | Decision |
|---|---|---|
| Significant improvement (p_corr < 0.05) | Any | SHIP |
| Non-significant, no regression | — | SHIP as neutral (no improvement claims) or HOLD |
| Any regression (p_corr < 0.05) | — | HOLD |
| Rollback criterion triggered | — | DROP (revert + cancel iteration) |

PI documents the decision with:
- Specific metrics cited (not "looks good")
- WG sign-off status (who approved, who abstained)
- Any quorum exceptions

**Gate:** PI written decision document required. No tag is cut without it.

---

### Phase F — Tag + Bench Progression Update

**Lead:** technical_lead (5) + growth_lead (92)

Activities:
1. TL cuts git tag `vX.Y.Z` only after PI SHIP decision and all required WG sign-offs
2. TL updates `benchmarks/BENCHMARKS.md` with new benchmark row
3. growth_lead (92) updates GitHub release page with release notes per `docs/RELEASE_PROCESS.md §6`
4. growth_lead posts public announcement (Show HN draft, X/Twitter) if metrics improved significantly

**Output:** Git tag, release notes, updated BENCHMARKS.md

**Gate:** All 4 required WG signatures collected (or documented quorum exception). Tag cannot be cut without this.

---

## 3. Iteration Document Set

Each iteration produces these artifacts (by end of Phase F):

| Artifact | Location | Owner |
|---|---|---|
| Iteration proposal | GitHub issue (iteration_proposal template) | PI |
| Per-task bench reports | `benchmarks/*/results/vX.Y.Z_*/` | experiment_designer |
| Release candidate summary | GitHub PR | TL |
| WG decision document | PR comment or spec doc | PI |
| Public release notes | GitHub release page | growth_lead |
| Bench progression update | `benchmarks/BENCHMARKS.md` | TL |
| Iteration retrospective | `spec/v2/pgmnemo/RETRO_vX.Y.Z_*.md` | PI + process_guardian |

---

## 4. Rollback Criteria

An iteration is **rolled back** (reverted, tag not cut) when any of:

- Phase C HOLD triggered and no fix available within iteration window
- research_supervisor finds reproducibility failure (independent derivation contradicts claimed result)
- Migration script cannot be applied without data loss on real v(N-1) schema
- `pg_regress` / `make check` fails on clean install and cannot be fixed

**Rollback procedure:**
1. TL reverts commits (not force-push; use revert commits on main)
2. PI documents what was attempted and why it was rolled back
3. Hypotheses that failed re-enter backlog with updated confidence score (downward)
4. Iteration retrospective still filed

---

## 5. Iteration Length

| Scenario | Length | Notes |
|---|---|---|
| Standard (1–2 hypotheses) | 2 weeks | Default |
| Complex schema change | 3 weeks | TL + PI agree at Phase B |
| Hotfix / P0 fix | 2–3 days | Bypasses Phase A; starts at Phase B with explicit emergency scope |
| Research-heavy (novel §4/§5 MAGMA) | 3 weeks | research_supervisor in Phase B co-lead |

Extensions beyond 3 weeks require PI written approval with reason.

---

## 6. Coordination with Existing Process Docs

- `docs/RELEASE_PROCESS.md` — statistical reporting requirements (§3), WG gate details (§4), decision matrix (§5): this document supersedes ad-hoc workflow but defers to RELEASE_PROCESS for statistical standards
- `.github/PULL_REQUEST_TEMPLATE.md` — WG sign-off checklist embedded
- `.github/ISSUE_TEMPLATE/iteration_proposal.md` — Phase A output template
- `spec/v2/pgmnemo/PGMNEMO_AGENT_PROMPT_TEMPLATE_2026-05-10.md` — stage structure for each Phase C task
