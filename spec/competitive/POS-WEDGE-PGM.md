# POS-WEDGE-PGM: Narrowed ICP After Karpov Critique

**Doc:** spec/competitive/POS-WEDGE-PGM.md  
**Task:** PGMNEMO-WG-VC-260517  
**Date:** 2026-05-17  
**Author:** PO (post-Karpov critique)  
**Status:** RATIFIED — internal, do not publish externally  
**Inputs:** POSITIONING.md (2026-05-17), ROADMAP.md v2, SYNTHESIS_PGMNEMO_2026-05-17.md, CROSS_CUTTING_SYNTHESIS_2026-05-16.md, POS-CA/GROWTH/MENTOR/RS-PGM.md

---

## Context: What Karpov Said

The 2026-05-17 POSITIONING.md frames pgmnemo as "The write-time gate for agent memory" — a universal claim. Karpov's critique: the gate mechanism (`commit_sha` OR `artifact_hash` required per write) presupposes the agent has a citable source. Agents that don't have citable sources cannot use pgmnemo at all. This is not a positioning edge case — it splits the entire agent memory market in half.

**Gate works when the agent has a source to cite:**
- RAG/document-grounded agents (document hash, file checksum)
- Customer support (ticket_id, case_id)
- Medical AI (patient_record_id, clinical note version)
- Legal AI (case_id, filing_id, Westlaw citation)
- Software dev agents (commit_sha, PR id)

