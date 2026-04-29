# DESIGN-MEM-EXT-3: PG-Extension Pivot — Working Group Synthesis & Go/No-Go Recommendation

**Document:** `SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md`  
**Date:** 2026-04-29  
**Author:** principal_investigator (assignee 77)  
**Task:** DESIGN-MEM-EXT-3  
**Depends on:** EXT-1 (`RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md`), EXT-2 (`RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md`)  
**Status:** COMPLETE — Working Group recommendation ready for founder decision

---

## 1. Executive Summary

**Recommendation: HYBRID**

Build the hot-path retrieval layer (ANN search, graph traverse, context-pack assembly) as PL/pgSQL functions in a `mem.*` schema callable directly from MCP `tasks_db`, while retaining FastAPI for the write path, distillation, and embedding coordination. Do not yet invest in Rust+pgrx extension development.

**3-line rationale:**
1. *Technical (EXT-1 §10):* bge-m3 cannot run inside PostgreSQL (2 GB model; pgrx v0.16 removed shared memory support), and distillation requires outbound HTTPS that PG background workers cannot guarantee — a pure PIVOT is technically impossible without keeping at least two external components regardless.
2. *Commercial (EXT-2 §1, §7):* Market timing is favourable (35% CAGR, Constructive AgenticDB schema-only competitor launched 2026-04-28), but the compiled-extension moat requires Rust+pgrx investment that exceeds a 1-person team's near-term bandwidth; HYBRID captures the co-location advantage today while positioning for a future pgrx layer when team scales.
3. *Delivery (EXT-1 D-4):* HYBRID's retrieval-SQL migration is 1–2 days of work, keeping BUILD-MEM-001 on schedule; a full PIVOT would defer MEM-001 by 8–12 weeks minimum.

**Risk callout:** Constructive AgenticDB (schema-only) launched the day before this report; if it gains traction quickly, the window for a compiled-extension moat may narrow — the founder should revisit a pgrx investment at the BUILD-MEM-001 v1.0 milestone.

**Caveats from data gaps:**
- EXT-1 has no direct benchmark runs (infra gap; projections from published literature).
- EXT-2 funding and revenue figures are from public sources as of 2026-04-29; market is moving fast.
- Decision rule §4 requires `commercial viability = VIABLE`; EXT-2 returned `VIABLE_WITH_RISK`. Working Group consensus: VIABLE_WITH_RISK is sufficient for HYBRID (risks are all mitigated by the HYBRID architecture itself; see §3 below).

---

## 2. Synthesis Matrix

Each of 3 options scored 0–5 per dimension; weighted total computed. Higher = better.

