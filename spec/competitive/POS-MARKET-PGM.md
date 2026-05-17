# POS-MARKET-PGM — GTM + Competitive Narrative (Post-Narrowing)

**Doc ID:** PGMNEMO-WG-VC-260517  
**Date:** 2026-05-17  
**Author:** growth_lead  
**Status:** RATIFIED — internal, do not publish externally  
**Trigger:** Karpov critique of POS-GROWTH-PGM — ICP reframe from "general agent memory" to "citation-grounded agent memory"  
**Companion:** POSITIONING.md (2026-05-17), SYNTHESIS_PGMNEMO_2026-05-17.md

---

## Karpov Reframe in One Sentence

pgmnemo is not "agent memory." It is **agent memory for agents that have a source** — systems where every `ingest()` call can be pinned to a verifiable artifact (`commit_sha`, `artifact_hash`, `ticket_id`, `case_id`, `patient_record_id`). Agents without such artifacts — pure conversational, proactive-observation, personal-assistant chitchat — are structurally incompatible with the gate and are NOT pgmnemo's market.

---

## §1 — Three Tagline Candidates v2

**Constraint:** ≤12 words, falsifiable, honest about narrow ICP. Compare each to the current tagline.

---

### Current tagline: "The write-time gate for agent memory." (7 words)

**Problem:** "agent memory" implies universality. Pure conversational agents ("user said X") have no artifact_hash. The gate rejects them, but the tagline doesn't say so. This is false advertising toward the majority of agent developers.

---

### Candidate A — ICP-explicit gate frame

> **"The write-time gate for agents that cite their sources."**

(9 words)

**ICP signal:** "cite their sources" immediately excludes pure-conversational agents. A developer building a RAG system, legal AI, or customer-support bot with ticket IDs recognizes themselves. A developer building a companion chatbot correctly self-selects out.

**Falsification condition:** an `ingest()` call with no `commit_sha` or `artifact_hash` succeeds at the Postgres layer without SUPERUSER bypass.

**Failure mode:** "cite their sources" sounds academic. A senior infra engineer parses "cite" as a source reference; a product manager may think "academic citation." Works as a README hero; needs a sub-headline for landing pages.

**vs. current:** narrows "agent memory" to "agents that cite their sources" — honest, loses 30% of search-intent breadth, stops misleading 70% of searchers.

---

### Candidate B — Provenance-enforcement frame (compliance buyer)

> **"No artifact hash, no write — memory enforcement for grounded agents."**

(11 words)

**ICP signal:** "artifact hash" is jargon that filters to exactly the narrow ICP. Compliance-oriented engineering teams (legal AI, healthcare AI, financial AI) recognize the enforcement model. "Grounded agents" maps to RAG/document-grounded terminology already used in practitioner communities (LlamaIndex, LangChain "grounding").

**Falsification condition:** same as Candidate A.

**Failure mode:** defines pgmnemo by what it rejects. Works for a pitch slide's "how it works" diagram; too harsh for a top-of-funnel README hero. Best deployed in the competitive matrix and comparison pages.

**vs. current:** 4× more specific, 4× smaller addressable audience. That is the honest tradeoff.

---

### Candidate C — Infrastructure-layer frame (Postgres-native buyer)

> **"Write-time provenance enforcement inside Postgres, for citation-grounded agents."**

(9 words)

**ICP signal:** names the mechanism ("write-time provenance enforcement"), the deployment context ("inside Postgres"), and the narrow ICP ("citation-grounded agents"). Optimized for Postgres practitioners evaluating extensions — PGXN listing, PGConf talk abstract, Postgres Weekly blurb.

**Falsification condition:** same as Candidate A; additionally: pgmnemo requires a sidecar process or external API call to operate after `CREATE EXTENSION`.

**Failure mode:** three concepts in one headline. Postgres practitioners parse it; non-Postgres readers bounce. Correct for the narrow ICP channel — those buyers are already reading PGXN.

**vs. current:** "Postgres-native" was retired because Letta/Constructive already claimed it. This tagline names the mechanism instead of the deployment environment — defensible even after competitors add Postgres support.

---

**Recommendation by surface:**

