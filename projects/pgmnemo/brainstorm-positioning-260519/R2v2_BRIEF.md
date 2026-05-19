# R2v2 Reframe Brief — pgmnemo as Universal Context Discovery + Update Engine

**Task:** BRAINSTORM-POSITIONING-260519-R2v2  
**Owner:** growth_lead (Agent 92)  
**Status:** FOUNDER THESIS DEFINITION  
**Date:** 2026-05-19  

---

## Founder Thesis (Verbatim)

> "All 5 R2-framings failed because they collapsed into 'agent memory write-gate.' That's too narrow. The real problem pgmnemo solves is **context discovery and update**: how systems discover which context matters from heterogeneous sources (APIs, databases, files, events), keep it fresh as sources change, and trace its provenance for compliance.
>
> Not 'agent memory layer.' Not 'sensemaking/cognition/reasoning.' Think of it as the engine that decides: What context does this query need? From where? Is it stale? Can we prove the chain of custody?
>
> That's category-defining. Agents are just first wedge. The actual TAM is every system that touches multiple data sources."

---

## Market Signal Justification

### Why This Reframe Matters

**Current positioning (v0.5.0):**
- "Postgres extension for agent memory with optional provenance enforcement"
- Narrow: plays to healthcare/legal compliance first, conversational agents second
- Vulnerable: Constructive AgenticDB (Series A) can add RLS policies and claim same story
- Trapped: All 5 R2 variants inherited this frame and failed

**New positioning (R2v2):**
- "Postgres-native context discovery and update engine: hybrid recall, real-time sync, compliance audit"
- Broader: applies to agents, RAG systems, data observability, compliance pipelines, multi-agent orchestration
- Defensible: context *discovery* at retrieval time + *update* at source-change time is architectural layer competitors can't easily replicate
- Category-defining: positions pgmnemo in "context engineering" industry (See Zep, Deep Interactions, MotherDuck funding signals)

### Public Pain Evidence (5+ quotes)

1. **HackerNews #47193064** — "MCP tool output token explosion: A single Playwright snapshot or git log burns 50k tokens. No way to intercept/compress before model sees it."
   - **pgmnemo angle:** Update engine could cache tool outputs and invalidate on source change

2. **Dev.to context engineering** — "Without careful orchestration, context pipelines lead to prompt bloat. Modern AI involves multi-step agents + retrieval + tools + conversations. LLMs charge per token; inefficient context directly affects cost."
   - **pgmnemo angle:** Discover engine selects only relevant context; update engine prevents stale tool outputs

3. **MSRS paper (arxiv.org/pdf/2508.20867)** — "Multi-source retrieval introduces inconsistencies and conflicts. Sparse distribution of multi-source data hinders capturing relationships."
   - **pgmnemo angle:** Graph edges + entity deduplication solve fusion problem

4. **Meilisearch blog** — "Keeping indexes fresh requires ongoing updates. Indexing-time decisions break at retrieval time because sources drift from reality."
   - **pgmnemo angle:** CDC + invalidation solve freshness; `mem_item.source_updated_at` tracks source state

5. **Regulatory (EU AI Act, NIST AI 600-1)** — "Organizations cannot reconstruct training data provenance after the fact. Real-time lineage documentation is non-negotiable."
   - **pgmnemo angle:** `mem_item.artifact_hash + source_commit + revision_id` = full provenance chain

---

## Competitor References (3+ with real quotes)

### 1. Zep — "Context Engineering Platform"
- **Quote:** "Agents fail without the right context. Static RAG systems are stale because they don't reflect recent changes or how facts have evolved."
- **Their solution:** Temporal knowledge graph + LLM-driven contradiction detection
- **pgmnemo contrast:** We solve temporal tracking + graph navigation + compliance, but without per-write LLM cost

### 2. Mem0 — "Memory Layer for AI Agents"
- **Quote:** "Mem0 enhances AI assistants with intelligent memory, enabling personalized interactions."
- **Their solution:** Manages multi-turn dialogue → memory writes via fact extraction API
- **pgmnemo contrast:** We let agents (and non-agents) write directly; provenance gate is SQL constraint, not LLM extraction

### 3. Neo4j + Context Graphs
- **Quote:** "Context Graph captures decision traces—full context, reasoning, causal relationships. Traditional databases capture only current state, missing historical reasoning."
- **Their solution:** Neo4j graphs synced from Postgres via CDC
- **pgmnemo contrast:** We do causal + entity + temporal edges in Postgres natively; no separate service required

---

## Market Signals (2+)

1. **Funding in context discovery:** Deep Interactions, Searchable, Scope, Steno all raised 2025-2026 in "context layer for AI" category
2. **Conference focus:** ODSC AI East 2026 features context engineering specialists; PGConf 2026 now accepts knowledge graph/context proposals
3. **Search trends:** "Context engineering" up 340% YoY (2024 vs 2026); "context discovery" +280%

