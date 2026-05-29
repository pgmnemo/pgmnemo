---
date: 2026-05-29
agent: research_supervisor (id=85)
task_id: PGMREL-070-RESEARCH
status: complete
release_key: pgmnemo-release-0.7.0
---

# Risk Register — pgmnemo 0.7.0

Scope: Tier-1 footguns + `confidence` column + `reinforce()` SP + ingestion guards.
Hypergraph: deferred (not a risk to this release — graph eval pre-conditions not met,
deferral decision documented in ROADMAP_REVIEW_PGMREL-070.md §1).

---

## Risk Taxonomy

**Severity:** P0 = blocks release | P1 = degrades release quality | P2 = post-release debt
**Likelihood:** H = high (>60%) | M = medium (20–60%) | L = low (<20%)
**Owner:** who resolves before gate sign-off

---

## P0 — Release Blockers

### R-01 — Bench regression: `confidence=0.5` does not reproduce v0.6.3 recall@10 ±0.001

| Field | Value |
|-------|-------|
| **Severity** | P0 |
| **Likelihood** | L |
| **Source** | ROADMAP_REVIEW_PGMREL-070.md §3 T2 |
| **Description** | Adding `0.05 × confidence` to the scoring formula must be algebraically neutral at default `confidence=0.5` flat. Analytically guaranteed (constant shift = rank-invariant), but any implementation error (e.g. NULL confidence coalesced to 0 instead of 0.5 for legacy rows) could produce a non-neutral constant and cause ordering perturbations. |
| **Trigger** | Bench run post-confidence-column migration returns recall@10 outside [0.9594, 0.9614] on LongMemEval-S (N=500). |
| **Mitigation** | (1) Migration sets `DEFAULT 0.5 NOT NULL` — no NULL path for legacy rows. (2) Acceptance gate script added to CI: seeds flat-confidence corpus, asserts recall@10 within ±0.001. (3) Fallback: promote confidence to post-filter sort modifier within same release (no API change, no bench risk). |
| **Residual risk after mitigation** | Very low — mitigation (3) guarantees release can ship even if formula approach fails. |
| **Owner** | chief_architect (implementation) + research_supervisor (bench snapshot) |

---

### R-02 — Footgun list incomplete at implementation lock

| Field | Value |
|-------|-------|
| **Severity** | P0 |
| **Likelihood** | M |
| **Source** | ROADMAP_REVIEW_PGMREL-070.md §3 T4; RESEARCH_BRIEF_PGMREL-070.md §2.1 |
| **Description** | "Tier-1 footgun closure" is a narrative claim. Five candidates identified (F-1 through F-5 in RESEARCH_BRIEF §2.1). F-1 shipped in v0.6.3. F-2–F-5 are derived from RFC and changelog audit; the list may be incomplete. Shipping with an undiscovered P0-class footgun violates the acceptance criteria and the "no more footgun-class bugs in default `recall_lessons()` path" positioning claim. |
| **Trigger** | Post-launch GitHub issue filed against `recall_lessons()` default behavior on a documented code path within 30 days of tag. |
| **Mitigation** | PLAN task (PGMREL-070-PLAN) must produce canonical numbered footgun list with: description, reproduction case, fix, regression test. List is a hard input gating implementation start. Research_supervisor reviews list for completeness against Agency RFC Q1–Q7. |
| **Residual risk after mitigation** | Low — canonical list produced by chief_architect + reviewed by research_supervisor covers the known surface. Unknown unknowns remain; this is inherent to hardening work. |
| **Owner** | chief_architect (enumeration in PLAN task) |

---

### R-03 — `reinforce()` blocks on missing `reinforced_at` column in migration