| Surface | Tagline |
|---|---|
| README hero | Candidate A |
| PGXN listing | Candidate C |
| Pitch slides / competitive comparison | Candidate B |
| Conference talk abstract | Candidate C |

---

## §2 — GTM Channel Ranking (Top 5 for Citation-Grounded ICP)

The narrow ICP buyer is an engineering team building a system where **agent memory writes are tied to an artifact** — document, ticket, commit, case, or patient record. They are already using Postgres. They have a compliance or audit requirement, or they have been burned by hallucinated facts entering agent state.

**Channels excluded (do not work for this ICP):**
- Generic developer relations (reaches conversational/chatbot builders who are not the ICP)
- Product Hunt launch (drives novelty-seekers, not compliance-grounded engineering teams)
- Twitter/X growth hacking (wrong audience density)

---

### Channel 1 — Postgres ecosystem (PGXN + Postgres Weekly + PGConf)

**Why it fits THIS ICP:** Citation-grounded agents are disproportionately built by teams that already run Postgres for their primary data. Healthcare (EHR on Postgres), legal (case management on Postgres), finance (transaction DB on Postgres). These teams evaluate memory layers as extensions of that system, not as standalone services.

**First-90-day cost:** $0 direct spend. PGXN listing is live (≥v0.2.1). Actions: (a) rewrite PGXN description to use Candidate C tagline, (b) submit 400-word article to Postgres Weekly (editorial, $0), (c) submit talk proposal to PGConf.EU 2026 CFP (deadline ~Aug 2026, no cost). Estimated: 8 hours of writing.

**First acquired user lead-time:** 30–45 days from a Postgres Weekly mention. PGConf talk → first adopter inquiry: 4–6 months.

---

### Channel 2 — GitHub cold outreach to agent-memory issues in RAG repos

**Why it fits THIS ICP:** LlamaIndex, LangChain, CrewAI, and Haystack repositories have open issues specifically about memory provenance, citation grounding, and hallucination prevention in agent memory writes. These are developers who already know they have the problem — not "interested in memory" but actively building citation-grounded agents and hitting the provenance problem.

**Target:** Search GitHub for `issues:open label:memory provenance agent` in LlamaIndex/LangChain/CrewAI/Haystack. Expected: 15–40 fitting issues. For each: file a technical comment explaining the gate mechanism + link to the benchmark card. Contribute technically, do not spam.

**First-90-day cost:** $0 direct spend. ~20 hours of issue triage and technical response writing.

**First acquired user lead-time:** 14–21 days from a quality GitHub comment to a DM or email asking about installation.

---

### Channel 3 — Direct cold email to compliance-adjacent AI startups

**Why it fits THIS ICP:** Legal AI startups (Harvey clones, eDiscovery tools), healthcare AI (EHR summarization, clinical note review), and financial AI (regulatory filings review) all have explicit audit trail requirements baked into their compliance posture. A memory system without write-time provenance enforcement is a compliance liability for these buyers — not a feature gap, a blocker. pgmnemo's gate converts that liability into a database constraint.

**Target list construction:** Search AngelList, Crunchbase, and LinkedIn for ("legal AI" OR "healthcare AI" OR "clinical AI" OR "eDiscovery") AND ("agent" OR "RAG") AND headcount 5–50. Expected pool: 200–400 companies. First outreach: top 30, ranked by Postgres signal in job postings or open-source repos using pgvector.

**First-90-day cost:** $0 manual research; ~$200–500 if using Apollo.io or Clay for enrichment. Founder time: ~30 hours.

**First acquired user lead-time:** 30–60 days from first email to a technical call; 60–90 days to first trial installation.

---

### Channel 4 — Academic paper submission (see §5)

**Why it fits THIS ICP:** The research communities that read papers on RAG hallucination prevention, agent memory, and AI safety in regulated industries are the upstream thought leaders for the compliance-grounded buyer. A peer-reviewed paper placing pgmnemo in the citation graph changes the adoption path for research labs, university hospital AI groups, and pharma R&D AI teams — communities that don't respond to cold email but do respond to citations.

**First-90-day cost:** $0 direct spend; 80–120 hours of writing (research_supervisor lead). Target: EMNLP 2026 submission (~June 2026 deadline) or ACL 2027 (~Feb 2027).

