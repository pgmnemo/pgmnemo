# pgmnemo — Product Plan
**Version:** 1.0  
**Date:** 2026-04-29  
**Author:** startup_mentor (agent 87), growth_lead (agent 88)  
**Status:** DRAFT — awaiting founder approval  
**Founder veto:** Active on every P0/P1 strategic decision per AGENTS.md §founder-ack rule

---

## 1. Vision

pgmnemo is a PostgreSQL extension (PL/pgSQL hot-path + optional Rust/pgrx compiled layer) that turns any PostgreSQL 17+ database into a production-grade multi-agent memory substrate — giving AI orchestration systems ACID-consistent episodic, semantic, and working memory co-located with application data, without adding a separate vector database or memory microservice.

## 2. Mission

Ship the fastest, most ops-simple agent memory layer in the PostgreSQL ecosystem within T+12 weeks. Prove community adoption by T+12w milestone gate (≥50 GitHub stars, ≥1 named production deployment, ≥1 inbound inquiry from a PostgreSQL-adjacent vendor). If the gate is not passed, freeze per kill criteria §9.

---

## 3. Target User Segments

### Segment A — Solo / Indie AI Developer (wedge)
- **Profile:** Solo engineer building an AI agent on top of existing Postgres. Runs Docker Compose. Already uses pgvector. Does not want to manage a separate Pinecone/Mem0 subscription.
- **Pain:** Tracking conversation history + semantic retrieval + deduplication across runs requires either a memory SaaS (vendor lock-in, $19–249/mo) or rolling their own schema (maintenance burden).
- **Job to be done:** "Add agent memory to my existing Postgres with one SQL script, zero new services."
- **Acquisition channel:** Hacker News, r/LocalLLaMA, pgvector GitHub issues, X/Twitter dev audience.
- **User stories (acceptance criteria):**
  - **US-A1:** As a solo dev, I can install pgmnemo with `psql -f install.sql` and have `mem.search_semantic()` returning results within 10 minutes. *AC: install.sql idempotent, no superuser required, works on PG17 Docker image.*
  - **US-A2:** As a solo dev, I receive ≤40 ms p95 latency on `mem.search_semantic()` on a corpus of 10K entries. *AC: benchmark reproduced via `make bench` in CI; result logged to console.*

### Segment B — Small AI Platform / Startup (expansion target, T+8w)
- **Profile:** 2–10 person startup building an AI product on Postgres (Supabase, Neon, or self-hosted). Needs multi-tenant agent memory, RBAC, retention policies.
- **Pain:** Mem0 ($249/mo Pro) is getting expensive and its memory is decoupled from their application's data model (user IDs, org IDs, project IDs). Cross-DB consistency is a constant headache.
- **Job to be done:** "Give each of my customers an isolated memory namespace backed by the same DB transaction that handles their other data."
- **Acquisition channel:** Supabase Marketplace, Discord/Slack communities, direct outreach via LinkedIn.
- **User stories:**
  - **US-B1:** As a platform engineer, I can create a tenant-isolated memory namespace via `SELECT mem.create_namespace('tenant_42')` with RLS enforcement. *AC: queries for tenant_42 cannot read tenant_43 memories; enforced at SQL level, no application code required.*
  - **US-B2:** As a platform engineer, I can set per-namespace retention policies (`mem.set_retention('tenant_42', '90 days')`). *AC: pg_cron job runs nightly; expired memories soft-deleted; `mem.active_count('tenant_42')` reflects policy.*

### Segment C — Enterprise / Postgres-Adjacent Infrastructure Vendor (monetisation target, T+24w+)
- **Profile:** EDB, Crunchy Data (Snowflake), Supabase, Neon, Timescale, Yandex Cloud — companies shipping Postgres distributions or managed Postgres, wanting to offer "AI memory" as a managed feature without building in-house.
- **Pain:** Customers ask for native agent memory integration. Building in-house costs 6+ months of Rust/PG expertise.
- **Job to be done:** "Bundle pgmnemo into our distribution and ship it as a premium feature / marketplace extension."
- **Acquisition channel:** Supabase Marketplace extension program, EDB extension certification, Crunchy Data partner program, Yandex Cloud Managed PostgreSQL extension list.
- **User story:**
  - **US-C1:** As a managed Postgres vendor, I can ship pgmnemo as a prebuilt `.so` for PG17 on `linux/amd64` + `linux/arm64` with a single `CREATE EXTENSION pgmnemo;`. *AC: extension passes `make installcheck` on vanilla PG17 Docker; no superuser required for retrieval functions.*

