# pgmnemo — Strategic Charter

**Status:** ACTIVE | **T0:** 2026-04-29 | **Project ID:** 20 | **Owner:** product_owner (16) with founder veto on P0/P1 decisions

---

## Vision

The default memory layer for any AI-agent system that already runs on PostgreSQL — installed with one
SQL command, written and read entirely inside the database, owned end-to-end by the user.
No separate service. No vendor lock-in. No data leaving the perimeter.

## Mission

Ship an open-source PostgreSQL extension (`pgmnemo`) that gives multi-agent AI systems a durable,
provenance-gated memory substrate **without** introducing a separate service, a SaaS dependency, or
a proprietary lock-in. Be the `pgvector` of agent memory: small, pg-native, universal.

---

## What we sell, in one sentence

> **pgmnemo is the multi-agent memory layer for teams that already trust their PostgreSQL.**

## What is unique

| | Competitors | pgmnemo |
|---|---|---|
| Form factor | separate service / SaaS | `CREATE EXTENSION pgmnemo;` |
| Data location | their cloud / their server | your existing PostgreSQL |
| Trust gate on writes | none | **provenance gate** — write requires commit SHA or artifact hash |
| Multi-agent role isolation | RLS or none | first-class — role + project + provenance composite |
| Vendor lock-in | yes (data egress, proprietary API) | none (Apache-2.0, plain SQL) |

The **provenance gate** is the wedge. Nobody else does it. Patentable. Defensible.

---

## Target users (3 segments, ranked by wedge fit)

### Segment 1 — Indie AI builders running multi-agent stacks (primary wedge)
- Profile: 1–5 person teams, building AI agents on top of OpenAI / Claude / Ollama
- Already on PostgreSQL (Supabase, Neon, self-host)
- Pain: every agent framework ships its own memory abstraction, none of them durable, none of them auditable
- Reach: HackerNews, dev.to, r/LocalLLaMA, r/MachineLearning, AI Engineer conferences

### Segment 2 — Enterprise AI teams under data-sovereignty constraints
- Profile: regulated industries (finance, healthcare, government); EU/RU sovereignty rules
- Already on managed PostgreSQL (RDS, AWS Aurora, EDB, PostgresPro)
- Pain: existing memory services (Pinecone, Zep, mem0) require data egress; legal team blocks
- Reach: PostgresPro / EDB / Crunchy / Yandex Cloud channel partnerships

### Segment 3 — Postgres extension ecosystem aficionados
- Profile: people who already use pgvector, pgrouting, citus, timescaledb
- Pain: love the extension model, want their AI memory in the same shape
- Reach: PGConf, PgDay, FOSDEM PGDay, postgres-weekly newsletter

---

## Differentiators (how we are not OpenBrain or Constructive)

1. **Extension form, not a service.** OpenBrain is a service-with-MCP. We are SQL functions inside Postgres.
2. **Provenance gate.** No competitor requires a verifiable artifact (commit SHA / file hash) before promoting a write to long-term storage. Without this, agent memory accumulates hallucinations.
3. **Universal AI provider compatibility.** No coupling to OpenAI / Claude / any specific LLM. Bring your own embeddings.
4. **Apache-2.0 with patent grant.** Not BSL, not FSL. Open-vendor friendly. PostgresPro/EDB can ship it bundled.
5. **Russian + global market.** RU-language support first class (bge-m3 multilingual baseline, fallback). Constructive doesn't, OpenBrain doesn't.

---

## Strategic sequence

```
T0 (now)         Internal-first: Agency v2 dogfoods pgmnemo as its memory layer
                 (BUILD-MEM-001 Phase 1 retargeted to extension form, not microservice)

T+6w             Extension MVP shippable internally: schema, retrieval, provenance gate,
                 acceptance gates met (recall@10 ≥ 0.55, install ≤ 5 min, footprint ≤ 50 MB,
                 zero external API calls on read)
                 Paper v0.3 submission-ready (PI + paper_writer)

T+8w             PAPER v0.3 submitted to ICSE-SEIP (paper-first condition)
                 Public GitHub repo created, Apache-2.0 LICENSE committed
                 README + 2 demo cases public

T+12w            STAGE 1 KILL GATE (StatAnalyst): if < 50 stars + 0 inquiries
                 + 0 prod deployments outside Agency → FREEZE

T+12w (success)  Variant 2 MCP server added; HN launch; conference CFP submissions
                 Approach Postgres-vendor partners (PostgresPro RU, EDB US)

T+24w            Decision: Variant 3 (Rust pgrx) or Variant 4 (Open-Core SaaS) or hold
```