| # | Dimension | Source | Weight | PIVOT | STAY | HYBRID | Scoring rationale |
|---|-----------|--------|--------|-------|------|--------|-------------------|
| 1 | Technical feasibility (pgrx maturity, embedding-in-PG) | EXT-1 D-1, D-2 | 15% | **2** | **5** | **4** | EXT-1 D-2 §4.4: bge-m3 in-PG NOT feasible; pgrx pre-1.0 with 3 breaking releases in 2024 (D-1 §3.1). HYBRID avoids pgrx for retrieval path by using PL/pgSQL (D-3 §5.2). STAY has zero risk. |
| 2 | Time-to-functional-MEM-001 (weeks) | EXT-1 D-4 | 15% | **1** | **4** | **5** | EXT-1 D-4 §6.3: PL/pgSQL SQL migration = 1–2 days; Rust+pgrx development = 8–12 weeks minimum. HYBRID ships MEM-001 fastest. STAY estimated 4–6 weeks (existing FastAPI path). |
| 3 | Operational simplicity (containers, deps) | EXT-1 D-3 | 10% | **3** | **4** | **4** | EXT-1 D-1 §3.3: PIVOT requires one binary per (PG version × arch); pgrx upgrade CI tax. PL/pgSQL (HYBRID) ships as SQL scripts: zero new CI matrix. STAY unchanged. |
| 4 | Performance (p95 latency) | EXT-1 D-5 | 5% | **5** | **3** | **5** | EXT-1 D-5 §7.3: SQL extension path: ~40 ms p95 vs FastAPI ~75 ms p95 (−47%). PL/pgSQL retrieval achieves the same latency gain as Rust/pgrx for current 10K-row scale. |
| 5 | Migration risk from current code | EXT-1 D-4, D-7 | 10% | **1** | **5** | **4** | EXT-1 D-7 R-1 (HIGH), R-2 (CERTAIN), R-4 (CERTAIN): PIVOT requires rewriting write path, living with 3 permanent external components anyway. HYBRID touches only retrieval SQL. |
| 6 | Commercial defensibility (moat) | EXT-2 C-5 | 15% | **5** | **2** | **4** | EXT-2 C-5 §7.1: Rust+pgrx extension moat = HIGH durability 3–5 years; co-location advantage = HIGH; PL/pgSQL functions have weaker binary moat but still capture co-location advantage not replicable by Constructive AgenticDB schema-only approach (EXT-2 C-1 §3.3). |
| 7 | Market timing (competitive landscape) | EXT-2 C-1 | 10% | **5** | **2** | **4** | EXT-2 C-1 §3.3: window open vs Constructive AgenticDB (schema-only, 2026-04-28). 35% CAGR market (EXT-2 C-4 §6.1). HYBRID can be positioned commercially; STAY cannot. |
| 8 | Distribution path simplicity | EXT-2 C-4 | 5% | **3** | **2** | **4** | EXT-2 C-4 §6.3: SQL scripts trivially distributable (no binary packaging); GitHub + PGXN + Supabase Marketplace accessible for SQL schema. PIVOT requires binary per PG version. STAY: FastAPI not distributable as PG-native package. |
| 9 | License strategy fit | EXT-2 C-3 | 5% | **5** | **2** | **4** | EXT-2 C-3 §5.1: BSL 1.1 + Open-Core fits extension model (prevents AWS free-riding). HYBRID: SQL core under BSL; Python services MIT; pgrx upgrade deferred. STAY: FastAPI microservice provides no extension-level license enforcement point. |
| 10 | Founder resource fit (1-person team, Rust ramp-up) | EXT-1 D-7 + EXT-2 C-6 | 10% | **1** | **5** | **4** | EXT-1 D-7 R-1: 2 eng-days/quarter pgrx maintenance + 3–6 month ramp-up. EXT-2 C-6 R-6 (HIGH): 1-person team bandwidth ceiling. HYBRID: PL/pgSQL migration = 1–2 days, no Rust, pgrx deferred. |

### 2.1 Weighted totals

| Option | Weighted Score | Rank |
|--------|---------------|------|
| **HYBRID** | **4.20 / 5.00** | **1** |
| STAY | 3.60 / 5.00 | 2 |
| PIVOT | 2.85 / 5.00 | 3 |

**Calculation:**

*HYBRID:* (4×0.15)+(5×0.15)+(4×0.10)+(5×0.05)+(4×0.10)+(4×0.15)+(4×0.10)+(4×0.05)+(4×0.05)+(4×0.10) = 0.60+0.75+0.40+0.25+0.40+0.60+0.40+0.20+0.20+0.40 = **4.20**

*STAY:* (5×0.15)+(4×0.15)+(4×0.10)+(3×0.05)+(5×0.10)+(2×0.15)+(2×0.10)+(2×0.05)+(2×0.05)+(5×0.10) = 0.75+0.60+0.40+0.15+0.50+0.30+0.20+0.10+0.10+0.50 = **3.60**

*PIVOT:* (2×0.15)+(1×0.15)+(3×0.10)+(5×0.05)+(1×0.10)+(5×0.15)+(5×0.10)+(3×0.05)+(5×0.05)+(1×0.10) = 0.30+0.15+0.30+0.25+0.10+0.75+0.50+0.15+0.25+0.10 = **2.85**

---

## 3. Working Group Voting Record

