# pgmnemo — Tactical Plan, Month 1

**Window:** T0 (2026-04-29) → T+4w (2026-05-27) | **Owner:** technical_lead (5) with PO sign-off

---

## Sprint goal of Month 1

By end of Week 4, have: license locked, repo bootstrapped (private), Phase 1 design complete,
schema migrations drafted, retrieval functions implemented and dogfooded internally on Agency v2,
positioning v1.0 ready for friendly review.

**Month 1 is internal-only.** No public launch this month. Public is Month 2.

---

## Week 1 (T0 → T+1w): Charter + License + Plans

**Goal:** all foundational artifacts exist; license locked; Phase 1 plan reviewed and approved.

| # | Task ID | Title | Owner | Cost | Due |
|---|---------|-------|-------|------|-----|
| W1.1 | 2114 | LICENSE_DECISION_LOCKIN | legal_advocate (74) | $1.00 | T+3d |
| W1.2 | 2115 | BUILD_MVP_EXT_PHASE1_PLAN | technical_lead (5) | $3.00 | T+4d |
| W1.3 | 2116 | LAUNCH_POSITIONING_v0.1 | growth_lead (92) | $2.00 | T+4d |
| W1.4 | 2117 | MENTOR_REVIEW_T0 | startup_mentor (91) | $2.00 | T+3d |
| W1.5 | 2118 | PRODUCT_PLAN | product_owner (16) | $3.00 | T+4d |

Gate at end of Week 1: founder reviews POSITIONING + PRODUCT_PLAN + MENTOR_REVIEW. Go/hold decision.

**Week 1 budget:** $11.00 cumulative.

---

## Week 2 (T+1w → T+2w): Schema + Migration draft + Bench harness

**Goal:** extension scaffolding exists in private repo; schema migrations applied; benchmark harness
ready to compare against OpenBrain.

| # | Task | Owner | Cost (est) |
|---|------|-------|------------|
| W2.1 | Extension scaffolding: `pgmnemo.control`, `pgmnemo--0.0.1.sql`, Makefile | backend_developer (70) | $2.00 |
| W2.2 | Schema design: `agent_lesson`, `memory_concept`, `provenance_log` tables + indexes | chief_architect (86) | $3.00 |
| W2.3 | Migration v1.0: schema + base seed data | backend_developer (70) | $2.00 |
| W2.4 | Benchmark harness setup: BL-B + OpenBrain comparison fixtures | experiment_designer (84) | $3.00 |
| W2.5 | Repo bootstrap (private) — founder runs REPO_BOOTSTRAP_CHECKLIST | founder | $0 |

**Week 2 budget:** $10.00.
**Critical path:** W2.5 (founder action) blocks public-facing W2.1/2.2 commits — but they happen
in private repo from T+1w onward, so blockers are minimal.

---

## Week 3 (T+2w → T+3w): Retrieval functions + Provenance gate + Demo case 1

**Goal:** core retrieval works; provenance gate trigger fires; first end-to-end demo runs.

| # | Task | Owner | Cost (est) |
|---|------|-------|------------|
| W3.1 | `recall_lessons()` PL/pgSQL function with tsvector + trigram | backend_developer (70) | $3.00 |
| W3.2 | `search_concepts()` PL/pgSQL function with role/project filtering | backend_developer (70) | $2.00 |
| W3.3 | Provenance gate trigger — verify commit SHA / artifact hash before promotion | backend_developer (70) | $4.00 |
| W3.4 | Demo case 1: Claude Code agent reading from pgmnemo (script + README) | technical_lead (5) | $2.00 |
| W3.5 | PAPER v0.3 outline aligned with measured Phase 1 results | principal_investigator (77) | $3.00 |
| W3.6 | MENTOR_REVIEW T+2w (biweekly cadence) | startup_mentor (91) | $2.00 |

**Week 3 budget:** $16.00.
**Risk:** W3.3 (provenance gate) is the technical USP — if it slips, all of Month 2 timeline slips.

---

## Week 4 (T+3w → T+4w): Demo case 2 + Internal review + Phase 1 measurement

**Goal:** Phase 1 acceptance gates measured; second demo (multi-agent role routing) shipped
internally; team alignment for Month 2 public launch.

