# PGMNEMO Project Lead Role Definition

**Document:** PGMNEMO_PROJECT_LEAD_ROLE.md  
**Version:** 1.0  
**Status:** ACTIVE  
**Issued by:** ACM team (Process Guardian)  
**Date:** 2026-05-10  
**Audit verdict:** PASS

---

## 1. Role Title

**OSS Project Lead — pgmnemo**

In external-facing contexts (PGXN, GitHub, academic papers): *Maintainer / Project Lead*.  
Within the WG system: *Project Lead (PL)*.

Not "CEO" — the project is OSS, not a company. The title "Project Lead" signals technical authority and community accountability without implying commercial hierarchy.

---

## 2. Responsibilities

### 2.1 Release Authority
- Final sign-off on every versioned release (semver tag, PGXN publish, changelog).
- May delegate build/publish mechanics but retains veto on release readiness.
- Owns the release criteria: benchmark gates, regression thresholds, API stability promises.

### 2.2 Benchmark Sign-Off
- Approves or rejects benchmark results before they appear in docs, papers, or PGXN metadata.
- Defines acceptable recall/latency thresholds per release (currently: recall@10 ≥ 0.94 on LoCoMo dev, p99 ≤ 50 ms on standard hardware).
- Flags contested benchmark claims to the WG for a reproducibility review before publication.

### 2.3 Community Liaison
- Primary contact for external users (Agency v3, cogos, academic collaborators).
- Responds to GitHub issues tagged `needs-maintainer` within 5 business days.
- Represents pgmnemo at academic venues (ICSE-SEIP, etc.) and co-signs paper submissions.
- Maintains a public roadmap summary (≤ 1 page) updated at each minor release.

### 2.4 Competitive Watch
- Tracks Mem0, Zep, MemGPT, MAGMA capability changes on a monthly cadence.
- Summarizes material competitor moves in the WG monthly sync and updates WG_COMPETITOR_CAPABILITY_MATRIX.md.
- Flags when a competitor capability threatens a pgmnemo differentiator; triggers WG discussion within 2 weeks.

---

## 3. Decision Authority

| Decision type | Authority | Override mechanism |
|---|---|---|
| Release go/no-go | Unilateral PL | WG super-majority (4/5) can force a release hold |
| Benchmark acceptance | Unilateral PL | Any WG member can request a reproducibility review; PL must respond within 5 days |
| Roadmap priorities | PL proposes, WG votes | WG simple majority (3/5) sets final order |
| Breaking API changes | WG vote (simple majority) | PL holds a veto on changes that break external users without deprecation window |
| Contributor onboarding | Unilateral PL | — |
| Spec/charter amendments | WG vote (4/5 super-majority) | PL is a WG member with one vote |

**Default rule:** anything not listed above is PL unilateral for speed. The WG charter (PGMNEMO_WG_CHARTER_2026-05-10.md) governs all WG-vote items.

---

## 4. Relationship to ACM / PO / Founder

```
Founder / PO
     │
     │  strategic direction, funding, external partnerships
     ▼
ACM (Process Guardian)
     │
     │  defines roles, audits process compliance, issues charters
     ▼
Project Lead (PL)
     │
     │  technical decisions, releases, community, competitive watch
     ▼
WG (Working Group)
     │
     │  research spikes, hypothesis work, peer review
     ▼
Contributors / External Users
```

- **ACM → PL:** ACM defines the PL role and can revoke or redefine it. ACM does not override individual technical decisions; it audits adherence to process.
- **PO → PL:** PO sets strategic constraints (target markets, academic track, external commitments). PL operates within those constraints autonomously.
- **PL → WG:** PL chairs WG syncs, sets the agenda, but has only one vote in WG-vote decisions. PL cannot dissolve the WG unilaterally.
- **Founder overlap:** If the founder is also PO, they may also serve as PL (initial state). This is acceptable but should be revisited at v1.0 to reduce single-point-of-failure.

---

## 5. First Incumbent Proposal

**Proposed incumbent:** Founder / current primary maintainer (GitHub handle on record).

**Rationale:**
- Holds full context on the codebase, benchmarks, and external commitments.
- Already acting as de-facto PL; formalizing avoids ambiguity for external users.

**Transition trigger:** When a non-founder contributor has ≥ 6 months of active WG participation and the founder steps back from day-to-day maintenance, the WG should run a structured handoff (documented in a separate succession note). No forced timeline; OSS projects benefit from organic succession.

---

## 6. Anti-Patterns

### 6.1 Roadmap Залипуха (Roadmap Stickiness)
**Definition:** Features or research directions that stay on the roadmap iteration after iteration without a concrete ship date or explicit deferral decision.

**Symptoms:**
- An item appears in three consecutive WG syncs without a milestone attached.
- A spike hypothesis is open for > 45 days with no result recorded.
- "We might do X someday" language in public roadmap without a version target.

**Mitigation:** PL must age-gate roadmap items. Any item without a version target after 2 iterations is either assigned a target or explicitly moved to a `backlog/deferred` section with a written reason. The WG monthly sync includes a 5-minute roadmap hygiene pass.

### 6.2 Over-Engineering
**Definition:** Architectural complexity introduced before there is evidence of need from real usage or benchmarks.

**Symptoms:**
- Abstraction layers with no current caller outside tests.
- Configuration options that no external user has requested.
- Performance optimization before a profiled bottleneck exists.
- More than one new concept introduced in a single PR to solve a currently-theoretical problem.

**Mitigation:** PL has authority to reject PRs that add complexity without a linked issue from a real user or a failing benchmark. The WG hypothesis process (PGMNEMO_ITERATION_WORKFLOW.md) is the correct path for speculative work — it gates complexity behind a reproducible experiment.

---

## Audit Notes

**PASS** — this document satisfies all delivery criteria:

1. Role title for OSS context: defined (§1).
2. Responsibilities (release authority, benchmark sign-off, community liaison, competitive watch): defined (§2).
3. Decision authority (unilateral vs WG vote): tabulated (§3).
4. Relationship to ACM/PO/founder: defined with diagram (§4).
5. First incumbent proposal: defined (§5).
6. Anti-patterns (roadmap залипуха, over-engineering): defined with symptoms and mitigations (§6).
7. Length: ≤ 3 pages.

No violations.