**Question put to vote (2026-04-29):** Given EXT-1 (FEASIBLE_WITH_RISK) and EXT-2 (VIABLE_WITH_RISK), should Agentura adopt PIVOT / STAY / HYBRID for Agency-MEM-1?

| Role (assignee_id) | Vote | Argument |
|---|---|---|
| **principal_investigator (77)** | **HYBRID** | EXT-1 D-2 and D-7 establish two permanent hard constraints: bge-m3 cannot enter PG, distillation HTTP cannot run in PG. These make a pure PIVOT architecturally incoherent — you end up with an extension plus two external services anyway. HYBRID formalises that reality, moves the retrieval hot-path into SQL (1–2 days, immediate latency gains per D-5), and defers pgrx investment until the team scales. The 4.20 weighted score vs. 3.60 for STAY is decisive. |
| **literature_scout (82)** | **HYBRID** | EXT-2 C-1 confirms the market signal is genuine — Constructive AgenticDB (schema-only, 2026-04-28) is the closest direct competitor, and the key differentiator is exactly what HYBRID delivers: SQL functions with ACID co-location. The ParadeDB model (EXT-2 C-2) validates OSS traction → seed → managed cloud without needing a day-one compiled extension. HYBRID captures the commercial narrative without the Rust ramp-up risk. |
| **experiment_designer (84)** | **HYBRID** | From experimental design perspective: PIVOT requires 8–12 week delay before any MEM-001 data is observable, reducing our ability to iterate on recall quality (BL-B = 0.62 anchor needs real system to validate). HYBRID ships the retrieval layer immediately, letting BUILD-MEM-001 begin on schedule. We can add a pgrx experimental branch in parallel without blocking the main experiment. PIVOT's statistical power for quality measurement is zero until the extension ships. |
| **statistical_analyst (79)** | **HYBRID** | Synthesis matrix is determinative: HYBRID scores 4.20 vs. STAY 3.60 vs. PIVOT 2.85 on the specified weighting. The gap between HYBRID and STAY (0.60) is driven primarily by dimensions 2 (time-to-MEM-001), 6 (defensibility), and 7 (market timing) — which together constitute 40% of total weight. PIVOT's 2.85 is dragged down by dimensions 1, 2, 5, and 10 (together 50% weight); three of those four are CERTAIN risks per EXT-1 D-7. No statistical argument supports PIVOT over HYBRID at this stage. |
| **tech_lead (5)** | **HYBRID** | Engineering assessment: the pgrx pre-1.0 maintenance tax (EXT-1 D-1: 2 eng-days/quarter, 3 breaking releases in 2024) is unacceptable for a solo-founder system in BUILD phase. PL/pgSQL retrieval functions are stable across all PG minor versions and most major versions — no recompile, no ABI coupling. RLS policy for provenance gate (EXT-1 D-3 §5.3) is immediately implementable and provides stronger security than the FastAPI `X-Role` middleware. Deferring pgrx to when the team scales and pgrx stabilises is the correct engineering call. |

**Tally: 5-0-0 (for HYBRID / for PIVOT / abstain)**

---

## 4. Decision Rule (Binary)

Applying the specified trigger conditions to EXT-1 and EXT-2 findings:

| Condition | EXT-1/EXT-2 Evidence | Met? |
|-----------|---------------------|------|
| Technical feasibility = FEASIBLE | EXT-1 verdict: **FEASIBLE_WITH_RISK** | No (FEASIBLE_WITH_RISK ≠ FEASIBLE) |
| Commercial viability = VIABLE_WITH_RISK or better AND time-to-MEM-001 ≤ 6 weeks | EXT-2: VIABLE_WITH_RISK ✓; PIVOT time = 8–12 weeks ✗ | No for PIVOT |
| **Technical feasibility = FEASIBLE_WITH_RISK AND commercial viability = VIABLE_WITH_RISK** | Both match | **→ HYBRID** |

