---
name: Iteration Proposal
about: PI-authored kickoff document for a new pgmnemo release iteration
title: "[ITER] v0.X.Y iteration proposal"
labels: iteration-proposal, wg-required
assignees: ''
---

## Iteration: pgmnemo vX.Y.Z

**PI:** @principal_investigator  
**Target tag date:** YYYY-MM-DD  
**Proposed on:** YYYY-MM-DD  
**Iteration length:** 2 weeks | 3 weeks (reason if 3)

---

## Phase A — Selected Hypotheses (PI rank)

Drawn from `spec/v2/pgmnemo/HYPOTHESIS_BACKLOG_*.md`. List only what is in scope for this iteration.

| # | Hypothesis ID | Title | ICE | RICE | Rationale for inclusion |
|---|---|---|---|---|---|
| 1 | H-XX | | | | |
| 2 | H-XX | | | | |

**Out of scope this iteration:** (list explicitly)

---

## Phase B — Implementation Tasks

| Task tag | Description | Owner | Effort | Bench impact |
|---|---|---|---|---|
| [TAG] | | TL | Xd | +/- recall@10 on [benchmark] |

---

## Rollback Criteria

This iteration is rolled back (no tag cut) if any of the following occur:
- [ ] Primary metric (recall@10) regresses significantly (p_corr < 0.05) vs vX.Y-1.Z baseline
- [ ] `make check` / `pg_regress` fails on clean install without a fix path within 24h
- [ ] Migration script fails against real vX.Y-1.Z schema
- [ ] (add iteration-specific criteria here)

---

## WG Checkpoints

| Checkpoint | Expected date | Required |
|---|---|---|
| Mid-iteration bench review | YYYY-MM-DD | PI + experiment_designer + research_supervisor |
| WG release review (48h window) | YYYY-MM-DD | All 8 members |
| Retrospective filed | ≤72h after tag | PI + process_guardian |

---

## WG Review (async — comment below)

Each WG member: post `LGTM — [role]` or `CONCERN: [specific issue]` within 24h of proposal.

Required before Phase B begins:
- [ ] experiment_designer — bench impact estimates validated
- [ ] process_guardian — task specs complete (evidence threshold + rollback criteria present)

Optional (confirm attendance at WG checkpoints):
- [ ] research_supervisor
- [ ] technical_lead
- [ ] startup_mentor
- [ ] growth_lead
- [ ] prompt_master