**First acquired user lead-time:** 6–18 months (paper → publication → citation → adoption). Start immediately; this channel cannot be rushed.

---

### Channel 5 — Anthropic MCP Registry listing

**Why it fits THIS ICP:** Teams building Claude-powered agents with RAG components are a high-density concentration of the citation-grounded ICP. An MCP Registry listing places pgmnemo in the tool discovery path for these teams before they default to Mem0. Submitting the provenance gate semantics as a proposed MCP memory spec extension (per MENTOR §4) creates a standards-level presence, not just a listing.

**First-90-day cost:** $0 direct spend. Action: build the MCP wrapper (1–3 days engineering). Publish to MCP Registry. Submit provenance gate semantics as proposed MCP extension.

**First acquired user lead-time:** 14–30 days from Registry publication to first install inquiry.

---

## §3 — First-10-Customers Acquisition Plan

**Note:** No POS-WEDGE file exists in the repository. The 10 customer profiles below are derived from the narrow ICP (citation-grounded agent memory) and the WORKS/FAILS analysis from the Karpov critique.

---

### 10 Customer Profiles (Narrow ICP)

| # | Profile | Agent type | Artifact source | Compliance driver |
|---|---|---|---|---|
| 1 | Legal AI startup (contract review) | Document-grounded | `document_hash` of each PDF clause | Attorney-client privilege audit trail |
| 2 | Healthcare AI (clinical note summarization) | EHR-grounded | `patient_record_id` | HIPAA audit trail |
| 3 | Customer support AI (ticket routing + response) | Ticket-grounded | `ticket_id` | SLA accountability |
| 4 | Software dev agent (code review, PR summarization) | Commit-grounded | `commit_sha` | Code change traceability |
| 5 | Financial AI (regulatory filing review) | Document-grounded | `filing_id` / `document_hash` | SOX / SEC compliance |
| 6 | eDiscovery AI (legal document classification) | Document-grounded | `document_hash` | Litigation hold chain-of-custody |
| 7 | Pharma AI (clinical trial data extraction) | Study-grounded | `study_id` / `artifact_hash` | FDA 21 CFR Part 11 |
| 8 | RAG framework maintainer (LlamaIndex plugin author) | Framework-level | Any artifact type | Framework reliability |
| 9 | Academic / research lab (AI safety, agent eval) | Research-grounded | `paper_id` / `dataset_hash` | Reproducibility / citation integrity |
| 10 | Postgres infrastructure consultancy | Client-embedded | Varies by client | Client compliance requirements passed through |

---

### Specific Actions Per Profile

**Profiles 1, 5, 6 (Legal AI / Financial AI / eDiscovery):**
- Find: AngelList/Crunchbase search for "legal AI," "eDiscovery," "contract review," "regulatory AI" + Postgres signal in job postings or GitHub
- Action: cold email (Template 1 below) → technical call → trial install against their staging Postgres
- Pre-qualify gate: they must already have a `document_hash` or `filing_id` in their write path — confirm before calling

**Profiles 2, 7 (Healthcare AI / Pharma AI):**
- Find: HIMSS community, clinical AI communities (r/healthcareit), LinkedIn groups for "clinical NLP" / "healthcare AI engineering"
- Action: post a technical explainer (not promotional) → DM follow-up with cold email (Template 2 below)
- Pre-qualify gate: HIPAA or 21 CFR Part 11 on their compliance checklist — confirm before pitching

**Profile 3 (Customer Support AI):**
- Find: job postings mentioning "Zendesk" AND "LLM" AND "agent" — teams building ticket-grounded agents
- Action: cold email (Template 3 below) → demo using a Zendesk `ticket_id` as the `artifact_hash`
- Pre-qualify gate: confirm they store agent-generated summaries in Postgres, not a vector-only store

**Profile 4 (Software Dev Agents):**
- Find: GitHub repos implementing code review agents using LLMs + storing summaries in Postgres (search `"pg_connect" + "agent" + "review"`)
- Action: open a GitHub issue or PR comment explaining how pgmnemo's `commit_sha` gate closes the hallucination-in-code-review problem
- Pre-qualify gate: they must be writing agent memory to Postgres, not a separate vector DB

