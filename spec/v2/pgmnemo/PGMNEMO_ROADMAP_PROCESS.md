# pgmnemo Roadmap Process
**Status:** CANONICAL  
**Effective:** 2026-05-10  
**Authority:** ACM (Process Guardian 78) + Product Owner  
**Applies to:** v0.3.0 and all subsequent releases  
**Audit verdict:** PASS

> This document defines HOW the pgmnemo roadmap is created and maintained. The roadmap itself is a separate artifact. Anyone should be able to run the first roadmap session from this document alone.

---

## 1. Purpose and Scope

This process governs:
- What inputs flow into roadmap construction
- How items are prioritized
- What gates a release must pass before shipping
- How the WG reviews and approves a release
- What happens when a shipped feature turns out to be wrong
- How far ahead we plan and who owns each item

It does **not** prescribe what goes on the roadmap — only how roadmap decisions are made, recorded, and enforced.

---

## 2. Inputs to the Roadmap

Every roadmap session must process all four input channels before ranking items. An item that cannot be traced to at least one channel is invalid.

### 2.1 User Demand

**Signal sources:**
- GitHub Issues labeled `user-request` or `integration-request`
- Direct feedback from integration partners (Agency v3, cogos — tracked in GitHub milestones or a linked tracking issue)
- Support/question patterns in Discussions

**How to capture:** Open a GitHub Issue with label `roadmap-candidate` within 48 hours of receiving signal. Include: requester, use case, blocking severity (P0/P1/P2).

**Minimum for session:** Pull all open `roadmap-candidate` issues, note which are from Agency v3 or cogos (flag as `external-dependency`).

### 2.2 Competitive Analysis

**Reference:** `spec/v2/pgmnemo/WG_COMPETITOR_CAPABILITY_MATRIX.md` (keep updated; re-run before each roadmap session if >4 weeks old)

**Scope:** Mem0, Zep, MemGPT/MemGPT-like, MAGMA

**How to use:** Items where pgmnemo `❌ lacks` a technique with `High` gap severity are roadmap candidates. Do not auto-promote — apply ICE/RICE scoring (§3).

### 2.3 Academic Track

**Targets:** ICSE-SEIP, ACL, ICLR, NeurIPS (applied track)

**Signal sources:**
- Open research hypotheses in `spec/v2/pgmnemo/HYPOTHESIS_BACKLOG_*.md`
- Benchmark gaps documented in `benchmarks/HISTORY.md` and benchmark result reports
- External papers tracked in `research/`

**Requirement:** Any feature motivated solely by a paper claim must have a reproducibility plan (which benchmark, which baseline, pass threshold) attached to its roadmap item before it can be scheduled.

### 2.4 Technical Debt and Infrastructure

**Signal sources:**
- `TODO`/`FIXME` comments in source that are more than one release old
- CI `continue-on-error` steps labeled temporary (tracked in cadence report)
- Regressions or flaky tests discovered during benchmark runs
- Migration correctness issues flagged by TL (5)

**Requirement:** Debt items must cite the file and line they address. Items with no ownable fix scope are not valid roadmap candidates.

---

## 3. Prioritization Method — ICE/RICE

Every roadmap candidate must be scored before the ranking meeting. The default method is **ICE** (Impact, Confidence, Ease). For items with multi-team dependencies, use **RICE** (Reach, Impact, Confidence, Effort).

### 3.1 ICE Scoring

| Dimension | Scale | Guidance |
|---|---|---|
| **Impact** | 1–10 | Effect on benchmark metrics, user unblocking, or competitive gap closure. 10 = moves a primary benchmark metric by ≥5pp or unblocks a named external partner. |
| **Confidence** | 1–10 | Evidence quality. 10 = reproduced result in prior benchmark run. 5 = plausible hypothesis with supporting paper. 1 = intuition only. |
| **Ease** | 1–10 | Inverse of effort. 10 = ≤1 day of TL time. 1 = multi-week with unknowns. |

**ICE = (Impact × Confidence × Ease) / 100**

Items scoring **< 1.0** require explicit justification to remain on the roadmap.

### 3.2 RICE Scoring (multi-team/external items)