| Field | Value |
|-------|-------|
| **Severity** | P0 |
| **Likelihood** | L |
| **Source** | RESEARCH_BRIEF_PGMREL-070.md §2.3 |
| **Description** | The `reinforce()` SP stamps `reinforced_at = NOW()` on update. If migration omits `ADD COLUMN reinforced_at TIMESTAMPTZ` (or adds it in wrong order), the SP fails at runtime with "column reinforced_at of relation agent_lesson does not exist." This blocks all reinforce() callers. |
| **Trigger** | First `SELECT pgmnemo.reinforce(...)` call after upgrade raises `ERROR 42703`. |
| **Mitigation** | Migration script `pgmnemo--0.6.3--0.7.0.sql` must include both `ADD COLUMN confidence` and `ADD COLUMN reinforced_at` in dependency order before `CREATE FUNCTION reinforce`. pg_regress test for `reinforce()` on fresh-install and incremental-upgrade path. |
| **Residual risk** | Very low — caught in pg_regress before any release tag. |
| **Owner** | chief_architect |

---

## P1 — Quality Degraders

### R-04 — `reinforce()` caller burden blocks Agency adoption

| Field | Value |
|-------|-------|
| **Severity** | P1 |
| **Likelihood** | M |
| **Source** | ROADMAP_REVIEW_PGMREL-070.md §3 T1; MENTOR_REVIEW_2026-05-19.md risk-3 |
| **Description** | `reinforce(lesson_id, delta)` requires the caller to hold `lesson_id` at the time the outcome is known. In fire-and-forget agent loops, the lesson_id may not be in scope when the downstream outcome completes (e.g., CI green/red is determined 60s after the lesson was recalled). Agents using stateless context windows cannot satisfy this without architectural change. |
| **Trigger** | Agency RESTORE-C1/C2 cannot wire `reinforce()` into the agent loop within the v0.7.0 cycle; feature ships but primary adopter cannot use it. |
| **Mitigation** | (1) Document "store lesson_id in agent state" cookbook pattern in USAGE.md. (2) Agency's RESTORE-C1/C2 scaffolding already tracks lesson_id per run — confirm with Agency TL before release. (3) `reinforce_by_query()` deferred to v0.7.1 with explicit backlog entry. |
| **Residual risk** | Medium for *other* adopters (not Agency). Agency adoption confirmed via T1 check. Unknown future adopters may hit the same burden. |
| **Owner** | TL (Karpov) — confirm Agency RESTORE-C1/C2 integration; research_supervisor tracks |

---

### R-05 — "Outcome learning" narrative conflated with ML/neural learning

| Field | Value |
|-------|-------|
| **Severity** | P1 |
| **Likelihood** | M |
| **Source** | POSITIONING_REFRESH_PGMREL-070.md §3.3 risk 3 |
| **Description** | The release headline uses "outcome-learning" (tagline). Developer-readers familiar with RLHF / PPO / neural feedback loops may interpret `reinforce()` as an automatic ML system rather than an explicit caller signal. Misaligned expectations lead to: (a) GitHub issues "why isn't confidence updating automatically?", (b) unfavorable comparisons to Mem0/Zep which use LLM-based extraction. |
| **Trigger** | ≥2 GitHub issues within 30 days of launch asking about automatic confidence updates or background training. |
| **Mitigation** | (1) Anti-promise #4 ("reinforce() is explicit, not auto") appears verbatim in README §Limitations before tag — owner: growth_lead. (2) USAGE.md "How confidence works" section uses "explicit reinforcement signal" as primary description; "learning" only in narrative context. (3) No tagline use of "learning" in SQL API docs (only in marketing narrative). |
| **Residual risk** | Low — anti-promise language is clear; risk is residual perception gap that no docs can fully close. |
| **Owner** | growth_lead (README anti-promise) |

---

### R-06 — Ingestion guards break callers with sloppy ingest patterns (NOTICE → noise)