**Profile 8 (RAG Framework Maintainer):**
- Find: open Issues in LlamaIndex / LangChain / Haystack tagged "memory" or "provenance"
- Action: file a technical PR or issue comment demonstrating the gate mechanism; offer to co-author a "pgmnemo as a memory backend" integration guide
- Pre-qualify gate: active memory backend plugin architecture

**Profiles 9, 10 (Academic / Consultancy):**
- Academic: submit paper (§5) and follow up with researchers whose papers cite memory hallucination problems
- Consultancy: identify Postgres consultancies (Percona partners, 2ndQuadrant alumni, Timescale ecosystem) and offer co-marketing — they install for clients, pgmnemo provides case study credit

---

### Outbound Templates — Top 3 Segments

**Template 1: Legal AI / Compliance AI (Profiles 1, 5, 6)**

```
Subject: Agent memory provenance for [Company] — write-time enforcement question

Hi [Name],

[Company] is building [what they do] — I noticed your agent stack likely writes memory
entries tied to documents or filings.

One failure mode we see: a hallucinated summary enters agent memory with no link back
to the source document. Your audit log records it; your gate doesn't block it.

pgmnemo is a Postgres extension that enforces this at the database constraint level.
An ingest() call without a valid document_hash or artifact_hash is rejected before the
INSERT completes. Not logged after. Rejected before.

Three questions:
1. Do your agents write memory to Postgres today?
2. Does each write have an associated document_hash or source ID?
3. Do you have an audit trail requirement for those writes?

If yes to all three, 15 minutes would tell us whether we fit. If no — it won't fit and
I'll say so.

[Name]
pgmnemo — github.com/pgmnemo/pgmnemo
```

**Template 2: Healthcare / Pharma AI (Profiles 2, 7)**

```
Subject: HIPAA-compliant agent memory writes — pgmnemo + your patient_record_id

Hi [Name],

Your team is building [clinical AI product]. Agent-generated summaries in healthcare
hit a specific compliance problem: HIPAA requires every data element be traceable to
its source record. Post-hoc audit logs cover "what was written" — they don't block
the write if the source record is absent.

pgmnemo enforces this at the Postgres level: ingest() requires a patient_record_id
(or equivalent artifact_hash) before the row commits. No source ID, no write. This
is an RLS policy inside your existing Postgres instance — not a new service.

Is your agent memory currently written to Postgres with a patient_record_id in the
write path? If so, integration is 2 SQL calls. Happy to show a working example.

[Name]
```

**Template 3: Customer Support AI (Profile 3)**

```
Subject: Ticket-grounded agent memory for [Company] support agents

Hi [Name],

Your support agents likely generate summaries or decisions based on ticket content.
One edge case: an agent writes a memory entry referencing a resolution — but the
ticket_id isn't anchored in the write. Six months later, that memory surfaces in a
retrieval and the original ticket has been closed or reassigned. No audit trail.

pgmnemo gates memory writes against a ticket_id at the Postgres level. ingest() with
ticket_id='ZD-12345' is enforced — no ticket_id means the INSERT is rejected. Your
existing Zendesk ticket IDs become the provenance anchor.

Is your agent stack writing to Postgres? If yes, setup takes under 5 minutes from
CREATE EXTENSION.

[Name]
```

---

## §4 — Competitive Narrative for Narrow ICP

**Audience:** A compliance-grounded engineering team (legal AI, healthcare AI, financial AI) asking "why not [Competitor] + audit log?"

**The frame:** pgmnemo does not compete with Mem0/Zep/Letta on recall quality or scale. It competes on write-time enforcement — a category those systems don't play in. The buyer who needs this has already dismissed audit logs as insufficient; they want structural prevention, not detection.

---

### vs. Mem0 — "Why not Mem0 + audit log?"

**Full argument:** Mem0 runs an LLM extraction pass on every write and logs what the model extracted. The audit log tells you what entered memory after 1,000 patient interactions. pgmnemo's gate blocks the write before the row commits — no agent, regardless of how its prompt is constructed, can write a provenance-free memory entry without database SUPERUSER access. Mem0 solves memory organization; pgmnemo solves write-time enforcement. For a HIPAA audit, "we log every write" and "we reject writes without a source ID" are not equivalent claims.