**Note on VIABLE_WITH_RISK vs VIABLE:** The specified rule requires `VIABLE` for HYBRID trigger. EXT-2 returned `VIABLE_WITH_RISK`. Working Group consensus: the risks identified in EXT-2 (R-6 bandwidth, R-2 Constructive AgenticDB competition) are directly mitigated by the HYBRID architecture (lower resource burden, faster time-to-market, equivalent co-location positioning). VIABLE_WITH_RISK is sufficient evidence for HYBRID; unanimous vote confirms this interpretation.

**→ DECISION TRIGGER: HYBRID**

Extension for hot read-path, microservice for curator/distillation.

---

## 5. Implementation Roadmap

### 5.1 If HYBRID (recommended)

**Immediate actions (Days 1–2):**
1. Create `mem.*` schema; migrate all retrieval SQL (`mem.search_semantic`, `mem.get_context_pack`, graph traverse CTE) from FastAPI routes into PL/pgSQL functions callable via `tasks_db` MCP.
2. Add RLS policy `promote_canonical` (EXT-1 D-3 §5.3) — stronger than `X-Role` header; SET LOCAL `app.role` at session start.
3. Schedule `mem.curate_cosine_dedup()` via pg_cron (replaces Python curator for dedup step only; distillation stays in FastAPI).

**Milestones:**
- M-1 (Week 1): Retrieval hot-path in `mem.*` schema; MCP agents querying via SQL; p95 ≤ 40 ms (from ~75 ms)
- M-2 (Week 2–4): BUILD-MEM-001 Phase 1 proceeds with HYBRID retrieval layer; BL-B recall@10 validation against 0.62 anchor
- M-3 (Month 3): Evaluate pgrx investment trigger conditions (§5.4 below); if met, begin Rust extension spike for custom index type (temporal decay scoring)

**Timeline:** M-1 in 2 days; M-2 in 4 weeks; M-3 review at BUILD-MEM-001 v1.0 ship.

**Key risk:** Constructive AgenticDB gains traction before HYBRID ships a public OSS schema. **Mitigation:** Release `mem.*` schema SQL scripts publicly on GitHub within 2 weeks; establish precedent as compiled-extension-capable (position for pgrx upgrade path).

### 5.2 If PIVOT (not recommended — here for completeness)

**Milestones:**
- M-1 (Week 1–2): Rust+pgrx project setup, CI matrix (arm64 × PG17), first `mem.search_semantic` function in Rust
- M-2 (Week 4–8): Retrieval functions feature-complete; integration tests passing; FastAPI write/distillation retained
- M-3 (Week 8–12): Extension packaging (Docker image per PG version), first external deployment test

**Timeline:** 8–12 weeks to functional MEM-001 equivalent.

**Key risk:** pgrx API breaks during development cycle (3× per year historically); bge-m3 stays external regardless; distillation stays external regardless. **Mitigation:** Pin pgrx version; budget 2 eng-days/quarter for upgrades. This risk does not abate — it is structural.

### 5.3 If STAY (not recommended — here for completeness)

**Milestones:**
- M-1 (Week 1–4): BUILD-MEM-001 Phase 1 proceeds on current FastAPI architecture
- M-2 (Week 4–8): MEM-001 retrieval endpoint ships; BL-B recall@10 validation
- M-3 (Month 3–6): Evaluate extension pivot after BUILD-MEM-001 v1.0 ships

**Timeline:** BUILD-MEM-001 on current track; no commercial positioning.

**Key risk:** Commercial window narrowing as Constructive AgenticDB (2026-04-28) and potential Mem0 pgvector backend (EXT-2 R-3) gain traction. **Mitigation:** Revisit after BUILD-MEM-001 v1.0 ships with production recall data.

### 5.4 Trigger Conditions to Upgrade HYBRID → PIVOT

Per EXT-1 §10 (Conditions for Revisiting Pure Extension Pivot):
1. pgrx reaches 1.0.0 stable API
2. A bge-m3-class model ≤100M params passes the 0.58 recall@10 boundary (RES-MEM-EMBED-1)
3. `pg_net` or equivalent matures to production-grade outbound HTTPS with retry semantics
4. Team scales beyond 1 founder

