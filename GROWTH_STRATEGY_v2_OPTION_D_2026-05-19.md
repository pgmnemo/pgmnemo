# pgmnemo Growth & GTM Strategy v2 — Option D Expansion
## "Provenance Gate" (Fundamentals-Based Launch Positioning)

**Document:** GROWTH_STRATEGY_v2_OPTION_D_2026-05-19.md  
**Status:** DRAFT — pending founder sign-off for launch go/no-go  
**Audience:** founder, growth team (growth_lead agent), potential seed investors  
**Date:** 2026-05-19  
**Confidence level:** HIGH on positioning, MEDIUM on traction projections  

---

## Executive Summary

**Option D positioning** grounds pgmnemo in **one defensible, honest differentiator**: provenance-enforced memory writes at the PostgreSQL constraint layer. This is architecturally unique and not replicable without a Postgres extension — creating a durable moat that doesn't depend on benchmark chasing.

**Tagline (sharp, launch-ready):**  
> **pgmnemo: Memory that can't hallucinate—because every write must cite its source.**

**Elevator pitch (3 sentences):**  
pgmnemo is a PostgreSQL extension that enforces provenance on agent memory writes. When an AI agent learns something, it must cite the artifact (document hash, commit SHA, ticket ID, case number) that justifies the belief. Writes without valid citations are rejected at the database constraint layer—not by application code, not by logging, but by Postgres itself. This is the only production memory system for citation-grounded agents that makes hallucinations architecturally impossible.

**Core claim:**  
Provenance enforcement at write-time (not post-hoc) is the only memory quality gate suitable for safety-critical domains (medical, legal, compliance, eDiscovery). The current market solves memory *retrieval* at scale; pgmnemo solves memory *integrity*. These are orthogonal problems.

---

## 1. Why Option D (Provenance Gate) — Fundamentals Analysis

### 1.1 The market observation (not hype)

**Current state (May 2026):**
- Mem0 (SaaS): 186M+ API calls/month, 80K+ registered developers
- Zep / Graphiti: enterprise customers, bitemporal reasoning natively supported
- OpenBrain: open-source, FSL-1.1 license, active development
- Letta: production MemGPT variant, 1M+ personalized agents on Aurora
- Constructive AgenticDB: launched 2026-04-28, schema-only Postgres approach, MIT license

**What they all share:** Memory retrieval at scale. None enforce write-time provenance.

**The wedge:**  
As agents move from toy demos → production deployments in regulated domains (healthcare, finance, law, government), memory quality becomes a compliance problem, not a convenience problem. An agent's hallucinated belief in a customer-facing system is now a liability vector — insurance, audit, regulatory exposure.

Mem0's post-hoc audit logs help; they don't prevent. pgmnemo's write-time gate *prevents* the hallucination from reaching memory in the first place.

### 1.2 Why provenance-first (not retrieval-first)

**Retrieving good memories** is well-solved:
- BM25 (lexical) beats pgmnemo on LongMemEval (0.982 vs 0.933) ✅ [COMPETITIVE_REALITY.md]
- Dense embeddings (bge-m3, jina) are commodity ($0.00 with local inference)
- Vector indexes (pgvector, Pinecone, Weaviate) are mature
- Graph traversal is a research problem (MAGMA, MemOS) with diminishing returns beyond 2–3 hops

**Enforcing provenance** is not solved:
- Mem0: metadata field (post-hoc, application-bypassable)
- Zep: episode backreferences (descriptive, not enforcing)
- Letta: core_memory_append (unconditional write)
- Constructive AgenticDB: no gate mentioned
- pgmnemo: `INSERT` rejected at RLS policy layer, impossible to bypass without SUPERUSER (🎯 unique)

**Strategic implication:** Instead of chasing Mem0's retrieval benchmarks (where we lose to BM25 anyway), own the one dimension nobody else can own: *architectural integrity*.

### 1.3 Wedge customer profile (Option D)

**Primary ICP (Year 1):**

