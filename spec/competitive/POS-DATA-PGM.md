# POS-DATA-PGM: Validation Inventory + Fundraising Data Gap

**Doc:** spec/competitive/POS-DATA-PGM.md  
**Date:** 2026-05-17  
**Task:** PGMNEMO-WG-VC-260517  
**Role:** PI — what data we have vs. what VCs/buyers need  
**Status:** INTERNAL — do not publish externally  
**Classification:** Pre-seed/seed fundraising readiness assessment

---

## §1 What We Measured Today (Validation Inventory)

### 1.1 Benchmark corpus inventory

| Asset | Value | N | 95% CI | Notes |
|---|---|---|---|---|
| LoCoMo session recall@10 | **0.8409** | 1,986 questions × 10 conv | ±1.4pp (Wilson) | Session-pooled; 22× smaller search space than ACL 2024 Table 3 |
| LoCoMo temporal-category recall@10 | **0.645** | ~340 | ±2.6pp | Weakest category; H-06 fix targeted v0.5.0 |
| LongMemEval-S recall@10 | **0.9334** | full session | ±0.8pp | bge-m3 substitution (Stella V5 incompatible); **LOSES to BM25 baseline (0.982) by 4.9pp** |
| LongMemEval-S vs BM25 gap | **−0.049** | same | — | Mandatory negative cell; gap is the current customer-acquisition blocker |
| Production corpus recall@10 | **0.5745** | 1,060 | ±3.0pp | Agency internal; leave-one-out self-retrieval; real-world agent memory |
| Production corpus MRR | TBD | 1,060 | — | Not yet computed for this corpus |

**Bench protocol status:** Pre-registered (`docs/BENCHMARK_PROTOCOL.md`). Gate mechanism live in CI since v0.3.1. Significance test script (`scripts/significance_test_extended.py`) blocks tag on regression.

### 1.2 What is absent