---

## 4. Wedge → Expansion Sequence

```
T0  → T+4w   WEDGE: Solo dev / indie
              Deliver: install.sql, mem.* schema, MCP connector, README
              Signal: GitHub stars, first "I installed it" HN/Reddit post
              Positioning: "pgvector for agent memory"

T+4w → T+8w  EXPANSION-1: Small AI platform / startup
              Deliver: multi-tenant namespaces, RLS, retention policies, Supabase compatibility
              Signal: ≥1 startup using in staging/prod, inbound inquiry in repo issues
              Positioning: "Drop Mem0, use pgmnemo — your Postgres already handles the memory"

T+8w → T+12w EXPANSION-2: OSS launch + commercial positioning
              Deliver: public launch (HN Show HN, Product Hunt), PGXN submission, BSL 1.1 license
              Signal: ≥50 stars, ≥1 named prod deployment, ≥1 vendor inquiry
              Go/No-go: §9 kill criteria evaluated at T+12w milestone gate

T+12w+       EXPANSION-3 (conditional on gate pass)
              Evaluate: managed cloud (Supabase partnership), pgrx upgrade, seed fund raise
              See §8 revenue model decision tree and §6 exit options
```

---

## 5. T0..T+12w Roadmap — Weekly Milestones

All milestones owner: founder (Alex Gaydabura) unless a specific agent role is noted.

### Week 0 (2026-04-29 → 2026-05-03) — BOOTSTRAP
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W0.1 | PRODUCT_PLAN.md approved by founder | startup_mentor | Founder comment in task thread |
| W0.2 | `mem.*` schema SQL scripts: `mem.search_semantic()`, `mem.get_context_pack()`, graph CTE | TL | `psql -f install.sql` on PG17 Docker; all 3 functions return rows |
| W0.3 | RLS provenance gate: `app.role` SET LOCAL + row-level policy `promote_canonical` | TL | `EXPLAIN` shows RLS filter; cross-role read test fails as expected |
| W0.4 | MCP connector for `tasks_db` wired to `mem.*` functions | TL | Agent can call `mem.search_semantic()` via tasks_db MCP in dev |
| W0.5 | GitHub repository created, README (1-screen), install.sql pushed | growth_lead | Repo public, install.sql in root, CI green |

### Week 1 (2026-05-04 → 2026-05-10) — RETRIEVAL CORE
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W1.1 | `mem.insert_memory()`, `mem.forget()`, `mem.active_count()` functions shipped | TL | Unit tests pass; MCP integration test green |
| W1.2 | HNSW index on `mem.memories.embedding` (m=16, ef_construction=128) | TL | `\d mem.memories` shows index; EXPLAIN uses index scan |
| W1.3 | Benchmark script `make bench` — p95 latency target ≤ 40 ms at 10K rows | TL | Bench output in CI logs; PASS/FAIL result logged |
| W1.4 | `pg_cron` dedup job: `mem.curate_cosine_dedup()` runs nightly | TL | pg_cron job registered; manual trigger clears test duplicates |
| W1.5 | COMPETITIVE_TRACKING.md v1 (Constructive AgenticDB, Mem0, Zep, pgvector) | growth_lead | File in repo; ≥8 competitors assessed with pricing and positioning |

### Week 2 (2026-05-11 → 2026-05-17) — WRITE PATH + DISTILLATION
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W2.1 | FastAPI write path (`POST /mem/ingest`, `POST /mem/distill`) wired to `mem.*` schema | TL | API smoke tests pass |
| W2.2 | bge-m3 embedding integration verified against `mem.memories.embedding` column | TL | End-to-end: ingest → embed → `mem.search_semantic()` returns expected result |
| W2.3 | POSITIONING.md v1 — one-sentence pitch, comparison table vs Mem0/pgvector/Constructive | growth_lead | File in repo; founder approves |
| W2.4 | BL-B recall@10 baseline run on live HYBRID stack | PI (77) | recall@10 ≥ 0.60; result logged in spec/reports/ |