| Dimension | Definition |
|---|---|
| **Reach** | Estimated users/integrations affected per quarter |
| **Impact** | Massive=3, High=2, Medium=1, Low=0.5, Minimal=0.25 |
| **Confidence** | % as decimal (e.g. 0.80) |
| **Effort** | Person-weeks |

**RICE = (Reach × Impact × Confidence) / Effort**

### 3.3 Who Scores

- First pass: item author or PI (77)
- Review and challenge: Startup Mentor (91) + Experiment Designer (84)
- Final score recorded in the roadmap artifact before the ranking meeting

---

## 4. Roadmap Session — Running the First One

This section is written so that a facilitator with no prior context can run a session.

### 4.1 Prerequisites (complete before the session)

| # | Action | Owner | Done when |
|---|---|---|---|
| 1 | Pull all open `roadmap-candidate` GitHub Issues | PI (77) | Issue list exported to session doc |
| 2 | Confirm competitor matrix is ≤4 weeks old | Process Guardian (78) | Date checked in `WG_COMPETITOR_CAPABILITY_MATRIX.md` |
| 3 | Run cadence check and note outstanding FAILs | Process Guardian (78) | Cadence report attached |
| 4 | Score all candidates with ICE/RICE (§3) | PI (77) + Startup Mentor (91) | Scores in session doc |
| 5 | Identify items from external partners (Agency v3, cogos) | PI (77) | Flagged `external-dependency` |
| 6 | List open hypotheses from HYPOTHESIS_BACKLOG | PI (77) | Subset ≥ ICE 1.0 included |

### 4.2 Session Agenda (90 min or async equivalent)

| Block | Duration | Facilitator | Output |
|---|---|---|---|
| **Inputs review** | 20 min | PI (77) | Confirm all four input channels covered; flag missing data |
| **Scoring review** | 20 min | Startup Mentor (91) | Challenge any score that differs from consensus by >3 points; update scores |
| **Horizon 1 selection** | 20 min | PI (77) | Agree on items for the NEXT release (max 1 release ahead — see §7) |
| **Horizon 2 selection** | 15 min | PI (77) | Agree on items for the release after next (max 1 release ahead) |
| **Owner + AC assignment** | 10 min | Process Guardian (78) | Every selected item has an owner and written acceptance criteria before session ends |
| **Anti-залипуха check** | 5 min | Process Guardian (78) | Remove or defer any item violating §7 |

### 4.3 Quorum for Session

- **Async:** PI (77) + Process Guardian (78) + Startup Mentor (91) must all participate (comment on session doc within 48 hours)
- **Sync:** Same three roles, plus TL (5) if any implementation-scope item is on the agenda

A session with fewer participants produces a **draft** roadmap only; it cannot be published or acted on until quorum is reached.

### 4.4 Session Artifact

The session produces a Markdown file at `spec/v2/pgmnemo/ROADMAP_<YYYYMMDD>.md` with:

```
## Horizon 1 — <release version>
| Item | Owner | ICE/RICE | Acceptance Criteria | Input channel |
|------|-------|----------|--------------------:|---------------|
| ...  |  ...  |    ...   |                 ... |           ... |

## Horizon 2 — <release version>
| Item | Owner | ICE/RICE | Acceptance Criteria | Input channel |
|------|-------|----------|--------------------:|---------------|

## Deferred
| Item | Reason | Revisit trigger |
|------|--------|-----------------|

## Session log
- Date:
- Participants:
- Decisions:
```

---

## 5. Release Gate Checklist

No version tag is cut until every item below is checked. This checklist extends `docs/RELEASE_PROCESS.md §1`.

### 5.1 Benchmark Gates (mandatory)

- [ ] LoCoMo full run (1982+ questions) against pinned dataset SHA — report in `benchmarks/locomo/results/`
- [ ] LongMemEval-S full run (≥500 items) against pinned dataset SHA — report in `benchmarks/longmemeval/results/`
- [ ] `scripts/significance_test.py` executed; p-values and 95% Wilson CIs present in the report
- [ ] Every claimed improvement is statistically significant (p < 0.05 vs. prior release baseline)
- [ ] No metric regresses vs. prior release without explicit WG acknowledgment in the Ship/Hold doc
- [ ] Benchmark protocol version cited: `pgmnemo Recall Benchmark Protocol v1.0.0 (benchmarks/PROTOCOL.md)`

### 5.2 Code and Test Gates