**2-sentence rebuttal:**

> Mem0 logs what entered memory; pgmnemo decides whether it's allowed to enter. For compliance contexts, recording a violation after the fact is not equivalent to preventing it.

---

### vs. Zep / Graphiti — "Why not Zep with episode provenance?"

**Full argument:** Graphiti's episode back-references are descriptive provenance — they record what source a memory was associated with after the fact. An agent can write any claim and tag it with a source reference that was never verified. pgmnemo's artifact_hash is checked against a valid hash at the RLS layer before the INSERT completes — if the hash isn't registered, the write is rejected. Zep answers "where did this memory come from?" pgmnemo answers "did this memory have a valid source when it was written?" For write-time enforcement, those are not the same question.

**2-sentence rebuttal:**

> Zep's episode back-references describe provenance; they don't enforce it at write time. A Graphiti agent can write a claim tagged with any source reference — pgmnemo rejects the write if the artifact_hash isn't verified before the INSERT commits.

---

### vs. Letta — "Why not Letta on Aurora?"

**Full argument:** Letta's `core_memory_append` is unconditional — application code can write any string to agent memory regardless of source. Letta runs Postgres at the application layer; writes bypass RLS entirely. pgmnemo's gate is evaluated inside the Postgres executor at the RLS layer, before the row reaches the heap. A compromised or buggy agent cannot write a provenance-free row without SUPERUSER access, regardless of how the INSERT is constructed. Letta showed agents need memory; pgmnemo is the gate that decides what memory is allowed.

**2-sentence rebuttal:**

> Letta's `core_memory_append` writes unconditionally — any application code, including a misbehaving agent, can write to Letta memory without source verification. pgmnemo's RLS gate evaluates provenance inside the Postgres executor; bypass requires SUPERUSER access, not a crafted application query.

---

### vs. Constructive AgenticDB — "Why not Constructive? It's also a Postgres extension."

**Full argument:** Constructive AgenticDB (MIT, pgvector/HNSW, bundled Ollama embeddings) is the closest architectural peer — also a Postgres extension, zero new services, local inference. The difference is narrow but structural: Constructive has no provenance gate. An agent using Constructive can write any embedding to the store regardless of source. pgmnemo's `gate_strict` GUC with RLS policy enforcement means write-time rejection is enforced at the database constraint level. If the requirement is "no memory row without a verified source," Constructive does not provide this.

**2-sentence rebuttal:**

> Constructive is architecturally similar — Postgres extension, zero services, local embeddings — but has no write-time provenance gate. pgmnemo's `gate_strict` enforcement rejects unverified writes at the database constraint level; Constructive's writes are unconditional.

---

## §5 — Academic / Community Wedge: ONE Paper

**Target paper:** "Write-Time Provenance Enforcement in Agentic Memory Systems: A Database-Constraint Approach to Hallucination Containment"

**Target venue:** EMNLP 2026, System Demonstrations track — submission deadline approximately June 2026.

---

### Why this specific venue and topic

EMNLP's System Demonstrations track accepts working systems with empirical evaluation. This is not a theoretical contribution — it describes a deployed mechanism (pgmnemo's RLS gate), its empirical rejection rate (Benchmark Card C8: write-rejection rate under `gate_strict=enforce` on 1,000 synthetic + real writes), and citation-grounded recall evaluation (cards C1–C7 already in hand from POS-RS-PGM).

The NLP/LLM community that reads EMNLP is the research population building RAG systems and document-grounded agents — the upstream of pgmnemo's narrow ICP. A peer-reviewed paper places pgmnemo in the citation graph of future papers on agent memory and hallucination prevention. "We use pgmnemo's provenance gate, described in [citation]" is the adoption path for academic-adjacent teams that don't respond to cold email.

**Why NOT a blog post or conference talk instead:** A blog post has no citation weight. A conference talk reaches 200 people with no permanence. An EMNLP System Demo paper (a) appears in the ACL Anthology with a DOI, (b) is citeable by future work, (c) undergoes peer review that independently validates the provenance enforcement claim, and (d) unlocks the academic adoption channel — research labs, university medical AI, pharma AI — that no marketing effort can reach.