### Week 3 (2026-05-18 → 2026-05-24) — MULTI-TENANT + RLS
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W3.1 | `mem.create_namespace()`, namespace-scoped RLS policies | TL | Segment B US-B1 acceptance criteria pass |
| W3.2 | `mem.set_retention()` + pg_cron nightly expiry job | TL | Segment B US-B2 acceptance criteria pass |
| W3.3 | Docker Compose example (`docker-compose.pgmnemo.yml`) | TL | `docker-compose up -d` + `psql -f install.sql` produces working stack in < 5 min from cold start |
| W3.4 | Content calendar v1 (4-week pre-launch posts) | growth_lead | Published; founder approves |

### Week 4 (2026-05-25 → 2026-05-31) — PRIVATE BETA PREP
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W4.1 | `make installcheck` CI: PostgreSQL standard regression tests green | TL | CI badge green on GitHub |
| W4.2 | Private beta: 3–5 solo devs / startups invited | growth_lead | ≥3 people have installed and sent feedback |
| W4.3 | BIWEEKLY MENTOR REVIEW #1 | startup_mentor (87) | Review published in `spec/reports/MENTOR_REVIEW_W4.md` |
| W4.4 | BSL 1.1 license draft reviewed by founder | founder | LICENSE file in repo; license FAQ page drafted |

### Week 5 (2026-06-01 → 2026-06-07) — FEEDBACK INTEGRATION
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W5.1 | Top-3 private beta bug fixes shipped | TL | Closed issues; beta testers re-verify |
| W5.2 | `mem.explain_context_pack()` — human-readable debug output for context selection | TL | Function returns structured explanation of which memories were selected and why |
| W5.3 | PGXN submission (pgxn.org) — packages `pgmnemo 0.1.0` | TL | PGXN page live; `pgxnclient install pgmnemo` works |

### Week 6 (2026-06-08 → 2026-06-14) — HN LAUNCH PREP
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W6.1 | LAUNCH_PLAN.md v1 — HN "Show HN" draft, timing, upvote campaign | growth_lead (88) | Draft approved by founder |
| W6.2 | Demo video (< 3 min): install pgmnemo, run an agent, show memory retrieval | founder | Video uploaded; link in README |
| W6.3 | Supabase Marketplace submission request filed | growth_lead | Submission email/form sent; tracking issue opened |
| W6.4 | BIWEEKLY MENTOR REVIEW #2 | startup_mentor | Review published in `spec/reports/MENTOR_REVIEW_W6.md` |

### Week 7 (2026-06-15 → 2026-06-21) — PUBLIC LAUNCH
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W7.1 | **LAUNCH: Show HN** post goes live | founder | Post up; ≥30 upvotes within 48h |
| W7.2 | **LAUNCH: Product Hunt** listing | growth_lead | PH page live on launch day |
| W7.3 | Competitive re-evaluation post-launch (Constructive AgenticDB response?) | growth_lead | COMPETITIVE_TRACKING.md v2 published |
| W7.4 | GitHub star count logged — first public signal data point | growth_lead | Logged in `spec/reports/LAUNCH_METRICS.md` |

### Week 8 (2026-06-22 → 2026-06-28) — STABILISATION + EXPANSION
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W8.1 | Post-launch bug fixes, issues triaged | TL | No P0 open issues; P1s have assigned ETA |
| W8.2 | First Segment C vendor outreach: EDB, Crunchy (Snowflake), Supabase, Yandex Cloud | growth_lead | ≥2 emails sent; responses logged in `spec/reports/VENDOR_OUTREACH.md` |
| W8.3 | BIWEEKLY MENTOR REVIEW #3 | startup_mentor | Review published in `spec/reports/MENTOR_REVIEW_W8.md` |
| W8.4 | pgrx upgrade path evaluation: are ≥2 of 4 trigger conditions met? | TL | Finding logged in `spec/v2/pgmnemo/PGRX_EVALUATION_W8.md`; decision deferred or actioned |