- [ ] All CI steps pass (no `continue-on-error` steps without labeled explanation)
- [ ] `installcheck` passes clean
- [ ] Migration correctness sign-off from TL (5)
- [ ] No open P0 issues in the release milestone

### 5.3 Documentation Gates

- [ ] CHANGELOG top entry matches release version
- [ ] README badge updated
- [ ] `docs/BENCHMARKS.md` updated with new results
- [ ] Migration guide present if schema changed

### 5.4 Process Gates

- [ ] Pre-release WG review completed (§6) with go/no-go decision recorded
- [ ] Every shipped item has a corresponding closed roadmap item with owner and AC verified
- [ ] Rollback branch exists and is named per §8.2

---

## 6. Pre-Release WG Review

This review happens **after** benchmark gates are met but **before** the tag is cut.

### 6.1 Purpose

The WG explicitly discusses what is IN the release and whether each item belongs. The goal is to catch: scope creep, premature features, benchmark-passing-but-not-production-ready items, and items that belong to a different release.

### 6.2 Agenda (per §4.2 format — async or sync)

| Block | Question | Required input |
|---|---|---|
| **Feature audit** | For each item in the release: does it match its acceptance criteria exactly? | Owner demos / cites evidence |
| **Scope challenge** | Does any item feel like it belongs in the NEXT release? | Startup Mentor (91) leads challenge |
| **Risk assessment** | Does any item introduce a risk not covered by the benchmark suite? | ResSup (85) assesses |
| **Defer/rollback options** | Is any item a candidate for deferral before tag? | Any WG member can nominate; PI (77) decides |
| **Go/no-go** | Explicit recorded vote | PI (77) calls; recorded in decision doc |

### 6.3 Quorum

- **Required:** PI (77), TL (5), ResSup (85), Startup Mentor (91)
- **Veto right:** Any WG member may veto a specific item (not the full release) by citing specific evidence. Veto blocks that item only; PI (77) decides defer vs. fix.
- **Go/no-go is recorded** in `spec/v2/pgmnemo/RELEASE_DECISION_<version>.md`

### 6.4 Deferral Option

Any WG member may propose to defer a completed item to the next release if:
- The item was completed but review reveals unexpected complexity
- Benchmark evidence for the item is weaker than expected (p ≥ 0.05, or CI overlaps baseline)
- Startup Mentor (91) raises a user-facing concern not present at planning time

Deferral is not a failure — it is preferred over shipping a half-proven feature.

---

## 7. Anti-Залипуха Rules

"Залипуха" = shipping something to feel done when the evidence does not support it, or planning so far ahead that items stagnate.

**Rule 1 — Horizon limit:** The roadmap may contain at most 2 releases of horizon (Horizon 1 = next release, Horizon 2 = the one after). Nothing beyond Horizon 2 is scheduled. Items may exist in a Deferred backlog but have no target version.

**Rule 2 — Owner required:** Every roadmap item in Horizon 1 or 2 must have a named owner (WG member role). Ownerless items are immediately moved to Deferred at the start of each roadmap session.

**Rule 3 — Acceptance criteria required:** Every roadmap item in Horizon 1 or 2 must have written, testable acceptance criteria. Vague criteria ("improve recall") are invalid. Valid criteria: "LoCoMo recall@10 increases by ≥2pp vs. v0.2.1 baseline, p < 0.05."

**Rule 4 — Stale item expiry:** Any item that has been in Horizon 2 for two consecutive roadmap cycles without progress is automatically moved to Deferred, with a note. Re-promotion requires ICE/RICE re-scoring.

**Rule 5 — No phantom DONE:** An item is not DONE until its acceptance criteria are verified by evidence (benchmark result, passing test, or signed-off demo). "Implemented" ≠ DONE. Process Guardian (78) enforces this at the pre-release review.

---

## 8. Rollback Protocol

### 8.1 Criteria for Rollback

A shipped feature (in a released, tagged version) is a rollback candidate when ANY of the following is true:

| Criterion | Who can trigger |
|---|---|
| Benchmark regression vs. prior release detected post-ship (any primary metric drops ≥2pp) | TL (5), ResSup (85), Experiment Designer (84) |
| Production defect reported by an external partner (Agency v3, cogos) that is traced to the feature | TL (5) or PI (77) |
| Statistical error discovered in the significance analysis used to justify the feature | ResSup (85) |
| WG determines in retrospective that the feature's complexity was not justified by its benefit | PI (77) via WG-VOTE |

