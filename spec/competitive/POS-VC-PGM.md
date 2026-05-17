# POS-VC-PGM: Venture-Consultant Fundability Assessment

**Doc:** spec/competitive/POS-VC-PGM.md  
**Date:** 2026-05-17  
**Author:** venture-consultant (WG-VC-260517)  
**Status:** RATIFIED  
**Classification:** INTERNAL — do not distribute to prospective investors without revision  
**Inputs:** POSITIONING.md, ROADMAP.md v2, SYNTHESIS_PGMNEMO_2026-05-17.md, CROSS_CUTTING_SYNTHESIS_2026-05-16.md, POS-CA/GROWTH/MENTOR/RS-PGM.md

---

## §1 — Investability Verdict (TODAY, May 2026)

**Verdict: Pre-seed possible with narrative revision. Seed is not fundable today. Series A is 18+ months away.**

Five signals drive this:

1. **1 production deployment = the founder's own orbit.** Agency is not an independent paying customer; it is a team in the founder's sphere using a tool they helped specify. Every VC hears "1 production user" and translates it to "zero market validation." The MENTOR document calls this charitably an "early adopter." A VC will not.

2. **Mom Test interviews not conducted.** DISCOVERY_PROTOCOL.md exists (Agency #6217, 2026-05-17) as a template — but the actual interviews have not happened. Fundability at pre-seed requires evidence of customer pain, not evidence of a plan to gather it. Seventeen structured interview questions in a file is not discovery.

3. **The Karpov critique narrows TAM irreversibly.** The tagline "The write-time gate for agent memory" implies the addressable universe is all agent memory. It is not. The gate requires a `commit_sha` or `artifact_hash` at write time. This works for RAG pipelines, customer support (ticket_id), medical records, legal case IDs, and software devtool agents. It structurally fails for pure conversational agents, proactive observation agents, and personal assistant chitchat — the three largest deployment categories in 2026 consumer AI. The real market is **citation-grounded agent memory**, a defined niche inside agent infrastructure. That niche may be the right bet; but it is not the claim being made publicly.

4. **Loses to BM25 on the benchmark that matters most.** recall@10 = 0.9334 vs BM25 = 0.982 on LongMemEval-S (disclosed honestly in POSITIONING.md, which is admirable). A VC technical advisor will ask why a team should install a Postgres extension instead of a 50-line `tsvector` query, and hear "we're fixing it in v0.5.0 (June 2026)." That answer defers conviction to a future milestone.

5. **No revenue. No ARR. No paying customers. Apache 2.0.** The OSS license is the right trust-building move for developer adoption. It is also a VC trap: the monetization playbook (SaaS, usage-based) requires a hosted product that explicitly contradicts the positioning ("No extra service"). Enterprise dual-license is the only credible path, and MENTOR analysis requires ≥10 enterprise contracts before it generates material ARR. Today there are zero contracts.

---

## §2 — VC Partner-Fit List

These three funds could theoretically write a pre-seed check if the founder closes the gaps in §5. Listed in priority order.

### 1. Amplify Partners — Mike Dauber (General Partner)

Amplify is a Menlo Park seed/early-stage fund focused on developer infrastructure and open-source tooling. Portfolio: ngrok, Temporal, Snyk ecosystem, Honeycomb. Dauber specifically evaluates OSS-first developer tools where the monetization path is enterprise feature gating or dual-license. Check size: $1–4M pre-seed. [amplifypartners.com]

**What they'd need before a term sheet:**
- ≥5 independent external adopters with documented usage (not Agency)
- Conversations with 2–3 adopters confirming provenance enforcement is a production requirement, not a nice-to-have
- A credible dual-license commercial tier: what does the paid version gate that the Apache core does not? (Compliance export, SIEM integration, multi-tenant provenance dashboard)
- A quantified answer to the Karpov TAM critique: what fraction of 2026 agent deployments are citation-grounded, and what is the realistic install base in 2027?

### 2. Unusual Ventures — John Vrionis (General Partner)

Vrionis backed CockroachDB at NEA before co-founding Unusual; he understands database primitives as infrastructure primitives. Unusual's model: hands-on pre-seed into developer-led enterprise plays in databases, security, and observability. They do not lead seed rounds without direct access to 3+ reference customers they can call independently. Check size: $1–3M pre-seed. [unusual.vc]

**What they'd need before a term sheet:**
- Benchmark card published and reproducible (Rec #7, due 2026-07-15) — Vrionis will assign an engineer to replicate it; the card must survive that test
- Provenance gate framed as a compliance story (SOC 2, HIPAA audit trails) — Unusual's enterprise portfolio buys on compliance requirements, not performance benchmarks
- At least one conversation with a buyer at a regulated-industry company (healthcare, financial services, legal) who says "we'd pay for audit-grade memory provenance"
- ARR > $0; even a single $500/month contract from a non-Agency customer changes the fundability narrative

### 3. Madrona Venture Group — Matt McIlwain (Managing Director)

Madrona (Seattle) has backed AI infrastructure from early: Turi (acquired by Apple), ML tooling throughout 2023–2025. McIlwain has written publicly on "intelligence layer" infrastructure. Madrona writes $2–8M seed checks for technical founders with strong OSS community signals in the Pacific Northwest AI/ML ecosystem. The Postgres/pgvector angle maps to their portfolio composition. [madrona.com]

**What they'd need before a term sheet:**
- GitHub repository public with ≥500 stars — Madrona checks star velocity as a community signal
- ICSE-SEIP paper accepted or conditionally accepted — academic credibility converts to "this is a real technical contribution" in Madrona's diligence model
- v0.5.0 shipped and BM25 gap closed; recall quality parity is table stakes for Madrona's technical advisor review
- A concrete answer on the TAM critique: Madrona will model market size independently; the founder must have a bottom-up number before the meeting, or the associate's memo dies before the partner sees it

---

## §3 — Top-5 Questions a VC Will Ask

### Q1: "What's your TAM? How much of the agent memory market can you actually address?"

**pgmnemo's honest answer today:** "The agent memory infrastructure market is large — Mem0 is processing 186M API calls/month at 30% MoM growth. pgmnemo addresses the subset of agents that ingest from citable sources: RAG systems, customer support, healthcare, legal, and software development agents. We believe that's 20–30% of enterprise agent deployments today and growing as regulated industries adopt agents."

**What the VC hears:** The Karpov constraint ("citation-grounded only") is a structural exclusion that halves the obvious TAM. The 20–30% estimate is not backed by customer discovery data — it's an assertion. The Mem0 proxy is a competitor's metric, not a bottom-up ICP count.

**Rating: WEAK.** A VC will triangulate: "what fraction of agents being built today actually use artifact-backed memory writes?" The honest internal answer, pre-discovery, is "we don't know." That is the single most damaging sentence in a VC pitch.

---

### Q2: "Why won't AWS or Anthropic build this into their stack and make you irrelevant?"

**pgmnemo's honest answer today:** "AWS has already solved the memory problem by defaulting to Mem0 in the Agent SDK — they're not building their own. Anthropic is a model company; they ship MCP as an open standard and let the ecosystem build tooling on top. Neither will become a Postgres RLS vendor. The provenance gate requires deep database integration — it's closer to 'pgvector' territory than 'LangChain plugin' territory, and neither AWS nor Anthropic is in that business."

**What the VC hears:** The AWS Mem0 exclusivity is precisely the meta-distribution risk identified by the WG. The 3-day research spike to determine whether the AWS SDK memory provider interface is pluggable (due 2026-05-30) has not yet completed. The "Anthropic is not a DB vendor" argument is structurally correct and durable.

**Rating: OK.** The Anthropic half of the answer is strong. The AWS half is "we're researching it" — which is an honest answer, not a confident one.

---

### Q3: "You have one customer and it's yourself. Why should I believe there's product-market fit?"

**pgmnemo's honest answer today:** "Agency is an external team, not the founder directly. They've shipped production requirements against pgmnemo (AGENCY_REQUIREMENTS_FOR_PGMNEMO.md) and deployed it at production scale (recall@10 = 0.5745 on 1,060 production memory items). We're at the PMF discovery stage — DISCOVERY_PROTOCOL.md is written and interviews are beginning."

**What the VC hears:** Agency is a captive user in the founder's orbit. The requirements document means Agency needed pgmnemo to meet specific criteria before acceptance — that's a dependency relationship, not independent PMF. recall@10 = 0.5745 on a production corpus is low; any technical advisor will flag it. "Interviews are beginning" means they haven't happened.

**Rating: NO ANSWER.** There is no honest answer to this question that is also fundable. The gap must be closed before fundraising starts, not during it.

---

### Q4: "Apache 2.0. How do you make money?"

**pgmnemo's honest answer today:** "Enterprise dual-license: an audit-mode commercial tier that exports provenance logs to external SIEM systems and provides a multi-tenant provenance dashboard — features that compliance buyers need and that have no OSS equivalent. The core stays Apache 2.0. This requires ≥10 enterprise contracts to generate material ARR, which is gated on ≥3 external adopters with case studies (v1.0 criteria, Q4 2026)."

**What the VC hears:** "We will have a monetization plan in 6+ months." The MENTOR explicitly ruled out SaaS before v1.0. Commercial support doesn't work at 1 user. The compliance feature gating thesis is directionally correct — it's how Elastic, Timescale, and Grafana monetize — but both had 10,000+ OSS users before enterprise tiers generated meaningful ARR. pgmnemo has zero external OSS users today.

**Rating: WEAK.** The monetization thesis is coherent and not wrong. It is 12–18 months and 10 enterprise contracts away from being executable. A VC is being asked to bet on the execution, not the thesis.

---

### Q5: "Mem0 adds provenance metadata to writes tomorrow. What's your moat?"

**pgmnemo's honest answer today:** "Mem0's 'provenance' is `metadata=` on `add()` — a post-hoc log, not a pre-write veto. To replicate the pgmnemo moat, Mem0 would need to change their SaaS architecture to enforce write rejection at the storage layer before committing — that's redesigning a system processing 186M API calls/month. The RLS-enforced gate is evaluated inside the Postgres executor; it's not a feature a cloud API can copy without rebuilding their backend from the data layer up. We estimate 12–18 months minimum for a well-funded competitor to replicate this if they start now."

**What the VC hears:** This is the strongest answer in the deck. The architectural moat is real (confirmed unanimously by WG-STRAT-260517 §C1), falsifiable (POSITIONING.md publishes the exact conditions under which the claim is false), and requires a fundamental architectural rewrite to replicate — not a feature sprint.

**Rating: STRONG.** This is the one answer that keeps a VC in the room.

---

## §4 — Exit Scenarios at 3-Year Horizon (2029)

### (a) Acquisition — Probability: 55%

**Who buys and at what price:**

| Acquirer | Strategic rationale | Likely valuation range | Probability |
|---|---|---|---|
| **Supabase** | pgmnemo is pure SQL + pgvector; maps directly to Supabase's Postgres-as-a-platform thesis. They'd ship it as `supabase.extensions.pgmnemo`. Provenance gate differentiates Supabase enterprise vs commodity Postgres. | $8–25M (acqui-hire to tuck-in) | 25% |
| **Neon** | Neon is Postgres serverless; actively building toward agent and LLM use cases. pgmnemo's zero-LLM-per-write cost maps to Neon's serverless compute model. | $10–30M | 15% |
| **EDB (EnterpriseDB)** | EDB acquires Postgres extensions with enterprise compliance value (historical pattern). Provenance audit trail = compliance story = EDB's exact enterprise ICP. | $5–15M | 10% |
| **AI infra platform (Cohere, Mistral, or similar)** | Acqui-hire for Postgres + agent memory primitives team; provenance gate as a model-safety feature for enterprise deployments. Speculative. | $15–40M | 5% |

**Conditions for acquisition:** ≥3 external case studies published, ICSE-SEIP paper accepted, v1.0 API freeze shipped. Without these, any acquisition is a talent buy at $2–5M.

### (b) IPO — Probability: <2%

Not realistic at a 3-year horizon. IPO requires $100M+ ARR with a visible path to $500M+. pgmnemo's OSS-first model means ARR growth is slow (enterprise dual-license takes 2–3 years from first contract to meaningful revenue cohort). Even Supabase at $100M+ ARR is still private in 2026. A Postgres extension sub-project does not have a standalone IPO path in this time horizon.

### (c) Lifestyle Business / OSS Reputation Play — Probability: 35%

This is the second-most likely outcome and should be treated as a legitimate strategy, not a consolation prize. ICSE-SEIP paper + speaking engagements + developer community reputation generates $200–500K/year equivalent in consulting and career optionality for a small founding team. If acquisition interest materializes, a $10–15M exit on a bootstrapped OSS project is a strong personal outcome.

**Recommended honest base case: Acquisition by Supabase or Neon at $10–25M in 2028–2029, conditional on v1.0 shipped + ≥3 external adopters + ICSE-SEIP acceptance.** Not a venture-scale return; a sound technical founder outcome.

---

## §5 — Fundraising Readiness Gap-List

In priority order. Items 1–3 are blocking (no VC meeting should happen before these close). Items 4–7 are necessary-but-not-sufficient for a seed close.

### BLOCKING — close before any VC call

**1. ≥5 independent paying customers — not Agency, not the founder's ecosystem.**  
"Independent" means: a company that discovered pgmnemo via OSS, evaluated it against alternatives without the founder in the room, and chose it. $100/month counts. The metric is independence of the buying decision, not ARR size. Timeline: cannot be manufactured quickly — requires executing Recs #3, #5, #7 from WG synthesis to drive organic adoption, then a 3–6 month adoption cycle.

**2. ≥10 Mom Test interviews conducted and documented, ≥3 outside the founder's network.**  
DISCOVERY_PROTOCOL.md is a tool, not a result. A VC asks "what did your customers say about the provenance-gate pain?" — not "do you have a discovery framework?" The interviews must happen before any pitch. The key question to answer: does the citation-grounded ICP (RAG, customer support, medical, legal) feel the write-time provenance problem as a burning issue or a nice-to-have? If nice-to-have, the TAM story does not hold.

**3. Karpov TAM revision — publish a bottom-up market size for citation-grounded agent memory.**  
The current narrative implies "agent memory = big and growing." VCs who do diligence discover the Karpov constraint (commit_sha / artifact_hash required at write time). The founder must get ahead of this: how many agents in production today write from citable sources? What is the realistic total install base in 2027 if RAG adoption continues at current pace? A narrow honest TAM is fundable. An overclaimed TAM that unravels in diligence destroys the relationship with that investor permanently.

### NECESSARY — required by seed close

**4. BM25 gap closed and verified (v0.5.0, June 2026).**  
recall@10 = 0.9334 losing to BM25 = 0.982 is the first technical question every diligence advisor asks. v0.5.0 must ship the fix, with new numbers published via the benchmark card before any serious VC meeting. Target: recall@10 ≥ 0.985 on LongMemEval-S at p < 0.05.

**5. Benchmark card v0 published and reproducible (Rec #7, due 2026-07-15).**  
The 8-cell card per POS-RS-PGM spec — pre-registered protocol, CI-validated, with C4 (the cell pgmnemo loses) included. This converts "interesting project" to "trusted technical artifact" and is the cheapest credibility upgrade available. Costs 2 weeks of execution; returns a diligence-passing technical document.

**6. Dual-license commercial tier defined and priced — even if not yet sold.**  
A VC will ask "what does the paid tier include and what does it cost?" before writing a check, even at pre-seed. Pick one feature set (audit-mode SIEM export, multi-tenant provenance dashboard, SLA-backed commercial support) and put a number on it ($1,000/month, $50K/year). "We'll figure out monetization at v1.0" fails the test.

**7. GitHub public repository with ≥500 stars.**  
Not a proxy for PMF, but a threshold signal every VC associate checks before scheduling the first meeting. Below 500 stars on a 2026 developer tool, the memo written by the associate contains "no community traction" and the GP skips the call.

---

## §6 — The Lifestyle vs Venture-Scale Question

**Honest answer: pgmnemo is not a venture-scale business today. There is a realistic path to becoming one, but executing it requires closing gaps that have not yet started.**

**The case against the venture-scale frame:**

- The addressable market is narrower than the tagline. After the Karpov constraint (citation-grounded agents only), the reachable market in 2026 is a specific niche inside AI infrastructure. "All agent memory" is what a VC underwrites when they hear the current tagline. Discovery will reveal the true number — and it may be too small for a VC return profile (10x in 7 years on a $2–5M check requires $20–50M exit minimum; that requires ≥$5M ARR at SaaS multiples, which requires ≥100 enterprise contracts at $50K/year).

- Apache 2.0 without a monetization playbook is a lifestyle business by default. Elastic and Timescale had 10,000+ users before enterprise tiers generated material ARR. pgmnemo has one user. The math does not compress to a 5-year venture return on any reasonable adoption curve.

- The only structural moat is unvalidated as a buying criterion. No competitor has the provenance gate — confirmed by all four WG positions unanimously. But "nobody has it" is not the same as "customers need it and will pay for it." The Mom Test interviews that would confirm the commercial value of the moat have not been conducted. Until they are, the moat is a technical fact with an unconfirmed price point.

**The case that it could become venture-scale:**

- The Karpov ICP (citation-grounded agents) may be 25–35% of enterprise agent deployments by 2028, especially if regulated industries (healthcare, financial services, legal) adopt agents at scale. That's a material market.
- v0.5.0 closing the BM25 gap and the benchmark card driving OSS adoption could produce a GitHub star velocity signal that attracts enterprise evaluation.
- ICSE-SEIP acceptance positions pgmnemo as the academic standard for agent memory provenance — a citation magnet that converts technical credibility into enterprise pipeline.
- A single $50K/year compliance contract changes the entire narrative from "OSS hobby project" to "provenance infrastructure with paying customers."

**Recommendation for the founder:** Do not approach VCs until the three BLOCKING gaps in §5 are closed. The current state produces polite rejections framed as "we're not the right fit for this stage." Instead, treat the next 6 months as a PMF validation sprint: ship v0.5.0, run 10 Mom Test interviews, publish the benchmark card, push for ≥5 independent adopters. If that sprint succeeds, Amplify or Unusual at pre-seed is fundable in Q4 2026.

If the interviews reveal the citation-grounded ICP is smaller than the roadmap assumes, the lifestyle / acquisition path is the honest outcome. At $10–25M acquisition by Supabase or Neon, with zero VC dilution, it is not a bad one. Name it as such rather than manufacturing a venture narrative that investors will see through.

---

*Commit: 9aa8f85*