| Field | Value |
|-------|-------|
| **Severity** | P1 |
| **Likelihood** | M |
| **Source** | ROADMAP_REVIEW_PGMREL-070.md §3 T3; AGENCY_FOLLOWUP_RFC_2026-05-20.md Q5 |
| **Description** | NOTICE-level guards produce PostgreSQL NOTICE messages that some callers route to STDERR, logs, or monitoring systems. Adopters with psycopg2 `connection.set_isolation_level()` or `autocommit=True` and structured logging may surface these as unexpected log entries. High-volume ingest pipelines (retries at scale) could produce NOTICE spam. |
| **Trigger** | Agency or other adopter files issue: "pgmnemo is flooding our logs with NOTICE messages after upgrade." |
| **Mitigation** | (1) NOTICE messages include structured prefix `pgmnemo:` for easy filter. (2) Documentation: USAGE.md explains NOTICE policy and log filter command. (3) Dedup fence is 60s window only — not triggered by replays >60s apart; controls NOTICE volume. (4) v0.7.1 promotion to ERROR is opt-in via GUC (`pgmnemo.guard_strict = on`) — document this ahead of v0.7.1. |
| **Residual risk** | Low — NOTICE is advisory; callers can suppress `pgmnemo:` prefix. |
| **Owner** | chief_architect (implementation) |

---

### R-07 — Competitive moat compression: Constructive AgenticDB adds provenance enforcement

| Field | Value |
|-------|-------|
| **Severity** | P1 |
| **Likelihood** | L (within v0.7.0 release window; M over 12 months) |
| **Source** | MENTOR_REVIEW_2026-05-19.md §Top-3 risks, risk-2 |
| **Description** | Constructive AgenticDB has Series A capital, MIT license, and fast-ship cadence (launched full product ≤3 weeks from repo creation). If they add RLS-policy write-time enforcement before pgmnemo achieves public ecosystem lock-in (500+ stars, 2+ named customers), the provenance-gate moat compresses. v0.7.0 `reinforce()` + confidence deepens the moat further, but does not eliminate the risk. |
| **Trigger** | Constructive AgenticDB announces "provenance enforcement" or "write-time validation" feature before v0.7.0 tag. |
| **Mitigation** | (1) v0.7.0 ships `reinforce()` — feedback loop is unique to pgmnemo among Postgres-native memory layers (no current equivalent in Constructive or Mem0). (2) Speed: target v0.7.0 tag before T+30 from T0 (2026-05-29) to establish ecosystem lead. (3) COMPETITIVE_TRACKING.md weekly monitoring — growth_lead watches Constructive's GitHub commits and releases. |
| **Residual risk** | Medium over 12 months. This is structural market risk, not implementation risk. Deepening moat via `reinforce()` and entity-graph population (v0.8.0+) is the long-term strategy. |
| **Owner** | growth_lead (competitive monitoring); founder (strategic response if triggered) |

---

### R-08 — Sales execution gap: no pilot customers to validate `reinforce()` ROI claim

| Field | Value |
|-------|-------|
| **Severity** | P1 |
| **Likelihood** | H |
| **Source** | MENTOR_REVIEW_2026-05-19.md §Top-3 risks, risk-1 |
| **Description** | The MENTOR_REVIEW rated sales execution gap as the most fatal risk (failure probability >70% without a CPO/CRO hire). v0.7.0 adds `reinforce()` as an outcome-learning primitive — but without external pilot customers wiring this into production agent loops, the narrative claim ("memory that gets smarter from outcomes") is untestable externally. The only adopter (Agency) is internal, limiting social proof. |
| **Trigger** | v0.7.0 ships; ≤50 GitHub stars at T+7 post-launch; 0 paying customers at T+60. |
| **Mitigation** | (1) This risk is outside the scope of v0.7.0 technical work — escalate to PI + founder. (2) `reinforce()` API design should be optimized for minimal adoption friction (cookbook pattern in USAGE.md, named-parameter calling convention). (3) Agency RESTORE-C1/C2 integration is the de-facto pilot — research_supervisor ensures H-2/H-3 A/B window starts within 2 weeks of v0.7.0 tag, generating real outcome data. |
| **Residual risk** | High — this risk requires founder action on sales/GTM, not engineering mitigation. Escalated per MENTOR_REVIEW. |
| **Owner** | Founder (GTM) — escalated from research_supervisor to PI |

---

## P2 — Post-Release Debt

### R-09 — `recall_diagnostics()` does not expose confidence distribution