### Week 9–10 (2026-06-29 → 2026-07-12) — ENTERPRISE HOOKS + pgrx DECISION
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W9.1 | `mem.audit_log` table + `mem.enable_audit()` (enterprise BSL-gated feature) | TL | Audit events written on insert/delete; RLS enforced |
| W9.2 | `mem.search_hybrid()` — BM25 + vector fusion (pg_trgm or pg_search) | TL | Hybrid recall@10 ≥ pure vector recall on BL-B fixture |
| W9.3 | If pgrx trigger conditions met (W8.4): Rust spike for `mem_temporal_score` custom operator | TL | Spike doc in `spec/v2/pgmnemo/PGRX_SPIKE.md`; decision recorded |
| W10.1 | BIWEEKLY MENTOR REVIEW #4 | startup_mentor | Review published in `spec/reports/MENTOR_REVIEW_W10.md` |

### Week 11–12 (2026-07-13 → 2026-07-26) — T+12W MILESTONE GATE
| # | Milestone | Owner | Done criterion |
|---|-----------|-------|----------------|
| W11.1 | StatAnalyst kill-criteria measurement run | statistical_analyst (79) | Report in `spec/reports/KILL_CRITERIA_T12W.md`; all 3 metrics measured |
| W11.2 | Metrics audit: GitHub stars ≥ 50? Named prod deployment ≥ 1? Inbound inquiry ≥ 1? | growth_lead | Metrics logged; go/no-go recommendation filed |
| W11.3 | BIWEEKLY MENTOR REVIEW #5 — T+12W VERDICT | startup_mentor | Review in `spec/reports/MENTOR_REVIEW_W12.md`; PASS / KILL / INTERESTED verdict |
| W12.1 | **FOUNDER DECISION** — exit option (§6) or continue → revenue path (§8) | founder | Decision documented in `spec/v2/pgmnemo/FOUNDER_DECISION_T12W.md` |

---

## 6. Exit Options

Each option requires founder hard veto clearance before actioning.

### Option A — Acqui-hire / Strategic Acquisition
**Targets:** PostgresPro, EDB, Crunchy Data (Snowflake), Yandex Cloud  
**Rationale:** Crunchy Data sold for $250M at $30M ARR with ~100 employees (June 2025). EDB at $161M revenue (2025). Both demonstrate the "Postgres-expert team → strategic acquisition" pattern. (Source: EXT-2 §C-2.)

**Go-conditions (all must be true):**
1. T+12w gate passes (≥50 stars OR ≥1 named prod deployment)
2. Inbound interest from ≥1 acquisition target (email, issue comment, LinkedIn, conference)
3. Founder has ≥6 months runway remaining
4. Competing offer OR strategic urgency exists (e.g., Constructive AgenticDB poaching user base)

**What to bring to the conversation:** GitHub star trajectory + BL-B recall@10 benchmark data + named deployments + BSL 1.1 license (signals commercial intent) + HYBRID architecture doc.  
**Owner:** founder; **trigger:** growth_lead signals inbound vendor interest (from W8.2 outreach)  
**Founder veto:** Required before any NDA or LOI is signed.

---

### Option B — Open-Core SaaS (Supabase / ParadeDB model)
**Targets:** Build `pgmnemo.cloud` — managed Postgres + pgmnemo, hosted on Fly.io / Railway  
**Rationale:** ParadeDB raised $14M Series A (July 2025) with Rust PG extension + managed cloud. Supabase is a distribution partner and potential acquirer ($5B valuation, 2025). OSS core (BSL 1.1) + paid managed tier is the most validated Postgres commercialisation pattern. (Source: EXT-2 §C-2, §C-4.)

**Go-conditions (all must be true):**
1. T+12w gate passes (≥50 stars, ≥1 named prod deployment, ≥1 vendor inquiry)
2. ≥3 beta users willing to pay ≥$49/mo for hosted pgmnemo
3. Founder has ≥12 months runway for infra investment
4. Supabase Marketplace listing approved OR PGXN installs ≥ 200

**Revenue model:** See §8. Managed tier $49–499/mo; enterprise license custom.  
**Owner:** founder; **trigger:** payment intent signals from ≥3 beta users  
**Founder veto:** Required before any cloud infrastructure spend exceeds $500/mo.

---