| # | Task | Owner | Cost (est) |
|---|------|-------|------------|
| W4.1 | Demo case 2: multi-agent role routing across 3 agents | technical_lead (5) + backend_developer (70) | $3.00 |
| W4.2 | Phase 1 measurement: recall@10, install time, memory footprint, query p95 | experiment_designer (84) + statistical_analyst (79) | $2.00 |
| W4.3 | Phase 1 measurement vs OpenBrain (head-to-head benchmark) | experiment_designer (84) | $2.00 |
| W4.4 | Internal QA pass — fresh PG container install + smoke test | qa_set (6) | $1.00 |
| W4.5 | PAPER v0.3 first draft (submission-ready) | paper_writer (81) | $4.00 |
| W4.6 | Month-1 retrospective + Month-2 Go/Stop decision (WG vote) | technical_lead (5) | $1.00 |

**Week 4 budget:** $13.00.
**Decision gate:** Founder + WG vote at end of Week 4 — proceed to Month 2 public launch yes/no?

---

## Month 1 budget total

| Week | Budget | Cumulative |
|------|--------|-----------|
| W1   | $11.00 | $11.00 |
| W2   | $10.00 | $21.00 |
| W3   | $16.00 | $37.00 |
| W4   | $13.00 | $50.00 |

**Month 1 cap: $60 (20% buffer over $50 baseline).**
If burn exceeds $60 before W4 retrospective → mandatory founder ack to continue.

## Risks (Month 1 specific)

| # | Risk | Owner | Mitigation |
|---|------|-------|-----------|
| R1 | Provenance gate (W3.3) more complex than estimated | TL | If 2x overrun → defer to W4, reduce demo scope |
| R2 | OpenBrain benchmark hard to set up (W2.4) | ExpDesigner | Fall back to internal-only benchmark; flag for Month 2 |
| R3 | Founder unavailable for repo bootstrap (W2.5) | Founder | Pre-create bootstrap-files/ so action is 5 minutes |
| R4 | License decision drags > Week 1 | legal_advocate | Default to Apache-2.0 + DCO sign-off if no objection by T+5d |
| R5 | Two-product split (Agency + pgmnemo) creates context-switch overhead | TL + PO | Use Agency v2 as pilot user — same codebase, single track |

## Outputs at end of Month 1

By 2026-05-27 the following must exist in `spec/v2/pgmnemo/`:

```
spec/v2/pgmnemo/
├── STRATEGY.md ✓ (created T0)
├── TACTICAL_M1.md ✓ (this file, created T0)
├── PRODUCT_PLAN.md (PO deliverable W1)
├── LICENSE_DECISION.md (legal deliverable W1)
├── POSITIONING.md (growth deliverable W1)
├── REPO_BOOTSTRAP_CHECKLIST.md ✓ (created T0)
├── MENTOR_REVIEW_2026-04-29.md (W1)
├── MENTOR_REVIEW_2026-05-13.md (W3)
├── MENTOR_REVIEW_2026-05-27.md (W4 → Go/Stop)
├── design/
│   └── BUILD_MVP_EXT_PHASE1.md (TL deliverable W1)
├── research/
│   └── (7 frozen copies from memory-svc/, see REPO_BOOTSTRAP_CHECKLIST)
└── (private repo) extension code in github.com/pgmnemo/pgmnemo
```

## Working Group involvement schedule

| Member | W1 | W2 | W3 | W4 |
|--------|----|----|----|----|
| product_owner (16)         | ★  | —  | ★  | ★  |
| technical_lead (5)         | ★  | ★  | ★  | ★  |
| chief_architect (86)       | —  | ★  | —  | ★  |
| backend_developer (70)     | —  | ★  | ★  | ★  |
| principal_investigator (77)| —  | —  | ★  | —  |
| paper_writer (81)          | —  | —  | —  | ★  |
| literature_scout (82)      | —  | —  | —  | —  |
| experiment_designer (84)   | —  | ★  | —  | ★  |
| statistical_analyst (79)   | —  | —  | —  | ★  |
| growth_lead (92)           | ★  | —  | —  | —  |
| legal_advocate (74)        | ★  | —  | —  | —  |
| qa_set (6)                 | —  | —  | —  | ★  |
| startup_mentor (91)        | ★  | —  | ★  | ★  |

★ = active week. Average burn-rate sanity: ~5 active people × 10 hours/week × $5 task budget = $250/week capacity, far above $13/week task budget — so concurrency is not the bottleneck.