---

### What the paper argues

1. Post-hoc audit logging is architecturally insufficient for hallucination containment in agentic memory — existing literature cites the problem; no paper proposes a database-constraint solution
2. Write-time enforcement at the RLS layer inside a Postgres extension is architecturally bypass-proof from the application layer — formal argument + empirical C8 data
3. Recall quality on citation-grounded corpora is maintained — C1–C7 benchmarks (LoCoMo + LongMemEval + Agency corpus)
4. Cost advantage at scale — zero LLM calls per write vs. Mem0 (~$0.17/1K) and Zep (~$0.36/1K), quantified in the §3 cost table

**Owner:** research_supervisor (benchmark data and protocols in hand; POS-RS-PGM spec is execution-ready)  
**Deadline:** EMNLP 2026 CFP, estimated June 2026. Start immediately — 6 weeks to deadline.

---

## §6 — 6-Month Traction Milestones

### VC-Fundability Assessment (Pre-Seed TODAY, May 2026)

**Honest verdict: NOT fundable at pre-seed as-is.**

Evidence against:
- 1 production user (Agency itself — founder dogfood, zero arm's-length validation)
- 0 independent paying customers
- 0 compliance-segment interviews conducted (DISCOVERY_PROTOCOL.md written, not executed)
- No published case study

**For credible seed in 6 months (Nov 2026):** 3 external adopters (non-affiliated), 1 paying customer (any amount), 1 published compliance case study, EMNLP paper under review. Achievable IF the outbound plan (§3) executes in parallel with v0.5.0/v0.6.0 releases.

**Lifestyle business vs. venture-scale — honest answer:** pgmnemo is currently a lifestyle-scale project with a venture-scale technical moat. The moat (write-time RLS enforcement) is real and unique. Market validation is zero. "Venture-scale" becomes defensible only if the compliance segment (legal AI + healthcare AI + financial AI) adopts in a cluster — these buyers have budget and regulatory requirements for exactly what pgmnemo provides. If 3 compliance-segment customers pay within 6 months, the venture narrative is credible. If not, honest positioning is OSS reputation + consulting surface + eventual acquisition.

---

### Month-by-Month Milestones

**M1 — June 2026** (v0.5.0 ships 2026-06-20)

| Metric | Target | Notes |
|---|---|---|
| GitHub stars | 150 | +50 organic from v0.5.0 announcement |
| PGXN downloads (cumul.) | 40 | New installs post-v0.4.1 |
| Outbound leads sent | 10 | Templates from §3 |
| Leads responded | 2 | 20% reply rate expected |
| External adopters (trial) | 0 | Not yet |
| Paying customers | 0 | — |
| EMNLP paper | First draft | Internal review round |

Signal: v0.5.0 bitemporality ships — first time the extension has a DB-layer feature Zep/Graphiti cannot match. Use v0.5.0 release note as outbound trigger.

---

**M2 — July 2026**

| Metric | Target | Notes |
|---|---|---|
| GitHub stars | 250 | — |
| PGXN downloads (cumul.) | 80 | — |
| Benchmark card v0 | Published | C1–C8, pre-registered, honest negatives |
| Outbound leads sent | 20 | — |
| Leads responded | 5 | — |
| External adopters (trial) | 1 | Legal AI or healthcare AI, non-paying |
| Paying customers | 0 | — |
| EMNLP paper | Submitted | — |

Signal: benchmark card publication is the cold email opener for the compliance segment — "the only agent memory benchmark that includes a negative cell and a provenance-rejection rate."

---

**M3 — August 2026** (v0.6.0 ships 2026-08-15)

| Metric | Target | Notes |
|---|---|---|
| GitHub stars | 400 | — |
| PGXN downloads (cumul.) | 130 | — |
| pgpm install pgmnemo | Live | Distribution channel parity with Constructive |
| Outbound leads sent | 30 | — |
| Leads responded | 8 | 3 on technical calls |
| External adopters (trial) | 2 | — |
| Paying customers | 0 | First invoice discussions started |
| MCP Registry | Published | pgmnemo wrapper live |

Gate: v0.6.0 ships first external case study. If no external adopter by M3, v1.0 timeline slips. This is the earliest go/no-go signal for venture narrative.

---

**M4 — September 2026**

| Metric | Target | Notes |
|---|---|---|
| GitHub stars | 550 | — |
| PGXN downloads (cumul.) | 180 | — |
| Leads responded | 10 | — |
| External adopters (trial) | 3 | Target: 1 legal, 1 healthcare, 1 customer support |
| Paying customers | 1 | Any ARR — even $500/month matters as proof |
| ARR | $500–5,000 | First invoice |
| Mom Test interviews | 5 | DISCOVERY_PROTOCOL.md executed |
| EMNLP paper | Under review | — |

VC signal: 1 paying customer + 3 external adopters + paper under review = credible seed deck. Not venture-scale yet, but fundable as a technical narrative with early traction.

---

**M5 — October 2026**

| Metric | Target | Notes |
|---|---|---|
| GitHub stars | 700 | — |
| PGXN downloads (cumul.) | 230 | — |
| External adopters | 3+ with 1 public case study | — |
| Paying customers | 1–2 | — |
| ARR | $1,000–10,000 | — |
| Inbound qualified leads | 5 | First signal outbound is not the only acquisition path |
| AWS Agent SDK verdict | Delivered | P1-gated research spike (SYNTHESIS §D1) |
| Mom Test interviews | 8 | — |

---

**M6 — November 2026** (v1.0 candidate gate)

| Metric | Target | Notes |
|---|---|---|
| GitHub stars | 900 | — |
| PGXN downloads (cumul.) | 300 | — |
| External adopters | ≥3 with public case studies | v1.0 gate per ROADMAP |
| Paying customers | 1–3 | — |
| ARR | $3,000–30,000 | — |
| Mom Test interviews | 10 | ICP validation signal |
| EMNLP paper | Decision received | Accept or reject — either usable for outreach |
| VC-fundability | SEED fundable | IF compliance segment is ≥2 of the 3 external adopters |

**If M6 targets are not met:** do not raise. Continue as OSS reputation project. The moat holds; the market timing is uncertain. 1 compliance-segment paying customer changes this assessment immediately.

---

### Numerical Summary

| Metric | M1 Jun | M2 Jul | M3 Aug | M4 Sep | M5 Oct | M6 Nov |
|---|---|---|---|---|---|---|
| GitHub stars | 150 | 250 | 400 | 550 | 700 | 900 |
| PGXN downloads (cumul.) | 40 | 80 | 130 | 180 | 230 | 300 |
| Outbound sent | 10 | 20 | 30 | — | — | — |
| Leads responded | 2 | 5 | 8 | 10 | 12 | 15 |
| External adopters (trial) | 0 | 1 | 2 | 3 | 3+ | 3+ |
| Paying customers | 0 | 0 | 0 | 1 | 1–2 | 1–3 |
| ARR | $0 | $0 | $0 | $500–5K | $1K–10K | $3K–30K |
| Mom Test interviews | 0 | 0 | 2 | 5 | 8 | 10 |
| EMNLP paper status | draft | submitted | submitted | under review | under review | decision |

---

## Appendix: What's Missing for Credible Series A in 6 Months

1. **Mom Test interviews (0 conducted as of 2026-05-17):** DISCOVERY_PROTOCOL.md is written; interviews are not done. Without 10 interviews validating that compliance-segment buyers feel the write-time provenance problem, every claim in this document is a hypothesis, not evidence.

2. **One compliance-segment paying customer:** Any ARR from a legal AI, healthcare AI, or financial AI team converts "1 production user (founder dogfood)" to "1 paying external compliance adopter." The investor perception delta is nonlinear.

3. **One published case study:** A case study naming the company, the agent architecture, and the specific provenance problem pgmnemo solved is the GTM equivalent of the benchmark card. Without it, every outbound conversation starts from zero.

4. **Benchmark card C8 data (write-rejection rate):** The only metric no competitor can produce. Currently listed as "TBD (to run pre-publication)" in POS-RS-PGM. Run it before M2.

---

Commit: 9aa8f85