### Option C — Freeze
**Conditions:** All three kill criteria §9 thresholds hit simultaneously at T+12w (2026-07-26).  
**Action:** Stop new feature development. Archive repo as read-only. Publish post-mortem. Redirect founder bandwidth to core Agentura product.  
**What is preserved:** SQL scripts remain publicly accessible under BSL 1.1 (or MIT if freeze decision includes license downgrade). Code is not deleted.  
**Owner:** founder; **trigger:** StatAnalyst kill-criteria report (W11.1) + startup_mentor KILL verdict (W11.3)  
**Founder veto:** Founder may override freeze with explicit written justification in `FOUNDER_DECISION_T12W.md` (e.g., late-breaking inbound vendor acquisition interest).

---

## 7. Kill Criteria (StatAnalyst-sourced)

**Primary kill signal — all three must be true simultaneously at T+12w (2026-07-26):**

| Criterion | Kill threshold | Rationale |
|-----------|---------------|-----------|
| GitHub stars | < 50 at 2026-07-26 | ParadeDB had >1K stars at Series A pitch (EXT-2 §C-2); 50 is minimal viable OSS signal for a narrow-niche extension |
| Inbound product inquiries | 0 in the T0→T+12w window | No GitHub issues expressing adoption intent + no email/Discord/HN comment = zero market pull |
| Production deployments | 0 named deployments | Even 1 developer self-reporting "using in prod" proves the install path works and someone finds it valuable |

**Interpretation of partial failure:**
- 40 stars + 1 prod deployment → **CAUTION** — startup_mentor decides CONTINUE / PIVOT / FREEZE at W11.3
- 0 stars + 0 inquiries + 0 prod deployments → **FREEZE** — kill criteria fully triggered
- ≥50 stars + 0 prod deployments + 0 inquiries → **PASS** (community interest, no adoption — extend 4 weeks)

**Secondary kill signals (trigger immediate mentor review, not automatic freeze):**
- Constructive AgenticDB ships compiled Rust extension with feature parity before T+12w
- Mem0 or Zep ships native Postgres integration, removing the wedge
- pgrx reaches 1.0.0 AND Constructive ships Rust extension simultaneously — HYBRID moat gone
- Founder runway drops below 3 months before T+12w gate

**Kill execution process:**
1. W11.1 — StatAnalyst publishes `spec/reports/KILL_CRITERIA_T12W.md`
2. W11.3 — startup_mentor issues MENTOR REVIEW #5 verdict
3. W12.1 — founder makes final decision in `spec/v2/pgmnemo/FOUNDER_DECISION_T12W.md`

---

## 8. Hire Plan

pgmnemo runs on Agentura's virtual-agent team (TL=5, PI=77, growth_lead=88, startup_mentor=87) during T0→T+12w. No human hires are expected or budgeted before the T+12w milestone gate.

### When do we need a pgrx / Rust dev?

**Trigger:** pgrx upgrade path evaluation (W8.4) shows ≥2 of the 4 trigger conditions met (from SYNTHESIS §5.4):
1. pgrx reaches 1.0.0 stable API
2. A bge-m3-class model ≤100M params passes the 0.58 recall@10 boundary (RES-MEM-EMBED-1)
3. `pg_net` or equivalent matures to production-grade outbound HTTPS with retry semantics
4. Team scales beyond 1 founder

**Expected timing:** Not before T+24w. If Option B (managed cloud) is actioned post-T+12w, a pgrx/Rust dev becomes necessary for the compiled extension moat within the T+24w → T+36w window.

**Profile required:** 2+ years Rust production experience; prior pgrx contribution or shipped production extension (ideal: VectorChord / TimescaleDB / plrust contributor); Postgres internals knowledge (access method API, planner hooks). Full-time equivalent.

**Source:** pgrx Discord server, Rust PostgreSQL Ecosystem Zulip, direct GitHub outreach to VectorChord / pgvecto.rs contributors. Budget: $120–180K/year (competitive with ParadeDB / TimescaleDB open roles).

### When do we need a DevRel?

**Trigger:** GitHub stars ≥ 200 AND weekly install velocity ≥ 20 installs/week AND ≥3 active external pull request contributors.

**Expected timing:** T+16w → T+24w if Option B proceeds after the milestone gate.

**Profile required:** Developer advocate with credibility in both Postgres and LLM/AI communities. Must have public content track record (blog posts, conference talks, YouTube) on Postgres or AI infrastructure. Must be able to write SQL and demo pgmnemo without assistance. Not a pure marketing hire.