| Field | Value |
|-------|-------|
| **Severity** | P2 |
| **Likelihood** | H (will be requested post-ship) |
| **Source** | RESEARCH_BRIEF_PGMREL-070.md §2.1 F-4 |
| **Description** | `recall_diagnostics()` currently exposes `hybrid_enabled` (GUC-only boolean) and session metrics. After v0.7.0, adopters will want to see confidence distribution on their corpus (e.g., histogram, p50/p95) to understand whether `reinforce()` is having an effect. This is not a blocking gap but will generate support questions. |
| **Mitigation** | Add to v0.7.1 backlog: `SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY confidence) AS confidence_p50 FROM pgmnemo.agent_lesson WHERE is_active` SQL probe in USAGE.md as a workaround until `recall_diagnostics()` is extended. |
| **Owner** | chief_architect (v0.7.1 backlog) |

---

### R-10 — `pgmnemo.stats()` reinforcement_count not added in v0.7.0

| Field | Value |
|-------|-------|
| **Severity** | P2 |
| **Likelihood** | L (if missed in PLAN task scope) |
| **Source** | ROADMAP_REVIEW_PGMREL-070.md §5 acceptance gate: "`pgmnemo.stats()` includes `reinforcement_count BIGINT`" |
| **Description** | ROADMAP_REVIEW gate-3 requires `reinforcement_count BIGINT` in `pgmnemo.stats()`. If PLAN task omits this column, the acceptance gate fails at QA. |
| **Mitigation** | Include `reinforcement_count` explicitly in PLAN task scope checklist. Implement as a counter in `pgmnemo.stats()` (either a dedicated counter table incremented by `reinforce()`, or a `COUNT(*)` on a `reinforcement_log` table). |
| **Owner** | chief_architect (PLAN task) |

---

## Risk Summary Table

| ID | Risk | Sev | Likelihood | Owner | Status |
|----|------|-----|-----------|-------|--------|
| R-01 | Bench regression: confidence term breaks recall@10 | P0 | L | chief_architect + research_supervisor | Open |
| R-02 | Footgun list incomplete at implementation lock | P0 | M | chief_architect | Open — blocked on PLAN task |
| R-03 | `reinforced_at` column missing from migration | P0 | L | chief_architect | Open |
| R-04 | `reinforce()` caller burden blocks Agency adoption | P1 | M | TL (Karpov) | Open — confirm RESTORE-C1/C2 |
| R-05 | "Outcome learning" narrative conflated with ML | P1 | M | growth_lead | Open |
| R-06 | Ingestion guards NOTICE flood adopter logs | P1 | M | chief_architect | Open |
| R-07 | Constructive AgenticDB adds provenance enforcement | P1 | L (now) M (12mo) | growth_lead + founder | Ongoing |
| R-08 | Sales execution gap — no external pilot evidence | P1 | H | Founder | Escalated to PI |
| R-09 | `recall_diagnostics()` lacks confidence distribution | P2 | H | chief_architect (v0.7.1) | Backlog |
| R-10 | `reinforcement_count` omitted from `pgmnemo.stats()` | P2 | L | chief_architect | Open — add to PLAN checklist |

---

## Pre-Release Gate Checklist (research_supervisor owned)

- [ ] Bench baseline snapshot: v0.6.3 LongMemEval-S recall@10 run (establishes ±0.001 reference)
- [ ] Agency corpus diagnostic: `recall_diagnostics()` + `pgmnemo.stats()` snapshot pre-upgrade
- [ ] Footgun canonical list reviewed (from PLAN task) — ≥F-1 through F-5, each with test
- [ ] Confidence formula bench gate: recall@10 at `confidence=0.5` flat within [0.9594, 0.9614]
- [ ] `reinforce()` smoke test: call with valid + invalid delta; verify RETURNING value + clamping
- [ ] Ingestion guards NOTICE test: empty role → NOTICE logged; lesson inserted; no ERROR raised
- [ ] `pgmnemo.stats().reinforcement_count` present and incrementing after `reinforce()` calls
- [ ] README §Limitations: anti-promise #4 present before tag (growth_lead sign-off)
- [ ] Agency RESTORE-C1/C2 integration confirmed as wired to `reinforce()` (TL Karpov sign-off)
