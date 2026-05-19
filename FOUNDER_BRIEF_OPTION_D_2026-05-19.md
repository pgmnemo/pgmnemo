# pgmnemo Launch Brief — Option D (Provenance Gate)
## For Founder Decision: Go/No-Go on Launch Positioning

**Prepared for:** Founder  
**Status:** Ready for founder review + sign-off  
**Date:** 2026-05-19 (today)  
**Attached:** GROWTH_STRATEGY_v2_OPTION_D_2026-05-19.md (full expansion)  

---

## One-Minute Summary

**What we're proposing:**

Launch pgmnemo with a **single, defensible differentiator:** provenance enforcement at the database constraint layer — the only architectural mechanism that makes agent hallucinations impossible without SUPERUSER bypass.

**Positioning tagline (sharp, memorable):**  
> **"Memory that can't hallucinate — because every write must cite its source."**

**ICP (narrow, defensible):**  
Citation-grounded agents in regulated domains: healthcare AI, legal eDiscovery, compliance automation, code agents.

**Why this works:**
1. **Honest** — we don't hide benchmarks (BM25 beats us on LongMemEval; we own that)
2. **Unique** — provenance enforcement at write-time is architecturally ours; Mem0, Zep, Constructive AgenticDB can't replicate it without a Postgres extension
3. **Regulatory-aligned** — as agents enter healthcare/legal, hallucination becomes a compliance problem; we're the only solution
4. **Founder-friendly** — single claim is easy to articulate; no temporal jargon or MAGMA paper citations
5. **Durable moat** — 18–24 months of defensibility before Constructive AgenticDB might add RLS policies

---

## Why NOT the other options we considered

| Option | Positioning | Why we rejected it |
|--------|-----------|-------------------|
| **A: MAGMA Implementation** | "Only production MAGMA impl" | MAGMA is research; we lose on LongMemEval benchmarks (0.933 vs BM25 0.982); chasing academic credibility when market wants practical tools |
| **B: Vector RAG in Postgres** | "Postgres-native Pinecone/Weaviate alternative" | pgvector exists; Constructive AgenticDB solves this; no moat, race to bottom |
| **C: Temporal Reasoning** | "Bitemporal agent memory" | Zep owns this; temporal is nice-to-have; impossible to pitch without jargon |
| **D: Provenance Gate** ✅ | "Write-time enforcement for regulated domains" | **✅ Defensible moat, honest positioning, regulatory-aligned, founder-friendly, durable** |

---

## Key Numbers (Fundamentals-Based)

**TAM (within provenance-enforcement segment):** ~$650M/yr  
- Healthcare AI: $200M (20% of $1B market)
- Legal AI: $150M (10% of $1.5B market)
- Compliance / GRC: $100M (5% of $2B market)
- Developer tools / code agents: $80M
- FinServ (KYC/AML): $120M

**Market timing:** Favorable (35% CAGR in agent memory; Constructive AgenticDB launched 2026-04-28; we have a ~18-month window before they might add RLS policies)

**Competition:** Mem0 dominates general agent memory (186M+ API calls/month); Zep has enterprise temporal graph; neither enforces write-time provenance. **We own the security/compliance segment.**

**Realistic first 90 days:** 500+ stars, 5+ external contributors, 2+ public adopters (healthcare + legal), assuming clean v0.5.0 launch and honest benchmarking.

---

## Founder Go/No-Go Checklist

**You need to review & approve:**