| Category | Status | Evidence |
|---|---|---|
| Independent third-party benchmark | **ZERO** | All bench runs are first-party (pgmnemo team or Agency internal) |
| Customer interviews (Mom Test) | **ZERO executed** | DISCOVERY_PROTOCOL.md designed (Agency #6217, 2026-05-17); instrument ready; zero calls made |
| External paying customers | **ZERO** | 1 production user = Agency itself; internal corpus |
| Compliance-segment evidence | **ZERO** | No healthcare, legal, or financial-services pilot; no compliance buyer interviewed |
| Security audit of provenance gate | **ZERO** | Gate claim is architectural; no CVE program, no external audit confirming bypass-impossibility |
| GitHub community signal | **ZERO documented** | POSITIONING.md competitor matrix cites "1 production deployment (early adopter)" with no star count published |

### 1.3 The Karpov gap: segment mismatch in current positioning

POSITIONING.md tagline is "The write-time gate for **agent memory**" — framing is universal, but applicability is narrow.

| Agent type | Has artifact_hash / commit_sha source? | pgmnemo gate applicable? |
|---|---|---|
| RAG / document-grounded agent | ✅ Yes — document ID, chunk hash | ✅ YES |
| Customer support (ticket-based) | ✅ Yes — ticket_id | ✅ YES |
| Medical / legal (record-based) | ✅ Yes — patient_record_id, case_id | ✅ YES |
| Software dev agent (code-grounded) | ✅ Yes — commit_sha natively | ✅ YES |
| Pure conversational ("user said X") | ❌ No stable source ID | ❌ FAILS — gate cannot enforce what does not exist |
| Proactive observation / ambient sensor | ❌ No document source | ❌ FAILS |
| Personal assistant chitchat | ❌ No provenance anchor | ❌ FAILS |

**Implication for fundraising:** "Agent memory" is the pitch; "citation-grounded agent memory" is the honest scope. VCs will probe the TAM boundary — currently no data quantifying the citation-grounded segment size. We have validated the gate mechanism; we have NOT validated that there are ≥N buyers in the citation-grounded segment who will pay.

---

## §2 What Seed-Stage VC Asks For

*Based on public reporting on comparable developer-infrastructure OSS seed rounds 2017–2024: TimescaleDB ($12.4M seed, 2017), Hasura ($1.5M seed + $9.9M Series A, 2018–2019), Materialize ($10M seed, 2020), PostHog ($3M seed, 2020). Sources: Crunchbase, TechCrunch, company blog posts.*

### 2.1 Seed-stage gap table

| Metric | Seed median (infra OSS tools) | pgmnemo current | Gap | GO/NO-GO |
|---|---|---|---|---|
| GitHub stars at first raise | 500–3,000 | Not publicly reported | Unknown — must measure | ⚠ UNKNOWN |
| PGXN / package downloads (30d) | — (not applicable; see note) | Not tracked | Not tracked | ⚠ NO DATA |
| Independent paying customers | 1–5 | **0** | −1 minimum | 🔴 NO-GO |
| Documented design partners (signed LOI or active pilot) | 2–5 | **0** | −2 minimum | 🔴 NO-GO |
| Customer discovery interviews (Mom Test) | 10–20 | **0** | −10 minimum | 🔴 NO-GO |
| ARR at seed | Pre-revenue to $100K | **$0** | Neutral (pre-revenue is acceptable; $0 with 0 pilots is not) | 🟡 BORDERLINE |
| Independent benchmark / third-party production reference | ≥1 | **0** | −1 | 🔴 NO-GO |
| Provenance of core claim (non-trivially reproducible moat) | Demonstrated or patent-pending | Architecturally solid; no external confirmation | External audit absent | 🟡 BORDERLINE |

**TimescaleDB seed context (most comparable):** Raised $12.4M with ~2,000 GitHub stars, strong production user testimonials from IoT/research community, and named enterprise design partners before close. pgmnemo is structurally earlier than TimescaleDB pre-seed.

**Hasura seed context:** $1.5M with demonstrable GitHub traction (rapid post-launch growth), multiple GraphQL API design partners actively building on it. Key signal: founder had public code evidence of adoption, not just a private pilot.

**PostHog ($3M seed, 2020):** Self-hosted analytics on Postgres. Had 100+ active installs from HN launch before raising. Customer interviews documented publicly in their blog.

### 2.2 VC likely verdict on pgmnemo TODAY (May 2026)

**Pre-seed (≤$1.5M, angels/pre-seed funds):** Potentially raiseable IF founders have strong personal networks and the architectural moat demo is compelling. The provenance gate is genuinely novel — a live demo rejecting a malformed `ingest()` call inside a Postgres transaction is tangible. Weak point: "1 production user = us" will immediately be noted.

**Seed ($2–5M, institutional):** **NOT fundable today.** Zero independent customers, zero interviews, zero third-party validation. Institutional seed funds pattern-match on: problem validation (interviews), solution traction (external deployments), and team. Two of three are absent.

**Series A in 6 months (by 2026-11):** Fundable IF the 90-day plan in §4 delivers ≥3 design partners, ≥5 customer interviews, and a published benchmark card. Series A infra tools typically require $50–500K ARR or equivalent pipeline signal. Without compliance pilots generating real contract intent, $0 ARR + design partners is a thin signal.

**Honest framing — lifestyle vs. venture scale:** pgmnemo as a pure OSS extension with 0 paying customers is a lifestyle/reputation play today. Venture scale requires: (a) a segment with willingness to pay (compliance buyers are the best bet — healthcare/legal/fintech agents need provenance audit trails and will pay for them), AND (b) demonstrated distribution to that segment. Neither is validated.

---

## §3 Validation Experiments (Priority Order)

### P0 — DISCOVERY_PROTOCOL.md Interviews (due 2026-06-15)

**What:** Execute 5–8 Mom Test interviews using the instrument already designed in Agency #6217 (2026-05-17). The instrument exists; zero calls have been made.

**Target respondents:** AI engineers or platform leads at companies running citation-grounded agents (customer support, RAG pipelines, medical/legal). Not Agency. Not pgmnemo team.

**What to learn:**
1. Do they have a hallucination / memory poisoning problem in production?
2. Do they currently gate memory writes at any layer?
3. Would they adopt a Postgres extension for write-time enforcement, or does their stack prohibit it?
4. What would they pay for compliance-grade provenance export?

**Success criterion:** ≥3 of 8 interviews produce a "problem is real and painful" signal (unprompted mention of stale memory / hallucination in agent state as a production incident). Negative result (nobody recognizes the problem) is a pivot signal — see §5.

**Owner:** PI / growth_lead. Cost: ~20 hours of conversation time. No engineering required.

### P1 — 2–3 Compliance Design-Partner Pilots (due 2026-08-15)

**What:** Recruit 2–3 companies in healthcare, legal, or fintech that run AI agents and need a provenance audit trail. Offer white-glove setup (1 engineer for 2 days), ask for a signed pilot LOI in return.

**Target segment:** Healthcare AI platforms (clinical decision support agents), legal AI (contract review agents), fintech (customer-facing advisory agents under FINRA/MiFID). All have regulatory requirements for agent memory auditability.

**Evidence produced:** Production corpus N>500, third-party recall@10 measurement, compliance buyer intent signal (LOI or expansion conversation), case study narrative.

**Success criterion:** ≥1 pilot produces signed LOI or verbal commitment to expand. Failure criterion: all pilots stall at "interesting but no budget" — see §5.

### P2 — Independent Third-Party Benchmark / Security Audit (due 2026-09-01)

**What:** Commission either (a) an independent recall benchmark run by a third party on their private corpus, OR (b) a security audit of the provenance gate RLS enforcement.

**Why:** The provenance gate is the sole structural moat (SYNTHESIS §2 C1). "Architecturally impossible to bypass" is currently a self-reported claim. An external security audit confirming the gate (or identifying bypass vectors) is both defensive (no CVE surprise) and offensive (marketing: "independently audited write-time enforcement").

**Lowest-cost path:** Academic collaboration — a university research group running a standard recall eval counts as third-party. Cost: $0–$5K.

**Success criterion:** ≥1 result produced by an entity not affiliated with pgmnemo or Agency. Published in benchmark card v0.

### P3 — Public Benchmark Card v0 (due 2026-07-15, per SYNTHESIS §4 Rec #7)

**What:** Execute the POS-RS-PGM spec (8-cell design, pre-registered protocol, mandatory negative cells C4 and C5). Publish before v0.6.0 tag.

**Status:** Fully designed (POS-RS-PGM.md). Data for C1–C5 already exists. C8 (write-rejection rate) requires one 1,000-write audit run.

**Success criterion:** Card published at stable GitHub URL, all 8 cells populated, C4 negative cell visible, pre-registration commit predating results directories.

**Owner:** research_supervisor (per SYNTHESIS §4 Rec #7).

---

## §4 Data-Collection Plan: Next 90 Days

*Target: investable evidence by 2026-08-15 (v0.6.0 ship date).*

### Month 1 (May 17 – June 15): Problem Validation

| Action | Owner | Output | VC signal produced |
|---|---|---|---|
| Execute 5–8 DISCOVERY_PROTOCOL.md interviews | growth_lead / PI | Interview notes + synthesis doc | Problem validation (or pivot signal) |
| Instrument GitHub star tracking | growth_lead | Weekly star count logged | Community traction baseline |
| PGXN download tracking setup | chief_architect | Download dashboard | Distribution baseline |
| Draft compliance segment one-pager (healthcare/legal/fintech pain) | growth_lead | 1-page segment brief | ICP sharpening for pilots |

**Month 1 success gate:** ≥3 of 8 interviews confirm problem is real. If <3: pivot or kill signal (§5).

### Month 2 (June 15 – July 15): Design Partners + Benchmark Card

| Action | Owner | Output | VC signal produced |
|---|---|---|---|
| Recruit 2–3 compliance design partners using interview referrals | PI / growth_lead | ≥2 LOI or active pilots | External production users |
| Publish benchmark card v0 (POS-RS-PGM spec) | research_supervisor | Public card at stable URL | Third-party credibility + honest negative disclosure |
| v0.5.0 ships (2026-06-20) with bitemporality + H-06 | chief_architect | Recall regression gate passed | Technical progress signal |
| AWS Agent SDK research verdict (due 2026-05-30) | chief_architect | Build or kill decision | Distribution strategy clarity |

**Month 2 success gate:** ≥1 signed pilot LOI + benchmark card published.

### Month 3 (July 15 – August 15): Case Study + ARR Signal

| Action | Owner | Output | VC signal produced |
|---|---|---|---|
| v0.6.0 ships with framework adapters + first case study (ROADMAP gate: ≥1 external adopter) | chief_architect | Public case study | External production deployment #2+ |
| First pilot produces measurable outcome (recall data, compliance report, or testimonial) | PI + design partner | Case study data | Buyer intent evidence |
| Publish compliance one-pager (post-interview synthesis) | growth_lead | Segment brief + buyer ICP | Fundraise narrative |
| Commission security audit or academic benchmark run | PI | Audit report / third-party recall | Independent gate validation |
| ARR target: ≥$5K MRR from ≥1 paying pilot | PI | Contract or LOI | Revenue signal for Series A pipeline |

**Month 3 success gate:** ≥2 external production deployments + ≥1 published case study + benchmark card live.

### 90-day metric targets summary

| Metric | Today (2026-05-17) | Target (2026-08-15) | GO threshold |
|---|---|---|---|
| Independent paying customers | 0 | ≥1 (pilot or contract) | ≥1 |
| Design partner LOIs signed | 0 | ≥2 | ≥2 |
| Mom Test interviews executed | 0 | ≥8 | ≥5 |
| Published benchmark card | 0 | v0 published | Published |
| Third-party recall reference | 0 | ≥1 (academic or pilot) | ≥1 |
| GitHub stars (tracked) | unknown | baseline established | Tracked |
| Case studies published | 0 | ≥1 | ≥1 |

---

## §5 Falsification Gates: When to Pivot or Kill Venture-Scale Plan

### Gate F1 — Interview failure (due 2026-06-15)

**Trigger:** Fewer than 3 of 8 DISCOVERY_PROTOCOL.md interviews produce an unprompted confirmation that agent memory poisoning / stale facts in production is a real, painful problem.

**Interpretation:** The problem either does not exist outside Agency's specific use case, OR the citation-grounded segment is too narrow to support a standalone product.

**Required action:** Call a WG meeting within 7 days. Either (a) pivot positioning to compliance-as-a-service niche (narrow but potentially high-ACV) or (b) absorb pgmnemo as an Agency-internal tool with no external roadmap. Do NOT continue spending engineering cycles on v0.6.0 adoption tooling without this gate passing.

### Gate F2 — Pilot stall (due 2026-08-15)

**Trigger:** 0 of 2–3 compliance design-partner pilots produce a signed LOI, a renewal conversation, or a measurable production outcome after 60 days of active setup.

**Interpretation:** Either (a) compliance buyers have budget elsewhere, (b) the Postgres extension install model is too high-friction for their stack, or (c) the problem is not compliance-grounded — it is an Agency-specific architecture constraint.

**Required action:** Kill venture-scale plan. Continue as OSS reputation play (MENTOR §3 verdict: "Pure OSS reputation play now"). Redirect engineering to MAGMA paper submission (ICSE-SEIP track) + Agency G2 milestone. No further fundraise attempt without new customer signal.

### Gate F3 — Recall regression below production floor (ongoing)

**Trigger:** Any release candidate where Agency-corpus recall@10 < 0.55 (p_corr < 0.05).

**Interpretation:** Core product is regressing against the only production user. Architectural credibility collapses.

**Required action:** Block tag. Publish incident note within 48 hours. Notify Agency. No new marketing or investor conversations until recovered. (Existing protocol per POS-RS-PGM §5.1.)

### Gate F4 — Provenance gate bypass demonstrated (anytime)

**Trigger:** Any external security researcher, audit, or CVE demonstrates that `gate_strict=enforce` can be bypassed without SUPERUSER — i.e., the architectural claim is false.

**Interpretation:** The sole structural moat does not hold. The entire "bypass-proof" narrative collapses.

**Required action:** Retract provenance-gate claim immediately. Publish security advisory. No investor conversations until independent patch confirmation. If bypass is fundamental to the RLS architecture (not a one-line fix), kill the venture-scale plan — the moat claim is the only non-imitable differentiator. (Existing protocol per POS-RS-PGM §5.2.)

### Gate F5 — Benchmark card not published by 2026-08-15

**Trigger:** v0.6.0 ships without a published benchmark card v0 (per SYNTHESIS §4 Rec #7 due 2026-07-15 pre-tag).

**Interpretation:** The team is unable to execute on its own designed protocol. If we cannot publish a card we designed, no Series A investor will believe the production-readiness claims.

**Required action:** Freeze growth/positioning work until card ships. No new investor meetings.

---

## §6 Summary GO/NO-GO

| Dimension | Today verdict | Evidence |
|---|---|---|
| **Pre-seed raise (angels):** raiseable? | 🟡 BORDERLINE | Architectural moat demo is real; but 0 external users and 0 interviews make "problem validated" hard to say. Angel bet on team + moat only. |
| **Seed raise ($2–5M, institutional):** raiseable? | 🔴 NO-GO | Zero independent paying customers, zero design partners, zero interviews. Minimum: Gate F1 + Gate F2 must pass first. |
| **Series A in 6 months:** credible path? | 🟡 CONDITIONAL | Only if 90-day plan delivers ≥2 design partners + published benchmark card + ≥1 case study. Missing any of these = continue as OSS reputation play. |
| **Lifestyle vs. venture-scale:** honest framing today | **Lifestyle/reputation play** | 1 user = internal. Zero revenue. Zero interviews. Valid OSS project; not yet a venture-scale business. Karpov critique stands. |

---

*Commit: 9aa8f85*