**Gate fails when no artifact exists:**
- Pure conversational ("user said they prefer X")
- Proactive observation agents (ambient sensing, no document origin)
- Personal assistant chitchat (reminders, preferences, casual context)
- Free-form personal note-taking (Mem0's consumer use case)

This is not a bug we can fix. The gate is the product. Narrowing ICP is not retreat — it is precision.

---

## §1 — Six-Row Segment Table

| # | Segment | Example Company / Product | Typical Artifact Source | pgmnemo Gate FIT | Buyer Persona | Urgency 1–5 |
|---|---|---|---|---|---|---|
| **S1** | Software dev agents | GitHub Copilot Workspace, Cursor, Agency (our prod user) | `commit_sha`, `pr_id`, `issue_id` | **YES** — commit SHA is the canonical hash already present in every write | Platform Eng / CTO / Solo Dev | **5** — CI/CD audit trail is already expected; compliance is habit not request |
| **S2** | Customer support / ticketing agents | Zendesk AI, Intercom Fin, Freshdesk Freddy | `ticket_id`, `conversation_id` | **YES** — every support event has a durable primary key the agent can cite | VP CX / CTO / Compliance Officer | **4** — CCPA/GDPR mandates traceable decisions; stale belief = wrong SLA response |
| **S3** | Document-grounded RAG agents (enterprise knowledge) | Notion AI, Confluence AI, Guru | `document_id` + `content_hash`, `page_revision_id` | **YES** — documents have versioned stable hashes; agent must cite source page | Head of Eng / CTO / Knowledge Ops | **3** — hallucination risk is felt but compliance mandate is weaker than S2/S4 |
| **S4** | Regulated-industry clinical / compliance agents | Epic Systems (clinical decision support), Veeva Vault | `patient_record_id`, `clinical_note_version`, `document_revision` | **YES** — provenance mandate is regulatory, not optional (HIPAA §164.312, SOC 2) | CISO / Compliance Officer / Chief Medical Informatics Officer | **5** — audit trail is a hard legal requirement; a write without source attribution is a liability event |
| **S5** | Legal research / case management agents | Clio, Bloomberg Law, Westlaw Edge AI | `case_id`, `filing_id`, `citation_string` | **YES** — legal citations are already the atomic unit; every memory write should carry one | Head of Legal Tech / CISO / Senior Partner | **4** — malpractice risk from stale/uncited legal facts is real; Bar associations increasingly require AI audit trails |
| **S6** | Conversational personal assistant agents | ChatGPT memory, Mem0 consumer, Replika | None — facts derived from conversation, no citable source document | **NO** — no artifact_hash exists; gate would reject every write | Consumer / Product Manager | **2** — users want recall, not provenance; "it forgot what I said" is the pain, not "it can't cite the source" |

**Row S6 is the explicit walk-away.** It is the dominant use case by volume (Mem0's 186M API calls/month are mostly S6). It is not pgmnemo's market.

---

## §2 — First-10-Customers Profile

Target profile: citation-grounded segments S1–S5 only. Each row is a distinct ICP hypothesis, ordered by reachability given current state (1 prod user = software dev agent at Agency).

| # | Industry | Company Size | Job Title | Trigger Event That Drives Evaluation | Segment |
|---|---|---|---|---|---|
| 1 | AI developer tooling / coding agent startup | 5–25 eng | Staff or Principal Eng | Agent wrote a stale belief to memory; broke a retrieval; team adds manual provenance field in app code — realizes they've reinvented pgmnemo manually | S1 |
| 2 | B2B SaaS, customer support platform | 50–200 eng | Platform Eng Lead or CTO | Support AI agent gave a wrong policy answer based on a belief written before a policy update; CX lead escalates; team needs audit trail on memory writes | S2 |
| 3 | E-discovery or legal SaaS | 10–50 eng | Head of Engineering | Legal AI citations audited by a client; two memory rows contained outdated case precedent; no write-time source logged; team is embarrassed | S5 |
| 4 | Compliance / GRC SaaS | 20–100 eng | CISO or VP Engineering | SOC 2 Type II audit asks for a log of every fact injected into AI state; team can produce retrieval logs but not write-time provenance; gap surfaces in audit prep | S4 |
| 5 | Healthcare IT startup (ambient scribe / clinical AI) | 15–60 eng | Chief Medical Informatics Officer or CTO | HIPAA audit questions provenance of AI-written clinical memory rows; Epic Systems competitor asks "can you prove that memory came from a signed clinical note?" | S4 |
| 6 | Enterprise knowledge management SaaS | 30–150 eng | Head of AI / Knowledge Ops Lead | Notion AI or Confluence AI competitor evaluating pgmnemo as memory backend — needs document revision tracking baked in, not bolted on | S3 |
| 7 | Fintech (AI-assisted portfolio or research agent) | 25–100 eng | Head of Quantitative Research / CTO | Bloomberg Terminal-adjacent product; AI agent recalled stale price data as a "fact"; compliance team flags write provenance gap | S5 / S2 |
| 8 | DevOps / infrastructure tooling startup | 5–30 eng | Solo Founder or CTO | Building an AI ops agent on top of Postgres; reads pgmnemo README; installs in 5 minutes; replaces 200-line custom memory management code (same trigger as Agency) | S1 |
| 9 | Legal tech (AI contract review) | 10–40 eng | VP Product or CTO | Contract AI writes a belief about governing law from one contract clause; later retrieves it for a different contract; wrong result; trigger = first customer complaint | S5 |
| 10 | Enterprise security / SIEM vendor adding AI agents | 50–200 eng | CISO or Principal Security Eng | Security AI agent must log write-time provenance for every memory insertion as part of alert triage audit trail; SOC team requires it per ISO 27001 | S2 / S4 |

**Common pattern across rows 1–10:** The trigger is not "we want provenance" — it is "something went wrong and now we need to prove where that belief came from." pgmnemo is a reactive purchase initially, not a proactive one. Sales motion must target teams that have already experienced a provenance failure, not teams building greenfield.

---

## §3 — TAM / SAM / SOM (Honest)

### Source basis

Primary: **IDC, "Worldwide Artificial Intelligence Software Forecast, 2023–2027"** (IDC #US50420423, published Q3 2023). IDC sizes the global AI software market at **$297B by 2027**, growing at ~31% CAGR. Agent infrastructure (orchestration, memory, tool-calling runtime) is approximately 8–12% of that envelope per IDC's "AI Platforms and Applications" subcategory breakdown.

Cross-check: **McKinsey Global Institute, "The Economic Potential of Generative AI"** (June 2023) estimates $2.6–4.4T/year in value from generative AI by 2030 across use cases; enterprise software tooling to capture that value is a fraction of enterprise IT spend (historically 3–5%).

**Caveat on all three numbers below:** No analyst firm publishes a "agent memory" line item. The TAM figure is a derived estimate with stated assumptions — not a sourced number. Treat as directional, not investable.

---

### TAM — Global LLM-agent memory spend by 2028

**Derivation:**
- IDC global AI software market: ~$220B by 2028 (interpolating 2027 forecast at 31% CAGR)
- AI agent orchestration + memory layer: 10% of that = **$22B agent infrastructure**
- Agent memory specifically (storage, retrieval, state management): 20% of agent infra = **$4.4B**

**TAM: ~$4B by 2028 (agent memory broadly defined)**

This includes all agent memory: conversational, citation-grounded, vector, graph, relational. It is the ceiling for the entire category.

---

### SAM — Citation-grounded subset, Postgres-using subset

Two successive filters:
1. **Citation-grounded agents** (S1–S5 segments above): approximately 35–45% of agent deployments by spend are in verticals that require source attribution (enterprise software dev, customer support, regulated industries, legal, document RAG). Use 40%.
2. **Postgres-using subset**: PostgreSQL has ~15% market share of all production databases (DB-Engines ranking, Q1 2026) and disproportionately higher in developer tooling / startup / SaaS contexts — estimate 45% of citation-grounded segment runs Postgres as primary DB.

**SAM: $4B × 0.40 × 0.45 = ~$720M by 2028**

This is the market pgmnemo can physically serve: agents with citable sources, on Postgres.

---

### SOM — Realistic 3-year share given OSS distribution + competition

**Honest constraints:**
- 0 paying external customers today (May 2026)
- Mom Test interviews not yet conducted (DISCOVERY_PROTOCOL.md written, interviews pending)
- Competitors with traction: Mem0 (186M API calls/month, AWS SDK integration), Zep (enterprise tier customers), Constructive AgenticDB (same Postgres-native positioning)
- OSS-first distribution: typical open-source conversion to paid support/enterprise tier is 1–3%

**SOM scenarios:**

| Scenario | Assumption | 3-year ARR |
|---|---|---|
| **Conservative (no monetization model)** | OSS with usage; zero commercial layer; 5,000 active installs by 2028; $0 ARR | $0 ARR, non-zero developer adoption |
| **Base (OSS + support contracts)** | 200 active production deployments; 15 convert to $12K/year support contracts | **$180K ARR** |
| **Bull (OSS + enterprise tier)** | 500 active production deployments; 30 convert to $36K/year enterprise tier; 3 regulated-industry customers at $100K/year | **$1.4M ARR** |

**SOM: $180K–$1.4M ARR by 2028 (base to bull)**

This is honest. At $0 LLM cost per write, pgmnemo's value capture is in enterprise compliance features, support, and a future SaaS tier — not in per-write billing. The $720M SAM is a ceiling, not a promise. Capturing 0.2% of SAM = $1.4M ARR in 3 years requires commercial infrastructure that does not exist today.

---

### VC Fundability Assessment (direct answer to WG brief)

**Can pgmnemo raise pre-seed/seed TODAY (May 2026)?**  
Marginally yes for the right check size. The provenance moat is real and technically differentiated (SYNTHESIS C1, unanimous 4/4). One production user (Agency) proves the thing works. The honest pitch: "We are the only write-time provenance gate for agent memory. One production deployment. Zero competitors at the DB-constraint layer. We need capital to run the 10 customer conversations that validate whether S2 (customer support) or S4 (compliance) is the repeatable segment." A $500K–$1M pre-seed from a technical angel who follows DB infrastructure is fundable today. A standard YC-tier seed ($3M at $15M cap) requires 3+ paying customers and evidence that the ICP buys, not just installs.

**What's missing for a credible Series A in 6 months (by Nov 2026)?**
- 3+ external paying customers (not Agency dogfood) — this is the only real gate
- 5+ Mom Test interviews conducted and recorded in DISCOVERY_PROTOCOL.md
- Benchmark card v0 published (POS-RS-PGM §1; SYNTHESIS D2 verdict: P1 by 2026-07-15)
- Evidence that one regulated-industry segment (S4 or S5) has a repeatable budget owner (CISO or Compliance)
- MRR ≥ $10K (even from support contracts) to show commercial intent exists

**Lifestyle business vs venture-scale exit — honest framing:**  
Today (May 2026): lifestyle business risk is real. SAM of $720M with 1 customer and 0 interviews is a research project dressed as a product. Venture-scale path exists but requires the S4/S5 regulated-industry conversion — those segments have compliance budgets of $50K–$500K/year and buy tools that satisfy auditors. If 2 of the first 10 customers (§2 above) are healthcare or legal and sign ≥ $50K contracts, the Series A narrative becomes coherent. If the first 10 installs are all solo developers using OSS for free, pgmnemo is a respected open-source library, not a fundable company. The decision point is whether the next 6 months are spent on customer conversations or on engineering.

---

## §4 — Wedge Sequencing

### Attack order

**Segment 1 (FIRST): S1 — Software Dev Agents**

*Why first:* Agency is already this. Every line of the current codebase was motivated by a software dev agent's needs. `commit_sha` is a natural first-class artifact. Developer-to-developer sales requires no sales team — a good README converts. The cost of getting the first 5 external installs is near zero if README and benchmarks are clean.

*Binary entry criteria (must both be true to count a customer):*
- [ ] Agent's write path has a `commit_sha` or `pr_id` or similar VCS reference available at ingest time
- [ ] Team already runs Postgres (v14+) in production

*Why NOT venture-scalable alone:* Developer tools have low ARPU. 500 free OSS installs at $0/year = $0 ARR. S1 is the **wedge for distribution and testimonials**, not for revenue.

---

**Segment 2 (SECOND): S2 — Customer Support / Ticketing Agents**

*Why second:* `ticket_id` is as natural as `commit_sha`. Zendesk, Freshdesk, Intercom all expose durable ticket IDs. The buyer (VP CX or Platform Eng) has a budget. The pain (support AI gave wrong answer based on stale policy) is recurring and documented. This is the first segment where pgmnemo can charge money.

*Binary entry criteria:*
- [ ] Agent receives a `ticket_id` or `conversation_id` at session start and can pass it to `ingest()`
- [ ] Team is either on Postgres or will migrate to it (Postgres is usually already present as the ticketing system's backend DB)

*Revenue target:* 3 customers at $12–24K/year = $36–72K ARR. Enough to prove commercial intent for a seed round.

---

**Segment 3 (THIRD): S4 — Regulated-Industry Clinical / Compliance Agents**

*Why third:* Highest urgency score (5/5) and highest ARPU ($50K–$500K/year). But sales cycle is 6–12 months (procurement, security review, HIPAA BAA). We cannot attack this segment without reference customers from S1/S2 first — no CISO buys from a 0-customer vendor. The entry here requires S1+S2 case studies.

*Binary entry criteria:*
- [ ] Vendor can sign a HIPAA BAA or SOC 2 Type II report exists (pgmnemo does not have this today — prerequisite: v0.6.0 or later with security audit)
- [ ] Customer runs Postgres (Epic typically uses Oracle/SQL Server — verify before targeting Epic Systems specifically; Epic's Caboodle is SQL Server; Cosmos is different — validate with customer discovery)

*Risk:* Epic Systems runs SQL Server for Caboodle. The actual target in S4 is Epic *competitors* or clinical AI startups building on top of Epic's FHIR API — not Epic itself.

**Abandon for now: S3 (document RAG) and S5 (legal) as primary targets.** They are addressable but the entry criteria overlap with S1+S2, and the sales motions require separate investment. Revisit at v1.0 when reference customers exist.

---

## §5 — What We Lose by Narrowing

### Segments abandoned

| Abandoned Segment | Representative Products | Reason for Walk-Away | Est. % of $4B TAM |
|---|---|---|---|
| Pure conversational memory | ChatGPT long-term memory, Mem0 consumer, Replika | No artifact_hash exists; gate rejects every write by design | **~40%** |
| Proactive / ambient observation agents | Humane AI, proactive scheduling assistants, "lifelogging" tools | Facts are observed, not cited; no document source | **~12%** |
| Free-form personal note-taking agents | Mem0 personal use, Notion AI personal | User writes free text; no stable document hash to associate | **~8%** |
| **Total walk-away** | | | **~60% of TAM = ~$2.4B** |

### What this means in practice

We are deliberately not competing for the $2.4B that Mem0 (consumer/conversational) and Zep (graph episode extraction from free text) are building toward. That is not a loss of addressable revenue — we were never equipped to serve those use cases. The walk-away clarifies the story: pgmnemo is not a general-purpose agent memory layer. It is a compliance primitive for agents that must cite their sources.

The $1.6B remainder (SAM ceiling before the Postgres filter) is a real market. It is a smaller, slower-moving market than the conversational memory race — but it has higher ARPU, mandatory compliance purchase triggers, and no well-funded direct competitor at the write-time enforcement layer.

**Walk-away does NOT mean we lose mindshare.** Open-source distribution means S6-type developers who need conversational memory will still install pgmnemo, realize it doesn't fit, and remember the brand. That is acceptable. The ICP document (§2) and wedge sequencing (§4) guide where we spend sales and feature effort.

---

## §6 — Recommended POSITIONING.md Rewrite

### Tagline (replace current)

**Current:** "The write-time gate for agent memory."  
**Problem:** Claims all agent memory. Fails Karpov's test: pure conversational agents cannot use it.

**Recommended tagline:**

> **"Provenance-enforced memory for agents that must cite their sources."**

### Explanatory paragraph (replace current §"Why pgmnemo exists")

> Agent memory systems fail in a specific way: a fact enters memory without a traceable source, accumulates across sessions, and surfaces as a confident retrieval result. pgmnemo addresses this for agents that have sources to cite — RAG pipelines, customer support bots, clinical AI, legal research agents, software dev agents. Every `ingest()` call must carry a `commit_sha`, `document_hash`, `ticket_id`, or equivalent artifact reference. The Postgres executor rejects writes without one at the RLS constraint level, inside the transaction, before any row reaches the heap. No application code can bypass this without database superuser access.
>
> pgmnemo is not general-purpose agent memory. It does not serve conversational agents, ambient observation agents, or personal assistants that derive beliefs from unstructured dialogue. Those agents do not have artifact sources to cite. If your agent does — if every belief can be traced to a document, a commit, a ticket, or a clinical record — pgmnemo gives you write-time enforcement that no other Postgres-native memory layer provides.

### What this tagline does and does not claim

- **Claims:** narrow, specific, falsifiable — write-time enforcement for source-citing agents
- **Does not claim:** universal agent memory, conversational memory, managed SaaS, scale at Mem0 levels
- **Does not sound niche because:** "agents that must cite their sources" is the entire regulated-industry and enterprise compliance market — it is not a hobbyist qualifier, it is a compliance qualifier

---

## Forced Decisions (Carry to Founder)

| # | Decision | Stakes | Recommendation |
|---|---|---|---|
| FD-1 | Run Mom Test interviews before next engineering sprint? | Without 5 interviews, ICP is a hypothesis; VC fundability claim is speculative | **YES — 5 interviews in 2 weeks (by 2026-05-31). Block engineering time if needed.** |
| FD-2 | Is DISCOVERY_PROTOCOL.md the right tool, or is it overkill for 5 interviews? | Mom Test document exists (Agency #6217); interviews not conducted | PROTOCOL is fine; the problem is execution, not tooling. Assign owner with deadline. |
| FD-3 | Abandon S6 (conversational) explicitly in public positioning? | Mem0 will claim we can't do conversational; we lose that marketing argument | **YES — explicit walk-away in POSITIONING.md is credibility, not weakness.** Mem0 has $23.9M raised; competing on their turf is a losing bet. |
| FD-4 | Can pgmnemo raise pre-seed without S4 validation? | Technical story is fundable; business story needs at least 1 external paying customer | Raise $500K angel round NOW for 6-month runway to get 3 customers; structured seed later. |

---

*Commit: 9aa8f85*