- [ ] **Positioning:** Do you agree that provenance-enforcement (write-time, architectural) is the *one* defensible differentiator pgmnemo has? (Not MAGMA, not vector retrieval, not temporal reasoning.)
- [ ] **Tagline:** Does "Memory that can't hallucinate — because every write must cite its source" land? (If not, what's your wording?)
- [ ] **ICP:** Is citation-grounded + regulated domains (healthcare, legal, compliance, code agents) the right first wedge? (Or should we start elsewhere?)
- [ ] **Honesty commitment:** Are you willing to launch saying "BM25 beats us on LongMemEval (0.982 vs 0.933)" in the first post? (Required for credibility.)
- [ ] **v0.5.0 blocker resolution:** Current TL report (2026-05-17) shows 3 hard blockers preventing v0.5.0 ship. **When will those be fixed?** (Launch depends on clean release.)
- [ ] **Licensing:** Apache 2.0 locked in for launch? (Legal_advocate confirmed this; just confirming with you.)
- [ ] **First adopter story:** Do we have 1 external adopter (confidential OK) willing to be a reference by T+30? (Significantly boosts credibility; not required, but helps.)

---

## Timeline (If go decision today)

| Gate | Timing | Owner | Status |
|------|--------|-------|--------|
| **Resolve v0.5.0 blockers** | ASAP (T-14 to T-7 before launch) | TL | Currently BLOCKED (see TL report) |
| **Founder signs off on positioning** | Today (2026-05-19) | Founder | ⏳ Waiting |
| **GitHub README refreshed for Option D** | T-7 | growth_lead | Ready |
| **HN post + Twitter threads drafted** | T-7 | growth_lead | Ready (in this doc) |
| **v0.5.0 ships** | T-7 | TL | Pending blocker fix |
| **Public launch (HN, dev.to, Twitter)** | T0 (date TBD by founder) | Founder + growth_lead | Ready |
| **First 100 stars (warm list seeding)** | T+1 to T+7 | Founder + growth_lead | Plan ready |
| **First external conversation (healthcare/legal)** | T+14 | Founder | Plan ready |

**Earliest launch date (realistic):** 2026-05-29 (if v0.5.0 blockers fixed by T-7 with no surprises)

---

## Growth Lead Commitment (What I own as growth_lead)

If you sign off on Option D:

1. **Refresh all launch collateral** — Show HN post, Twitter threads, dev.to, Product Hunt copy, rewritten for provenance-gate narrative (not MAGMA)
2. **COMPETITIVE_TRACKING.md** — start weekly updates tracking Constructive AgenticDB, Mem0, Zep moves
3. **Issue triage + community management** — first 2 weeks post-launch (daily); then weekly
4. **Blog post queue** — 4 draft posts ready (T+7: "Provenance under-appreciated", T+14: benchmark honesty, T+30: case study, T+60: thought leadership)
5. **Conference talk drafts** — PgConf NYC, FOSDEM PGDay abstracts due T+30
6. **Founder support** — all messaging, competitor talking points, warm-list outreach coordination

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| **v0.5.0 doesn't ship by T-7** | HIGH (3 blockers, 5 days) | CRITICAL — launch delayed | Resolve blockers NOW; if not possible, launch on v0.4 + roadmap highlight |
| **Constructive AgenticDB adds RLS policies before we gain traction** | MEDIUM (they launched 2026-04-28; moat window ~18 months) | MEDIUM — moat compressed | Speed to market matters; aim for 500+ stars by T+90 to establish community |
| **Healthcare/legal adopter says "no, still too risky"** | MEDIUM (regulation-averse) | MEDIUM — wedge validation delayed | Run 2–3 conversations by T+30; if all say no, pivot to code-agents (lower regulation) |
| **BM25 baseline narrative backfires ("so you lose?")**| LOW (if we frame it as roadmap) | MEDIUM — credibility hit | Lead with honesty: "BM25 wins on LongMemEval today; our v0.4 fixes it via hybrid. We measure what we're honest about." |
| **Benchmark claim audited by academic** | LOW (pgmnemo not academic) | LOW — explains our methodology clearly | COMPETITIVE_REALITY.md already documents all caveats; we're defensible |

---

## Decision Time

**Three options:**

**Option 1: APPROVE Option D — Launch with provenance-gate positioning (recommended)**  
- Gives pgmnemo a defensible, honest narrative
- Targets the right wedge (regulated domains)
- Launches with credibility (we own the honesty)
- Timeline: T-7 to ship (if blockers fixed)

**Option 2: DEFER to fix v0.5.0 + gather first adopter story first**  
- Delays launch to T+14–21 (more robust)
- Requires 1 public healthcare or legal adopter (boosts positioning)
- Higher confidence, lower risk of momentum loss
- Timeline: 3–4 weeks

**Option 3: PIVOT to different positioning (Option A/B/C)**  
- Revisit MAGMA, vector RAG, or temporal reasoning angles
- Requires new analysis + founder consensus
- Higher execution risk; unclear why we'd choose these over Option D

**Recommendation: OPTION 1 — Go with Option D today, assuming v0.5.0 blockers are resolved by T-7.**

---

## Your Decision Required

Please reply with:

1. **Positioning approval:** Do you approve the Option D provenance-gate positioning?
2. **Tagline:** Do you like "Memory that can't hallucinate — because every write must cite its source" or propose an alternative?
3. **Launch date decision:** Assuming v0.5.0 ships clean, what's your preferred T0 date? (Week of 2026-05-27? 2026-06-02?)
4. **Honesty commitment:** Are you willing to include BM25 benchmark context ("we lose to BM25 on LongMemEval; v0.4 fixes it") in launch post?
5. **Go/no-go:** Ready to proceed with Option D launch planning?

Once you confirm, growth_lead will execute the full content calendar + founder support plan.

---

**Questions? Review the full GROWTH_STRATEGY_v2_OPTION_D_2026-05-19.md for details.**