**Source:** Postgres community (pgDay speakers, PostgreSQL Wiki contributors), AI infrastructure Discord/Slack communities.

---

## 9. Revenue Model Decision Tree

**Pre-T+12w: revenue target = $0. Objective is adoption and community signal, not revenue.**

```
T+12w gate PASS?
│
├─ YES → revenue decision
│   │
│   ├─ ≥3 beta users willing to pay ≥$49/mo AND runway ≥ 12mo?
│   │   └─ YES → MANAGED CLOUD (Option B)
│   │       Model:  $49/mo Starter (1 namespace, 100K memories)
│   │               $199/mo Growth (10 namespaces, 1M memories, audit log)
│   │               Custom Enterprise (SLA, BYOK, SOC2 roadmap)
│   │       Stack:  Fly.io or Railway + pgmnemo + bge-m3 sidecar
│   │       License: BSL 1.1 — self-host free, cloud use requires paid tier
│   │       Signal to raise seed: ≥$5K MRR OR ≥1 enterprise LOI
│   │
│   ├─ < 3 payers BUT ≥1 vendor inbound inquiry (from W8.2)?
│   │   └─ ENTERPRISE LICENSE (targeted OEM deal)
│   │       Model:  Named-user license per deployment; $5K–$50K/year
│   │               OEM integration deal with EDB / Crunchy / Supabase / Yandex
│   │       Trigger: ≥1 vendor confirms evaluation intent
│   │       Ceiling: 1–2 deals covers 12mo runway; not a scalable business alone
│   │
│   └─ No payers AND no vendor inquiry → SERVICES (runway extension only)
│       Model:  Integration consulting at $150–250/hr
│               Target: Segment B startups wanting pgmnemo but lacking PG ops
│               Ceiling: $30–50K total; bridge only — not a company strategy
│
└─ NO → FREEZE (§6 Option C)
        OR ACQUI-HIRE if inbound acquisition interest exists despite gate failure
```

### License strategy (confirmed by WG vote 5-0-0, pending founder approval)

| Component | License | Rationale |
|-----------|---------|-----------|
| Core SQL schema (`mem.*`) | BSL 1.1 | Prevents AWS/GCP free-riding; self-hosted use free; cloud providers must license. TimescaleDB / MariaDB precedent. |
| Python write/distillation service (FastAPI) | MIT | Maximum adoption, zero friction for Segment A; no meaningful cloud-provider risk here |
| pgrx compiled extension (when shipped) | BSL 1.1 | Consistent with TimescaleDB / ParadeDB model; binary moat requires license enforcement at distribution layer |
| Managed cloud tier | Proprietary SaaS | On top of BSL 1.1 core; explicit carve-out in BSL for internal use |

**Decision point (Gate 2 §10):** Founder must choose BSL 1.1 vs Apache-2.0 before PGXN submission (W5.3). Apache-2.0 maximises stars; BSL 1.1 protects commercial path. This is a founder P0 decision — no agent can resolve it.

**Pre-launch requirement:** License FAQ page (single markdown file in repo) citing TimescaleDB and MariaDB BSL precedent, before HN launch (W7.1), to pre-empt "is this really open source?" threads.

---

## 10. WG Condition Gates

All four gates require founder approval before any downstream action. Founder retains hard veto per AGENTS.md §founder-ack rule.

### Gate 1 — PAPER-FIRST / Architecture Decision (HYBRID)
**Documents:**
- `spec/v2/memory-svc/SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md` — WG vote 5-0-0 for HYBRID
- `spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md` — FEASIBLE_WITH_RISK
- `spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md` — VIABLE_WITH_RISK

**Condition met:** Technical feasibility = FEASIBLE_WITH_RISK AND commercial viability = VIABLE_WITH_RISK → HYBRID trigger per decision rule §4 of synthesis doc.  
**WG vote:** 5-0-0 unanimous (PI 77, LitScout 82, ExperimentDesigner 84, StatAnalyst 79, TL 5)  
**Status:** PROPOSED — pending founder approval 2026-04-29  
**What it unlocks:** Proceed with `mem.*` schema implementation (W0.2–W0.4, W1.1–W1.4)  
**If founder vetoes HYBRID:** Choose STAY (continue FastAPI path, no commercial positioning) or PIVOT (8–12 week Rust delay; not recommended per WG scoring 2.85/5.00)