Rollback is **not** triggered by: user preference changes, competitive considerations alone, or minor performance variation within CI.

### 8.2 Branch Policy

- Before every release, TL (5) creates a `rollback/<version>` branch pointing to the prior release tag
- The rollback branch is never deleted until the version after the next release ships successfully
- Rollback branch is documented in the release decision doc

### 8.3 Rollback Process

1. **Trigger:** Any eligible party files a GitHub Issue with label `rollback-candidate`, citing the criterion met
2. **Triage (within 6 hours):** TL (5) + PI (77) confirm the criterion is met and assign severity (P0 = ship immediately, P1 = plan patch release)
3. **WG notification:** Process Guardian (78) posts to the WG async channel; all members notified
4. **Decision (within 24 hours for P0, 72 hours for P1):** PI (77) + TL (5) joint decision; recorded in `spec/v2/pgmnemo/ROLLBACK_DECISION_<version>_<date>.md`
5. **Execution:** TL (5) merges `rollback/<version>` to main, cuts a patch tag (e.g., v0.2.2 → v0.2.3 reverts feature from v0.2.2), updates CHANGELOG with rollback rationale
6. **Post-rollback:** The rolled-back item is returned to Deferred with a note; it may not be re-promoted for one full release cycle without new benchmark evidence

### 8.4 What Is NOT a Rollback

- Removing a feature via normal deprecation in a planned release: use the standard release process
- Disabling a feature flag: no branch protocol required; document in CHANGELOG

---

## 9. Cadence

| Activity | Frequency | Trigger | Owner |
|---|---|---|---|
| Roadmap session | Before each release cycle begins | Iteration kickoff (per `PGMNEMO_ITERATION_WORKFLOW.md §1`) | PI (77) |
| Competitor matrix refresh | Every 4 weeks or before roadmap session | Calendar / session prerequisite | Process Guardian (78) |
| Cadence check (Mon/Wed/Fri) | 3× per week | Automated or manual | Process Guardian (78) |
| Pre-release WG review | Once per release, post-benchmarks | Benchmark gates met | PI (77) |
| Roadmap retrospective | Within 3 days of tag cut | Tag cut | PI (77) + Process Guardian (78) |
| Rollback branch creation | Before every tag cut | Part of release gate checklist | TL (5) |
| Stale item audit | Each roadmap session | Session start | Process Guardian (78) |

---

## 10. Governance and Updates

- This document is updated only by joint authority of PI (77) + Process Guardian (78)
- Any change must be reflected in a dated commit on `main` with message format: `process(roadmap): <description>`
- Changes that weaken quality gates (remove benchmark requirements, relax statistical thresholds, remove quorum requirements) require WG-VOTE (≥4 of 8 members, per `PGMNEMO_WG_CHARTER_2026-05-10.md §3.1`)
- This document supersedes any informal process previously used for roadmap decisions

---

## Appendix A — Quick Reference Card (print and use at session)

```
ROADMAP SESSION QUICK REFERENCE

Before session:
  □ Issues exported (roadmap-candidate label)
  □ Competitor matrix ≤4 weeks old
  □ Cadence report attached
  □ ICE/RICE scores in session doc
  □ External partner items flagged

During session (90 min / async):
  □ Four input channels reviewed
  □ Scores challenged, updated
  □ Horizon 1 locked (≤ 1 release out)
  □ Horizon 2 locked (≤ 2 releases out)
  □ EVERY item: owner + written AC
  □ Anti-залипуха check: remove ownerless / stale

Session artifact:
  spec/v2/pgmnemo/ROADMAP_YYYYMMDD.md

Pre-release checklist:
  □ Benchmark gates (LoCoMo + LongMemEval-S)
  □ significance_test.py run, p < 0.05
  □ WG review quorum met
  □ Go/no-go recorded
  □ Rollback branch created

Rollback trigger (any one):
  - Metric drops ≥2pp post-ship
  - Production defect from external partner
  - Statistical error in prior analysis
  - WG retrospective + WG-VOTE
```

---

*End of document — `spec/v2/pgmnemo/PGMNEMO_ROADMAP_PROCESS.md`*