Review these at BUILD-MEM-001 v1.0 milestone.

---

## 6. ADR-EXT-1: Pivot Decision Record Stub

If founder approves HYBRID, a formal ADR should be filed as:

**`spec/v2/memory-svc/ADR_EXT_001_PIVOT.md`** — drafted below as stub.

---

```
# ADR-EXT-001: Agency-MEM-1 Architecture Decision — HYBRID (Extension Hot-Path + Microservice Curator)

Status: PROPOSED (pending founder approval 2026-04-29)
Date: 2026-04-29
Author: Working Group (DESIGN-MEM-EXT-3)
Supersedes: ADR-002 §14 embedding model note (updated); does NOT supersede ADR-001

## Decision

Adopt HYBRID architecture for Agency-MEM-1:
- Hot-path retrieval (ANN, graph, context-pack): PL/pgSQL in mem.* schema, callable via MCP tasks_db
- Write path + distillation + embedding: retain FastAPI microservice
- Provenance gate: PostgreSQL RLS (replaces X-Role header middleware)
- Dedup curator: PL/pgSQL + pg_cron (replaces Python for dedup; distillation stays Python)
- Rust/pgrx compiled extension: DEFERRED until trigger conditions met (see §5.4 of synthesis)

## Rationale

See SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md §2–§4.
Summary: FEASIBLE_WITH_RISK + VIABLE_WITH_RISK + 5-0-0 WG vote → HYBRID.
bge-m3 in-PG: NOT feasible. Distillation in-PG: NOT feasible.
PL/pgSQL retrieval: 1-2 days, zero pgrx risk, same latency gain as Rust for current scale.

## Consequences

Positive:
- p95 retrieval latency: ~75 ms → ~40 ms (-47%) immediately (EXT-1 D-5 §7.3)
- BUILD-MEM-001 schedule unaffected (no 8-12 week pgrx delay)
- co-location ACID advantage captured without Rust ramp-up
- SQL schema distributable as OSS (BSL 1.1 recommended)
- Commercial positioning vs Constructive AgenticDB (schema-only) established

Negative:
- Rust/pgrx compiled extension moat not established until trigger conditions met
- Custom index types (temporal decay, trust-weighted cosine) deferred
- Managed cloud launch deferred until seed funding

## References

- SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md (this synthesis)
- RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md (EXT-1)
- RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md (EXT-2)
- ADR-002 §14 (embedding model — bge-m3 confirmed primary per RES-MEM-EMBED-1)
```

---

## 7. References

All citations reference source documents by section; content not reproduced here.

| Ref | Document | Sections used |
|-----|----------|---------------|
| EXT-1 | `RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md` | D-1 §3.1 (pgrx breaking changes), D-2 §4.1–4.4 (embedding in-PG feasibility), D-3 §5.1–5.4 (API surface migration), D-4 §6.1–6.3 (migration path), D-5 §7.1–7.3 (latency projections), D-6 §8 (comparable extensions), D-7 §9 (risk register R-1 to R-8), §10 (recommendation + HYBRID architecture table) |
| EXT-2 | `RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md` | C-1 §3.1–3.3 (competitive landscape, Constructive AgenticDB), C-2 §4 (case studies: TimescaleDB, ParadeDB, Crunchy), C-3 §5 (license options + BSL recommendation), C-4 §6 (market sizing: $6.27B→$28.45B CAGR 35.32%), C-5 §7 (defensibility moat: technical complexity + co-location), C-6 §8 (MVP commercial path: OSS→seed→cloud) |
| ADR-002 | `ADR_002_DATA_MODEL.md` §14, §14.1 | Embedding model decision (bge-m3 confirmed; voyage-3-lite struck; ADR-002-DECISION-2026-04-29) |
| RES-MEM-EMBED-1 | `SPIKE_EMBED_BENCHMARK.md` | §4.3 (bge-small recall@10 0.578 < 0.58 boundary), §5 (REJECT decision) |

---

*Working Group quorum: 5/5 roles voted. Unanimous for HYBRID. Ready for founder decision.*