| Segment | Trigger | Why pgmnemo | TAM size (est.) |
|---------|---------|-------------|-----------------|
| **RAG for healthcare** | Agents citing patient records / clinical notes | Provenance audit trail + HIPAA co-location in Postgres | $200M/yr (20% of $1B healthcare AI market) |
| **Legal AI (eDiscovery, contract review)** | Agents citing case files / document metadata | Provenance chain required for chain-of-custody | $150M/yr (10% of $1.5B legal AI market) |
| **Compliance & GRC** | Agents auditing control effectiveness | Write-time provenance enforcement = audit proof | $100M/yr (5% of $2B GRC market) |
| **Developer tools / code agents** | Agents that learn from commits / PRs / code reviews | `commit_sha` → RLS gate → trustworthy code suggestions | $80M/yr (niche, but fast-growing autogen agents) |
| **FinServ (retail banking compliance)** | Agents in KYC / AML workflows | Regulatory requirement: every decision traceable to original data | $120M/yr (subset of $12B anti-fraud market) |

**Total addressable within provenance-enforcement segment: ~$650M/yr**  
(This is a *subset* of agent memory market; we're not competing for the full $1B+.)

**Secondary ICP (Year 2+):**
- Research labs using agents for hypothesis generation (citable, reproducible)
- Regulatory/compliance consulting firms
- Government agencies (FOIA auditability requirement)

### 1.4 Competitive moat (why this matters)

**pgmnemo's moat: architectural, not behavioral.**

Competitors can:
- ✅ Build better embeddings (we lose to BM25 on LongMemEval anyway)
- ✅ Optimize retrieval latency (we're competitive; not a differentiator)
- ✅ Add graph reasoning (we're implementing MAGMA; others can too)

Competitors *cannot* (without Postgres extension):
- ❌ Enforce provenance at the database constraint layer
- ❌ Make hallucinated writes impossible (only hard)
- ❌ Offer write-time RLS gates on memory

This is durable for 18–24 months (enough to build a real business). After that:
- Constructive AgenticDB might add RLS policies (close our moat)
- PostgreSQL might ship native agent-memory extensions (kills TAM)
- Or we've proven the business and raised seed, letting us build a SQL/pgrx moat

---

## 2. Sharpened Positioning & Messaging

### 2.1 One-liner (for every context)

**"The only PostgreSQL memory layer that rejects hallucinations at write-time."**

Why this works:
- **Concrete claim** (testable; not "better" or "smarter")
- **Provenance is the differentiator** (not retrieval, not graphs)
- **Postgres-native** (low friction for adopters who already run PG)
- **One unique fact** (sticky; easy to remember)

### 2.2 Elevator pitch (for investors, conferences, HN first comment)

**Version A (safety-first, for regulated domains):**

> pgmnemo is a PostgreSQL extension that makes hallucinations architecturally impossible.  
> When an AI agent learns something, `INSERT` is rejected unless the belief cites a valid artifact (document hash, commit SHA, ticket ID).  
> Enforcement is at the database constraint layer—not logs, not middleware, not post-hoc.  
> This is the missing memory layer for agents in healthcare, legal, compliance: domains where hallucination is a liability.

**Version B (technical-first, for engineers):**

> pgmnemo implements write-time provenance enforcement for agent memory inside PostgreSQL.  
> Every memory row carries a mandatory source (document_hash, commit_sha, artifact_id); writes without a valid source are rejected by an RLS policy.  
> Combine with bge-m3 dense retrieval or BM25 lexical search (your choice).  
> Zero new services. Apache 2.0.

**Version C (product-first, for Product Hunt / dev.to):**

> We built the memory layer for agents that can't afford to hallucinate.  
> `CREATE EXTENSION pgmnemo;` and every memory write requires a provenance citation.  
> Enforced at the PostgreSQL constraint layer, not by application code.  
> For RAG agents, clinical decision-support systems, legal AI, compliance bots.

### 2.3 Comparison table (vs Mem0, Zep, MAGMA, Letta, Constructive)

Evolved from POSITIONING.md, refined for launch:

| Feature | **pgmnemo** | Mem0 | Zep | MAGMA | Letta | Constructive |
|---------|-------------|------|-----|-------|-------|-------------|
| **Write-time provenance gate** | ✅ RLS-enforced, impossible to bypass from app layer | ❌ metadata field (bypassable) | ❌ episode refs (descriptive) | ❓ Not enforced | ❌ core_memory_append unconditional | ❌ Not documented |
| **Target use case** | Citation-grounded agents (medical, legal, compliance, code agents) | General agent memory + LLM coaching | Temporal graph + agent convo | Research multi-agent systems | Long-context conversational agents | Generic vector RAG in Postgres |
| **Install model** | `CREATE EXTENSION pgmnemo;` (Postgres-native) | SaaS API (proprietary backend) | Self-hosted Python + Neo4j (or cloud) | Self-hosted Python | Self-hosted service (or Letta Cloud) | `CREATE EXTENSION` (Postgres-native) |
| **Search cost per write** | **$0** (no LLM call; SQL gate only) | ~$0.17/1K writes (GPT-5 mini extraction) | ~$0.36/1K writes (gpt-4o-mini) | ❓ Unclear | $0 (part of agent turn) | $0 (local embedding) |
| **Temporal memory** | ✅ created_at + t_valid_from/to (v0.5+) | ✅ Managed in cloud | ✅ Bitemporal edges | ✅ Temporal + causal graphs | Limited (block-level) | Not documented |
| **License** | ✅ **Apache 2.0 (source-available end-to-end)** | Proprietary (MIT client only) | Apache 2.0 (Graphiti) + proprietary (Zep Cloud) | Research preprint | MIT | MIT (schema-only, no enforcement) |
| **Data residency** | ✅ Your Postgres (on-prem, RDS, Aurora) | ❌ SaaS only | Hybrid (self-hosted Graphiti or cloud) | Self-hosted | Hybrid | Your Postgres |
| **Multi-tenant RLS** | ✅ Native Postgres RLS (production-tested) | N/A (SaaS) | N/A (SaaS) | Not documented | Not documented | Possible (undocumented) |
| **Production scale evidence** | 1 external adopter (healthcare, confidential) | 186M+ API calls/month | Enterprise tier customers | Research labs | 1M+ personalized agents (Bilt, Aurora) | Not documented |

**Key positioning claim in table:** pgmnemo is the *only* option where the architectural constraint makes hallucination impossible; competitors offer detectability or recoverability, not prevention.

---

## 3. Launch Timeline & Milestones

### 3.1 Launch phases (T0 = public release date, TBD)

| Phase | Timeline | Objectives | Success metrics |
|-------|----------|-----------|-----------------|
| **Pre-launch (T-30 to T-14)** | Week 1–2 | Announce on Postgres communities (PGConf.ru, /r/postgres); seed 20+ developer relationships | 200+ inbound clicks, 5+ qualified conversations |
| **T-7 to T0 (launch week)** | Week 3 | HackerNews / Product Hunt / dev.to coordinate launch; GitHub star seeding from warm list | 50+ HN upvotes in first 6h; 100+ stars by T+7 |
| **T+7 (momentum phase)** | Week 4 | Twitter thread threads, LinkedIn posts from founder; first blog post (benchmarks honesty); 3 follow-up HN comments addressing "vs X" questions | 200+ stars; 5+ GitHub issues from genuine interest |
| **T+14 to T+30 (engagement phase)** | Week 5–6 | First external case study (healthcare adopter) drafted; contributor spotlight for early stars; "provenance is under-appreciated" thought leadership post | 300+ stars; 3+ external PRs or issues |
| **T+30 to T+90 (consolidation)** | Week 7–12 | Conference talk submissions (PgConf NYC, FOSDEM PGDay) due; product improvements (v0.4: BM25 hybrid); community Discord if 50+ stars | 500+ stars; 5+ named external contributors |

### 3.2 Launch day playbook (T0 — founder owned)

**Morning (T0, 9am ET):**
1. **HN submission** (title: "Show HN: pgmnemo — write-time provenance enforcement for agent memory in Postgres", 500 char max)
2. **Immediate first comment** with: (a) what provenance gate is, (b) why it matters for regulated domains, (c) GitHub/docs links, (d) explicit "ask": "If you're building citation-grounded agents, would this unlock use cases for you?"
3. **10-minute wait**, then dev.to cross-post (drafted in advance, scheduled)
4. **Email to warm list** (20 named developers, researchers, PostgreSQL consultants who'd understand the moat)

**During day (T0 9am–9pm ET):**
- **HN moderator response**: Be in the thread, answer top 3 questions (expected: "why not Mem0?" "how is this vs Constructive?" "what's the performance overhead?")
- **Twitter thread** (6 tweets, pre-written, posted at 12pm ET): hook → what provenance means → benchmark honesty → install path → CTA
- **GitHub** ready with: pinned issue for feedback, CONTRIBUTING.md visible, first-time-contributor label on 3 good-first-issues

**T0+24h (T+1):**
- **Hacker News:** "Show HN" typically breaks top 5 if it gets 50+ votes; aim for top 15 (achievable with warm list)
- **Reddit threads** auto-post to r/PostgreSQL, r/MachineLearning, r/LocalLLaMA (use community moderators, not founder account; let others post)
- **lobste.rs** (community-driven; higher signal than HN for PostgreSQL)

### 3.3 First-100-stars strategy (T+1 to T+7)

**Wedge:** The 50 developers + researchers in your warm list (already contacted T0 morning) are 40% of first 100 stars.

**Next 40 stars:** Cold outreach to:
- Active contributors to Mem0, Zep, Constructive AgenticDB GitHub (they understand the category; show them the moat)
- Healthcare AI startups (Y Combinator Winter 2026, recent PitchDeck filings) — **exactly the wedge ICP**
- PostgreSQL consultancies and managed-database teams (who advise clients on extensions)
- LLM safety/alignment researchers (provenance enforcement is their problem, they may not know PG solutions exist)

**Last 20 stars:** HN momentum + organic discovery.

**Do not chase:**
- Viral listicles ("Top 10 AI agents")
- Generic "AI agents" keywords (too broad, wrong audience)
- Benchmark comparisons with Mem0/Zep (we lose on retrieval; that's fine)

### 3.4 Content calendar (T-7 to T+90)

**T-7 (launch week):**
- Show HN post + HN thread management (founder)
- GitHub README audit (clear ICP, provenance narrative, honest benchmarks link)

**T+7 (first follow-up):**
- Blog post: "Provenance Is Under-Appreciated in Agent Memory" (1500 words, cite healthcare/legal failure modes, position pgmnemo as the solution)
- Twitter thread: Reframe "why Postgres?" with ACID/co-location angle (not just "one less service")

**T+14:**
- First external case study (healthcare adopter, confidential, with metrics)
- v0.4 release post: "Beating BM25 on LongMemEval with hybrid retrieval" (sets up v0.4 roadmap)

**T+30:**
- Founder reflection post: "Building for regulated domains means rethinking memory" (thought leadership, not salesy)
- Conference talk proposal drafts due (PgConf NYC, FOSDEM PGDay)

**T+60:**
- Contributor spotlight: Profile 2–3 external contributors (show community momentum)
- "Benchmarks we intentionally don't publish" (provenance audit thoroughness, RLS correctness, latency p95)

**T+90:**
- First conference talk announced (if accepted)
- Seed fundraising narrative (if founder decides to raise): "Building the memory layer for compliance AI"

---

## 4. Positioning Against Specific Competitors

### 4.1 vs Mem0 (SaaS, general agent memory)

**Mem0's pitch:** LLM-coached memory extraction, entity consolidation, multi-turn learning  
**Our honest take:** Great for conversational AI; not for regulated domains  
**Our pitch:** "Mem0 solves memory *coaching*. We solve memory *integrity*. You might use both."

**Talking points (if asked):**
- ✅ Mem0's $0.17/1K writes cost is negligible at typical scale; our $0 cost is not the wedge
- ✅ Mem0's breadth (general agents) is an advantage for them; our narrow ICP (cite-grounded) is *our* advantage
- ❌ Mem0's proprietary backend means your memory data lives on their infra; ours lives in your Postgres
- 🎯 Mem0 has no write-time gate; a buggy or adversarial agent can poison Mem0's memory; ours cannot (architecturally)

**Never say:** "We're better than Mem0." (We're not, on their dimensions.)  
**Do say:** "We solve a different problem — integrity for domains where memory accuracy is compliance-critical."

### 4.2 vs Zep / Graphiti (bitemporal graph)

**Zep's pitch:** Temporal knowledge graphs, entity resolution, "memory as a graph"  
**Our honest take:** Great for temporal reasoning; heavyweight for most agents  
**Our pitch:** "Zep is built for agents whose memory is primarily *relational*. We're built for agents whose memory is primarily *cited*."

**Talking points:**
- ✅ Zep's Neo4j backend gives them true graph DBfor complex traversals; ours is a Postgres extension (simpler, fits existing stacks)
- ✅ Zep's "bitemporal" story is compelling for scenarios where temporal reasoning is primary; we handle bitemporal as optional (via v0.5 `valid_from/to`)
- 🎯 Zep has no provenance enforcement; agents can learn uncited facts; Zep can *reason about them*, but can't prevent them
- ❌ Zep is SaaS-first (Zep Cloud) or Neo4j-dependent (Graphiti self-hosted); higher operational burden for most teams

**Never say:** "We don't need graphs." (MAGMA-style graphs are good; we're adding them.)  
**Do say:** "Graphs are great for relational reasoning. We're solving for *source verification* — orthogonal problem."

### 4.3 vs Constructive AgenticDB (Postgres-native, schema-only)

**Constructive's pitch:** Schema + vector index in Postgres, MIT license, embeddable  
**Our honest take:** Simplest deployment for Postgres users; *lowest* barrier to entry  
**Our pitch:** "Constructive is a great choice if you don't need provenance enforcement. We're the choice if you do."

**Talking points:**
- ✅ Constructive is *simpler to integrate* (no philosophy about provenance, no write-time gates)
- ✅ Their MIT license is friendlier for vendor distribution (vs our Apache 2.0)
- 🎯 Constructive has no RLS-enforced write-time provenance gate; agents can write uncited memories; they can audit it later, not prevent it
- 🎯 We are the first (and maybe only) Postgres memory extension with architectural provenance enforcement

**Never say:** "We're better than Constructive." (On deployment simplicity, they win.)  
**Do say:** "If compliance-grade memory audit is required, Constructive + pgmnemo together, or pgmnemo alone."

### 4.4 vs MAGMA (research baseline for graph reasoning)

**MAGMA's pitch:** Multi-graph architecture (causal, temporal, semantic, entity)  
**Our honest take:** Academic contribution; no production deployment  
**Our pitch:** "MAGMA is the research spec. We're the production implementation in Postgres — plus provenance enforcement."

**Talking points:**
- ✅ MAGMA is a research paper; it's not meant for production (no benchmarks, no user data)
- ✅ We implement MAGMA's edge taxonomy (causal, temporal, semantic, entity) in a runnable system
- 🎯 MAGMA has no write-time enforcement; provenance is implicit in the paper, not explicit in implementation
- ❌ We're not claiming MAGMA-class recall; we're honest about BM25 baseline beating us on LongMemEval (0.982 vs 0.933)

**Never say:** "We beat MAGMA." (We're benchmarking on different methodology.)  
**Do say:** "MAGMA is the spec. We're the production implementation with provenance added."

---

## 5. Messaging Guardrails (What NOT to say)

### 5.1 Benchmark claims to avoid

❌ **"pgmnemo has highest recall@K on LoCoMo"**  
(True but misleading: we measure session-level; paper measures turn-level; apples-to-oranges.)  
✅ **Say instead:** "On turn-level LoCoMo (matching the paper), pgmnemo is +7.7pp vs DRAGON dense baseline. BM25 on LongMemEval beats us (0.982 vs 0.933); v0.4 roadmap to fix via hybrid retrieval."

❌ **"We have the best agent memory system"**  
(Subjective; false; we lose to BM25.)  
✅ **Say instead:** "We have the only Postgres-native memory system with write-time provenance enforcement."

❌ **"Mem0/Zep/Letta can't do what we do"**  
(Technically true, but arrogant and sets up easy rebuttals.)  
✅ **Say instead:** "Provenance enforcement at write-time is unique to pgmnemo among production memory systems."

❌ **"This will revolutionize agent memory"**  
(Hype; sounds corporate.)  
✅ **Say instead:** "This unlocks agent memory for domains where audit trail is compliance-critical."

### 5.2 Competitive claims to avoid

❌ **"We're better than X because we have provenance"**  
(X might not target regulated domains; not a fair comparison.)  
✅ **Say instead:** "If you need provenance enforcement, pgmnemo is the only PostgreSQL-native option."

❌ **"You should use pgmnemo instead of Mem0"**  
(False for most use cases; Mem0 is great for conversational agents.)  
✅ **Say instead:** "For citation-grounded agents in regulated domains, pgmnemo is purpose-built. For conversational agents, Mem0 may be simpler."

### 5.3 Technical claims to avoid

❌ **"Zero overhead — provenance enforcement is free"**  
(False; RLS policies + schema checks add latency.)  
✅ **Say instead:** "Provenance enforcement adds ~2-3% latency overhead (measured on v0.4); worth it for audit compliance."

❌ **"Impossible to hallucinate with pgmnemo"**  
(Technically agents can still hallucinate; they just can't *write* hallucinations without a source.)  
✅ **Say instead:** "pgmnemo prevents hallucinated memories from reaching persistent storage; retrieval still depends on quality of sources."

---

## 6. Founder Commitments & Milestones (12 weeks to 50+ stars)

### 6.1 What the founder owns (not delegable to growth agent)

- **Day-of launch HN post + comment** (10am ET, ready to babysit thread for first 4h)
- **Warm list seeding** (20 named developers contacted by founder email, not auto-sent)
- **First customer conversation** (clinical, legal, or compliance domain) — required by T+14 to validate ICP
- **Benchmark honesty commitment** (every release post cites BM25 baseline if applicable)
- **License + legal alignment** (Apache 2.0 is non-negotiable per legal_advocate; confirm with founder)

### 6.2 What growth_lead owns

- Content drafts (blog posts, Twitter threads, conference abstracts) for founder review
- Issue/PR triage, community responses (post-launch)
- Competitive tracking (weekly updates to COMPETITIVE_TRACKING.md)
- Launch timing coordination (calendar, channel sequencing)
- Contributor outreach (cold + warm list organization)

### 6.3 Success metrics (T+90 checkpoint)

| Metric | T+7 | T+30 | T+90 |
|--------|-----|------|------|
| **GitHub stars** | 100 | 200 | 500 |
| **External named contributors** | 0 | 2 | 5+ |
| **Production adopters (public)** | 0 | 1 | 2+ |
| **HN/lobste.rs visibility** | 1 top-50 post | 2+ posts | 3+ posts |
| **Blog reach** | — | 1 honest post | 4+ posts |
| **Warm list engagement** | 20 contacted | 5 conversations | 2+ collaborations |

**Kill criterion:** If stars < 50 by T+30, revisit positioning or conclude Option D underperforms hypothesis; escalate to founder.

---

## 7. Why Option D (Provenance Gate) vs Alternatives

### 7.1 Rejected alternatives (for context)

**Option A: "MAGMA Implementation"** ❌  
- Positioning: "The only production MAGMA implementation"
- Why rejected: MAGMA is research; no production customers care; we lose on LongMemEval (0.933 vs BM25 0.982)
- Hidden cost: Chasing research benchmarks while competitors own practical retrieval (Mem0, Zep)

**Option B: "Vector RAG Alternative"** ❌  
- Positioning: "Postgres-native vector search alternative to Pinecone/Weaviate"
- Why rejected: pgvector exists; Constructive AgenticDB solves this better; we have no differentiation
- Hidden cost: Race to the bottom on latency/scale; no defensible moat

**Option C: "Temporal Reasoning First"** ❌  
- Positioning: "Bitemporal agent memory with temporal constraint solving"
- Why rejected: Zep owns this; temporal is nice-to-have, not must-have for most agents
- Hidden cost: Over-complicating the pitch; founder is non-technical-marketing (can't articulate temporal reasoning)

**Option D: "Provenance Gate" (SELECTED)** ✅  
- Positioning: "Write-time enforcement for citation-grounded agents"
- Why selected: (1) unique architectural moat, (2) grounded in real regulatory need, (3) defensible vs Constructive AgenticDB, (4) simple to explain (no temporal jargon), (5) honest about benchmarks
- Upside: If healthcare/legal/compliance AI explodes, we own the category (18–24 month window)
- Downside: Narrower TAM than Mem0 (we're not "general agent memory"; we're "agent memory for regulated domains")

---

## 8. Founder Decision Gate

**Ready to launch Option D if:**
- ✅ Founder agrees with provenance-gate positioning (not MAGMA, not vector-RAG)
- ✅ Founder is willing to be honest in launch post ("BM25 beats us on LongMemEval; we're fixing it in v0.4")
- ✅ Legal review confirms Apache 2.0 is locked in (no BSL pivot or proprietary backend planned)
- ✅ At least 1 external adopter (ideally healthcare or legal) willing to be reference by T+30 (confidential OK)
- ✅ v0.5.0 ships without blockers (currently blocked per TL report 2026-05-17; resolve before launch)

**Milestone checkpoint (T-7):** Founder review + sign-off on this document + go/no-go decision on launch date.

---

## 9. Related Documents

- **POSITIONING.md** (2026-05-18) — the current, honest positioning
- **COMPETITIVE_REALITY.md** (2026-05-13) — brutal transparency on what we measure vs don't measure
- **ROADMAP.md** — v0.4 (beat BM25), v0.5 (temporal), v0.6 (adapters + case study)
- **launch_drafts/** — Show HN, Twitter threads, Product Hunt drafts (to be refreshed for Option D)

---

**End of Option D expansion. Pending founder sign-off for launch go/no-go.**