---

## Working Group conditions (from 2026-04-29 vote, 5-0-0)

These are mandatory gates. Any breach pauses the project until founder ack.

| # | Condition | Owner | Gate |
|---|-----------|-------|------|
| **1** | PAPER v0.3 (Phase 1 measured) submitted on ICSE-SEIP **before** public GitHub release | principal_investigator (77) + paper_writer (81) | T+8w |
| **2** | License = Apache-2.0 with first-commit `LICENSE` file; CLA decision documented | legal_advocate (74) | T+1w |
| **3** | BUILD_MVP_EXT_PHASE1 plan contains: recall@10 ≥ 0.55 / install ≤ 5 min / footprint ≤ 50 MB / zero external API calls on read + competitive baseline vs OpenBrain | technical_lead (5) + experiment_designer (84) | T+1w |
| **4** | Kill criteria at T+12w public release: < 50 stars + 0 inquiries + 0 prod deployments → freeze | statistical_analyst (79) | T+12w |

## Hard prohibitions

- Variant 3 (Rust+pgrx) **does not enter implementation** until pgrx-experienced engineer is hired
- Two products in parallel **forbidden** — Agency v2 internal use is pgmnemo's pilot user, not a separate track
- License **cannot** be changed from Apache-2.0 retroactively without all-contributors CLA re-sign

## Founder veto rule

All P0 and P1 strategic decisions require founder ack:
- Public release date
- License change
- Pricing announcement
- Pivot or kill recommendation from `startup_mentor`
- Hire decisions (pgrx engineer, DevRel, legal counsel)

PO (assignee 16) executes operationally; founder retains chairman-level veto.

---

## Org structure

```
Founder (Alex Gaydabura) — CEO/Chairman, P0/P1 veto holder
│
├── Product Owner (16) — operational PO, customer voice, roadmap
├── Startup Mentor (91) — biweekly venture-style review, brutally honest
│
├── Tech track
│   ├── Tech Lead (5) — owns shipping
│   ├── Chief Architect (86) — owns extension architecture
│   ├── Backend Developer (70) — implementation
│   └── QA (6) — testing
│
├── Research track (paper-first track)
│   ├── Research Supervisor (85)
│   ├── Principal Investigator (77)
│   ├── Paper Writer (81)
│   ├── Literature Scout (82)
│   ├── Experiment Designer (84)
│   ├── Statistical Analyst (79) — owns kill-criteria
│   └── Simulation Engineer (80)
│
├── Go-to-market track
│   ├── Growth Lead (92) — positioning, launch, content, DevRel, community
│   └── Legal Advocate (74) — license, CLA, patent
│
└── Process
    └── Process Guardian (78) — standards compliance
```

Core weekly involvement: PO, TL, PI, backend_dev, growth_lead, mentor.
Gate-only involvement: rest.

---

## Reference artifacts

- Tactical plan (Month 1): `TACTICAL_M1.md`
- Product plan: `PRODUCT_PLAN.md` (PO ownership; skeleton in repo, full version pending PO task 2118)
- Repo bootstrap checklist: `REPO_BOOTSTRAP_CHECKLIST.md`
- Research portfolio: `research/` (frozen copies of pre-pivot research)
- Competitive tracking: `COMPETITIVE_TRACKING.md` (growth_lead append-only)
- Mentor reviews: `MENTOR_REVIEW_<date>.md` (biweekly)

## Pre-pivot reference (frozen)

- `spec/v2/memory-svc/PAPER_DESIGN-MEM-001_v0.1.md` — original architecture paper
- `spec/v2/memory-svc/ADR_001_SUBSTRATE.md`, `ADR_002_DATA_MODEL.md` — substrate/data model decisions
- `spec/v2/memory-svc/SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md` — pivot decision (HYBRID 5-0-0)
- `spec/reports/RETRO_F-A1-FIX-3_REGRESSION.md` (addendum 2026-04-29) — ADR confirmations
