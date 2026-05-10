# pgmnemo Working Group Charter
**Effective:** 2026-05-10  
**Authority:** Founder directive (2026-05-10)  
**Coordinator:** principal_investigator (77)  
**Co-lead (process):** process_guardian (78)

---

## 1. Purpose

This charter formalizes the pgmnemo Working Group (WG) to govern iterative releases, research methodology, and technical decisions. All v0.3.0 and subsequent work follows this charter.

---

## 2. WG Members and Roles

| Role | Agent ID | Responsibilities |
|------|----------|-----------------|
| **Principal Investigator (PI)** | 77 | Final ship/hold authority; hypothesis catalog ownership; WG coordination; iteration kickoff |
| **Process Guardian** | 78 | Process discipline; phantom-DONE detection; audit execution; quality gate enforcement |
| **Research Supervisor (ResSup)** | 85 | Threat-to-validity assessment; benchmark integrity; methodology sign-off |
| **Technical Lead (TL)** | 5 (Karpov) | Code/release ownership; implementation authority; migration correctness; installcheck sign-off |
| **Startup Mentor** | 91 | External critique; business framing; ship/hold challenge; pre-release review |
| **Experiment Designer** | 84 | Metrics ownership; benchmark design; WG-VOTE on bench protocol changes |
| **Growth Lead** | 92 | GitHub project surface; public-facing content; release note publishing |
| **Prompt Master** | 76 | Task spec quality; agent prompt design; quality gates per stage |

### 2.1 ACM Methodology Team (Coordination Leads)

ACM team members (PI 77, Process Guardian 78, Research Supervisor 85) serve as methodology leads. They are collectively responsible for:
- Enforcing this charter and the iteration workflow
- Catching and escalating phantom-DONE patterns
- Publishing WG retrospectives

---

## 3. Decision Authority Matrix

| Decision Type | Approve (sole authority) | Must Review | Can Veto | Notes |
|---------------|--------------------------|-------------|----------|-------|
| Ship / Hold release | PI (77) | TL (5), ResSup (85), Startup Mentor (91) | Any WG member — veto must cite specific evidence | Founder overrides all |
| Benchmark protocol change | Experiment Designer (84) via WG-VOTE | PI (77), ResSup (85), TL (5) | ResSup (85) | WG-VOTE = ≥4 of 8 approve |
| Implementation task spawn | TL (5) | PI (77) | — | TL has implementation authority |
| Hypothesis addition to backlog | PI (77) | Experiment Designer (84) | — | ICE/RICE scoring required |
| Hypothesis priority rerank | PI (77) | Experiment Designer (84), Startup Mentor (91) | — | Evidence required to rerank |
| Rollback of released version | TL (5) + PI (77) joint | All WG | — | Rollback criteria defined in §6 |
| Agent prompt template change | Prompt Master (76) + PI (77) | Process Guardian (78) | Process Guardian (78) | Must not weaken quality gates |
| WG member role change | Founder | PI (77) | — | Documented in charter revision |
| Process/charter change | PI (77) + Process Guardian (78) | All WG | Any WG member | Requires dated revision in this doc |

### 3.1 WG-VOTE Protocol

A WG-VOTE is required for benchmark protocol changes and any decision where two or more WG members disagree after async discussion.

- **Quorum:** 5 of 8 members must vote
- **Pass threshold:** ≥4 affirmative votes
- **Async:** votes cast within 48 hours via PR comment on the relevant spec doc
- **Result recorded:** in the PR description and in the iteration's WG checkpoint note

---

## 4. Meeting Cadence

All sync points are async-friendly: decisions via PR comments or spec doc annotations are valid equivalents to synchronous meetings.

| Sync Point | Trigger | Required Attendees | Format |
|------------|---------|-------------------|--------|
| **Iteration Kickoff** | Start of every iteration | PI (77), TL (5), Experiment Designer (84) | Kickoff doc (see `PGMNEMO_ITERATION_WORKFLOW.md §1`) |
| **Hypothesis Ranking Review** | Phase (a) of each iteration | PI (77), Experiment Designer (84), Startup Mentor (91) | Async: PR on HYPOTHESIS_BACKLOG |
| **Mid-iteration WG Review** | After first benchmark pass | All WG | Async: comment thread on bench report |
| **Ship/Hold Decision** | End of iteration, after final bench | PI (77), TL (5), ResSup (85), Startup Mentor (91) | Decision doc (see workflow §5e) |
| **Retrospective** | Within 3 days of tag cut | PI (77), Process Guardian (78) | Retrospective doc in `spec/v2/pgmnemo/` |
| **Emergency (P0 regression)** | On detection | TL (5) + PI (77) | Immediate async thread, decision within 6 hours |

---

## 5. Escalation Paths

### 5.1 Normal Disagreement (2 members disagree)

1. Both members post their position with evidence in the relevant PR/spec doc
2. PI (77) reviews within 24 hours and makes a call
3. If PI is the disagreeing party: ResSup (85) arbitrates
4. Decision logged in the PR

### 5.2 Benchmark Dispute (methodology disagreement)

1. Experiment Designer (84) posts a formal objection with specific metric/methodology concern
2. ResSup (85) and PI (77) review within 48 hours
3. If unresolved: WG-VOTE (§3.1)
4. During dispute: no release tag is cut on the disputed metric

### 5.3 Phantom-DONE Pattern Detected

1. Process Guardian (78) flags with evidence (files missing, tests not passing)
2. TL (5) must respond within 12 hours with artifact or acknowledgment
3. Status reverted to IN_PROGRESS by Process Guardian
4. PI (77) notified; iteration timeline adjusted

### 5.4 Founder Override

Founder may override any WG decision by direct directive. Founder directives are documented in the relevant spec doc with date and rationale.

---

## 6. Sign-off Requirements

All WG members listed below must sign off on this charter by commenting `LGTM — [role]` on the PR that introduces this document.

| Role | Agent | Status |
|------|-------|--------|
| PI | 77 | pending |
| Process Guardian | 78 | pending |
| Research Supervisor | 85 | pending |
| Technical Lead | 5 | pending |
| Startup Mentor | 91 | pending |
| Experiment Designer | 84 | pending |
| Growth Lead | 92 | pending |
| Prompt Master | 76 | pending |

---

## 7. Charter Revision History

| Date | Change | Authority |
|------|--------|-----------|
| 2026-05-10 | Initial charter (ACM-PGMNEMO-WORKFLOW-1) | Founder directive |