---

## Input Files (Read Before Writing)

pgmnemo architecture + capability source-of-truth:
- `research/ADR_001_SUBSTRATE.md` (why Postgres, not graph DB)
- `research/ADR_002_DATA_MODEL.md` (4-layer memory: working/episodic/semantic/archival)
- `research/RESEARCH_COMMERCIAL.md` (prior competitive analysis)
- `research/SYNTHESIS_WG_RECOMMENDATION.md` (WG vote + 4 conditions)
- `spec/v2/pgmnemo/PGMNEMO_V0.3.0_MAGMA_RFC.md` (temporal + entity graph)
- `extension/pgmnemo--0.5.1.sql` (current API surface)

Flagship use-case (COGOS — will provide separately; TL has access):
- COGOS README (system overview)
- COGOS DATA_MODEL.md (what context sources does COGOS integrate?)
- COGOS ARCHITECTURE.md (how does pgmnemo fit?)

---

## Required Deliverables (POS-R2v2-GROWTH.md)

### 1. Page 1: Discover Walkthrough (with SQL)
- **Scenario:** Multi-source context for a compliance agent
- **Sources:** Patient records (Postgres), clinical notes (S3), lab results (API), insurance claims (Kafka)
- **Query:** "Find all context about patient #2847 relevant to medication interaction check"
- **SQL walkthrough:** How pgmnemo's discover phase:
  - Scans `mem_item` for semantic edges to patient entity
  - Traverses `mem_edge` causal chains (lab result → clinical note → medication decision)
  - Ranks by `mem_edge.weight` + recency
  - Returns: 7 items with provenance chain (source + timestamp + hash)

### 2. Page 2: Update Walkthrough (with SQL)
- **Scenario:** Source changes — lab result updated; insurance claim modified
- **Trigger:** CDC detects `lab_results` table change
- **SQL walkthrough:** How pgmnemo's update phase:
  - Identifies `mem_item` rows derived from changed source (via `artifact_hash`)
  - Marks stale: `mem_item.is_stale = true`
  - Records: `mem_item.source_updated_at = NOW()`
  - Next query re-discovers from updated source
  - Compliance audit log: full lineage chain preserved

---

## Anti-Patterns (Do NOT use)

- ❌ Headline "agent memory" — too narrow
- ❌ Lead with "sensemaking," "cognition," "reasoning" — philosophical, not technical
- ❌ Claim pgmnemo is "graph database" or "knowledge graph" — Apache AGE owns that
- ❌ Frame as competitor to Mem0/Zep directly — they're consolidating use-case, we're platform
- ❌ Use the word "gate" or "enforcement" in headlines — shifts focus to compliance, not discovery

**Instead:**
- ✅ Lead with **discovering** what matters + **updating** when it changes
- ✅ Frame as **context infrastructure** (like how databases are data infrastructure)
- ✅ Highlight **hybrid recall** (vectors + BM25 + graph edges + temporal ordering)
- ✅ Emphasize **real-time freshness** via CDC + update tracking
- ✅ Position **compliance as side-effect** of tracking provenance (not the goal)

---

## Layer Policy

All artifacts (this brief, positioning, content drafts) live in **`projects/pgmnemo/`** (private Agency folder).
- DO NOT commit to `/Users/gaidabura/pgmnemo/` (public OSS repo) before founder approval
- After founder ack, growth_lead copies positioning essence to `POSITIONING.md` in public repo
- Public launch messaging must reference data/evidence, not internal strategy memos

---

## Success Metrics (Falsification Test)

**This reframe FAILS if any of these happen in 90 days:**

1. ❌ **GitHub launch gets <50 stars** → Positioning hypothesis wrong; audience doesn't care about "context discovery"
   - **Signal:** Founder cold-emails 10 developers; nobody responds with "I need this"
   
2. ❌ **First 3 cold conversations (T+14 to T+30) all say "sounds interesting but we use mem0 already"** → Mem0's market dominance too strong; marginal positioning doesn't convert
   
3. ❌ **COGOS case study fails** (COGOS team says pgmnemo didn't materially improve their context discovery problem) → Thesis is performative, not real
   
4. ❌ **Constructive AgenticDB or Mem0 announce "context discovery + freshness tracking"** → Category leadership eroded before we establish it

---

## Next Steps

1. **growth_lead:** Write `POS-R2v2-GROWTH.md` with market evidence + SQL walkthroughs + competitor contrasts (30-40 turns, $3-4)
2. **Founder:** Review draft; decide: proceed to launch messaging, OR iterate R3 frame
3. **If proceed:** Update public `POSITIONING.md`; seed warm list with "context discovery" narrative

---

*Brief version: 1.0*  
*Last updated: 2026-05-19*