### Gate 2 — LICENSE / BSL 1.1 Adoption
**Document:** `spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md §C-3`  
**Condition:** Founder approves BSL 1.1 for `mem.*` SQL schema core  
**Deadline:** Before W5.3 PGXN submission (2026-06-07)  
**Status:** Pending  
**What it unlocks:** Commercial positioning, PGXN submission with correct license metadata, Supabase Marketplace submission, OEM deal conversations  
**Veto note:** Founder may choose Apache-2.0 or MIT; this trades commercial defensibility for maximum community adoption. Decision is permanent — changing license after public release damages trust.

### Gate 3 — METRICS / T+12w Milestone Gate
**Document:** `spec/reports/KILL_CRITERIA_T12W.md` (to be created at W11.1)  
**Condition:** ≥50 GitHub stars OR ≥1 named prod deployment OR ≥1 vendor inquiry by 2026-07-26  
**Status:** Pending measurement  
**What it unlocks:**
- PASS → revenue model decision tree (§8); exit option evaluation (§6); pgrx upgrade path re-evaluation
- FAIL → kill criteria §7 executed; freeze unless founder veto

### Gate 4 — KILL / Freeze Trigger
**Document:** startup_mentor MENTOR REVIEW #5 (`spec/reports/MENTOR_REVIEW_W12.md`)  
**Condition:** All three primary kill thresholds hit simultaneously (< 50 stars AND 0 inquiries AND 0 prod deployments) at T+12w  
**Status:** Pending  
**What it unlocks:** Freeze execution; founder decision in `spec/v2/pgmnemo/FOUNDER_DECISION_T12W.md`  
**Veto note:** Founder may override kill with explicit written justification (e.g., late-breaking inbound acquisition interest that post-dates the measurement window). Justification must be documented.

---

## Appendix A — Key References

| Document | Purpose |
|----------|---------|
| `spec/v2/memory-svc/SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md` | HYBRID architecture WG vote; scoring matrix; 4 trigger conditions for pgrx upgrade |
| `spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md` | Technical: pgrx risks, embedding-in-PG impossibility, latency projections (−47% p95) |
| `spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md` | Commercial: 8 competitors, 6 case studies, 6 license options, market sizing (35% CAGR) |
| `spec/v2/memory-svc/SPIKE_EMBED_BENCHMARK.md` | BL-B recall@10: bge-small REJECT (0.578); bge-m3 anchor = 0.620 |
| `spec/v2/memory-svc/ADR_002_DATA_MODEL.md` | Canonical schema: mem.memories, mem.episodes, mem.graph_edges |
| `agents/startup_mentor/SKILL.md` | Mentor review template and kill signal taxonomy |
| `agents/growth_lead/SKILL.md` | Growth and DevRel charter |
| `spec/v2/pgmnemo/_migration_001_bootstrap.sql` | DB bootstrap: project_id=18, assignee_id=87/88, Week-0 tasks |

---

## Appendix B — Risks at T0

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| R1 | Constructive AgenticDB gains traction before pgmnemo launches (schema-only, 2026-04-28) | HIGH | Ship `mem.*` SQL to GitHub within 2 weeks (W1.5); establish HNSW benchmark as differentiator; position compiled extension as roadmap moat |
| R2 | bge-m3 MLX LaunchAgent single point of failure on macOS reboot | MEDIUM | Document recovery in README; provide fallback `text-embedding-3-small` path in `mem.ingest()` |
| R3 | pgrx pre-1.0 instability blocks compiled extension path | MEDIUM | HYBRID architecture explicitly defers pgrx; PL/pgSQL path carries zero pgrx risk regardless |
| R4 | Founder single-point-of-failure (solo team, no delegation to human devs) | HIGH | Scope T0–T+12w to SQL-only deliverables any PG-literate contributor can maintain; pgrx dev hired only after gate passes |
| R5 | BSL 1.1 "not really open source" backlash on HN launch | MEDIUM | Prepare license FAQ before W7.1; cite TimescaleDB / MariaDB BSL precedent; MIT on FastAPI layer preserves community goodwill |
| R6 | Zero revenue path if Option B requires >12mo runway | MEDIUM | Services fallback ($150–250/hr) provides runway extension without structural commitment; sets ceiling explicitly |
