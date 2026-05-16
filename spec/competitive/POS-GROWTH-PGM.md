# POS-GROWTH-PGM — Positioning Growth Work Product
# [PGMNEMO-WG-STRAT-260517]

**Date:** 2026-05-16
**Author:** growth_lead
**Status:** DRAFT — for internal review before POSITIONING.md goes public
**Companion output:** `/external-repos/pgmnemo/POSITIONING.md`

---

## §1 — Tagline Rewrite

**Problem:** "Postgres-native" is no longer a differentiator. Letta runs Aurora in production at Bilt (1M+ agents). Constructive AgenticDB ships "The Postgres Memory Layer for AI Agents." Both arrived there before pgmnemo had a public tagline.

**What to replace it with:** the precise structural claim no one else can make — write-time enforcement at the RLS layer.

---

### Candidate A — Gate-first frame

> **"The write-time gate for agent memory."**

(7 words)

**(a) Audience:** AI infrastructure engineers and platform teams evaluating memory stores for production agents. Familiar with the phrase "write-time" from database / event-sourcing contexts.

**(b) What it does NOT claim:** does not claim "Postgres-native" (Letta/Constructive now own that phrase), does not claim fastest retrieval (Mem0 makes that claim), does not claim managed cloud option, does not reference Postgres at all (intentional — the gate claim is architecture-level, not deployment-level).

**(c) Failure mode:** "gate" is jargon outside platform-eng audiences. A product manager or a non-technical founder will not know what "write-time gate" means. If used as a top-of-funnel tagline without supporting copy, it bounces. Requires an explanatory sub-headline ("Every `ingest()` call is verified against source provenance before the row commits.").

---

### Candidate B — Contrast frame

> **"Agent memory enforced at write time, not logged after."**

(9 words)

**(a) Audience:** Security-conscious engineering teams who have already discovered that audit logs and post-hoc memory reviews don't prevent hallucinated facts from entering agent state. Best for pitch slides and conference talks, where the audience already knows what "audit log" means.

**(b) What it does NOT claim:** does not claim graph memory (Zep's differentiator), does not claim managed SaaS (Mem0), does not claim scale proof at 1M agents (Letta), does not claim bundled embedding pipeline (Constructive).

**(c) Failure mode:** "not logged after" is a jab at Zep's provenance model (episode back-references are post-hoc descriptive, not gating). Zep can respond that their provenance is richer in graph structure. This tagline picks a fight and requires the team to be prepared to defend it head-to-head.

---

### Candidate C — Minimal frame

> **"One Postgres extension. Write-time provenance. No extra service."**

(8 words)

**(a) Audience:** ops/infra engineers evaluating whether pgmnemo adds a new operational burden. Best for README hero copy and PGXN listing where the reader is already in a Postgres deployment context.

**(b) What it does NOT claim:** does not claim retrieval quality (Mem0/Zep claim 91-94% on LoCoMo/LongMemEval), does not claim model-agnosticism (Letta's differentiator), does not claim bundled AI pipeline (Constructive), does not claim $X funding or team size.

**(c) Failure mode:** "No extra service" is true but defensive. If Candidate C is the first thing a buyer reads, it positions pgmnemo as a commodity ("just an extension") rather than a category primitive. Works as a supporting claim, not a lead claim.

---

**Recommendation:** Lead with **Candidate A** as the primary tagline. Use **Candidate B** verbatim for pitch decks and technical conference talks. Use **Candidate C** as the second line of the README hero and PGXN description.

---

## §2 — POSITIONING.md

Full draft at: `/external-repos/pgmnemo/POSITIONING.md`

The draft delivers:
- One-paragraph wedge statement (public-facing, no internal acronyms)
- 6×N competitor matrix (pgmnemo / Mem0 / Zep / Graphiti / Letta / Constructive AgenticDB) on 6 axes: write-time provenance gate, install model, LLM calls per write, temporal memory, license/hosting, production scale evidence
- Corrected Constructive AgenticDB facts: MIT (not Apache-2.0), HNSW (not "no vector index"), bundled Ollama + nomic-embed-text (not user-supplied)
- MAGMA note: MAGMA is an internal benchmark control label (raw pgvector + app-level memory, no memory abstraction layer). Not named in the public POSITIONING.md per the "no internal acronyms" constraint. Appears in bench tables as "pgvector baseline" for competitive honesty.

---

## §3 — Cost-per-1K-Memories Comparison (Rec #3)

**Framing:** pgmnemo's write path is deterministic SQL. The RLS gate rejects or accepts; no LLM is called during ingest. Competitors built LLM extraction into the write path — this is a per-write token cost that compounds at scale.

### Table: Estimated LLM cost per 1,000 memory writes

| System | LLM calls / write | Write model (default) | Est. LLM cost / 1K writes | Source |
|---|---|---|---|---|
| **pgmnemo** | **0** | — (rule-based gate at RLS) | **$0.00** | Deterministic SQL; no extraction step |
| Constructive AgenticDB | 0 | Local Ollama (`nomic-embed-text`) | **$0.00** (local) | Embedding trigger only; no LLM extraction; cost = local GPU/electricity |
| Letta | 0 extra | Agent's model (turn already paid) | **$0.00 extra** | `core_memory_append` is unconditional; write cost is the agent turn, not an extra call |
| Mem0 | **1** | GPT-5-mini (default, May 2026) | **~$0.17** | Single-pass fact extraction per `add()` call; ~500 in + ~150 out tokens¹ |
| Zep / Graphiti (v0.29.0+) | **1** (was 3 pre-v0.29.0) | Configurable (OpenAI / Anthropic / Ollama) | **~$0.36** at gpt-4o-mini¹ | Combined node+edge extraction; ~800 in + ~400 out tokens per chunk |
| Zep / Graphiti (pre-v0.29.0) | **~3** | As above | **~$1.00–$1.50** | Three separate LLM calls per chunk (NER + relation extraction + dedup) |

**Footnotes:**

¹ Estimates use OpenAI list pricing as of May 2026: GPT-5-mini ~$0.15/1M input, ~$0.60/1M output; gpt-4o-mini at same rates. Actual cost depends on provider selection, prompt length, and whether the user supplies a cheaper local model (Ollama). Embedding costs (~$0.02/1M tokens with `text-embedding-3-small`) not included — apply similarly across systems using a hosted embedder.

### Scale-up table: cumulative LLM extraction cost at volume

| System | 100K writes | 1M writes | 10M writes |
|---|---|---|---|
| pgmnemo | $0 | $0 | $0 |
| Constructive AgenticDB | $0 | $0 | $0 |
| Letta (write-only) | $0 extra | $0 extra | $0 extra |
| Mem0 | ~$17 | ~$170 | ~$1,700 |
| Zep/Graphiti v0.29.0+ | ~$36 | ~$360 | ~$3,600 |

**Publishing note:** before shipping this table publicly, validate GPT-5-mini pricing against the current OpenAI pricing page and confirm Graphiti's post-v0.29.0 per-call token consumption with a test ingestion. The per-write estimates above are derived from the zep.md and mem0.md deep-dive reports; they are directionally correct but should be reproduced with an actual API trace before public attribution.

---

## §4 — Letta Citation as Positioning Anchor (Rec #8)

### Exact wording

> "MemGPT showed agents need memory; pgmnemo shows memory needs a gate."

Source: recommended by founder synthesis (CROSS_CUTTING_SYNTHESIS_2026-05-16 §Recommendations #8). Already present verbatim in letta.md §13 as a defense-strategy line.

### Where to deploy

| Surface | Usage |
|---|---|
| **README.md §"Why this exists"** | First bullet or sub-header. Replace or supplement the current "One differentiator none of Pinecone, Letta, Mem0, or Zep have" opener. |
| **POSITIONING.md** | Wedge statement closing sentence. |
| **Conference talks / pitches** | Final line of the positioning slide before the demo. |
| **pgmnemo vs Letta comparison page** (recommended, letta.md §14 #1) | Section opener under "What they showed us." |

### Risk assessment

This line **invokes Letta in our positioning**, which gives them air — any reader who doesn't know Letta now knows to check them out. Specific risks:

1. **Legitimizes the MemGPT framing.** By citing MemGPT/Letta as the category-maker, we confirm their academic lead. Acceptable tradeoff because their lead is already undeniable (22.7K stars); denying it costs credibility.
2. **Letta could ship a provenance gate.** If Letta adds `gate_strict` equivalent to their `core_memory_append` path before pgmnemo v1.0, this tagline becomes historically accurate but no longer differentiating. Risk: medium probability within 12 months (letta.md §13 threat vector #2).
3. **"Gate" word collision.** If Letta also starts using "gate" terminology (their Evals product already uses the concept of a "reliability gate"), the line loses sharpness. Monitor Letta release notes.

**Mitigation:** Ship the citation now while the technical gap is unambiguous; it will remain historically accurate even if Letta closes the gap later.

---

## §5 — Distribution Channel Implications of Mem0/AWS Threat (Rec #4 context)

### Threat recap

Mem0 is the **exclusive memory provider for AWS Agent SDK** (TechCrunch, 2025-10-28; 186M API calls/month, ~30% MoM growth). This is meta-distribution: AWS developers default to Mem0 without evaluating alternatives. pgmnemo's ICP ("teams already on Postgres") overlaps significantly with "teams running on AWS RDS/Aurora."

### PGXN — done

PGXN is live for all releases ≥ v0.2.1. Distribution to the Postgres extension ecosystem is solved. **Next step for this channel:** ensure PGXN listing description uses the sharpened tagline (Candidate A above), not the stale "Postgres-native memory layer" copy.

### Anthropic MCP Registry — HIGH PRIORITY

Anthropic is building an MCP (Model Context Protocol) tool registry. pgmnemo is a natural MCP server — it exposes `ingest()` and `recall_lessons()` as tool endpoints that any Claude-powered agent can call.

| Action | Effort | Owner | Urgency |
|---|---|---|---|
| Wrap pgmnemo as an MCP server (simple HTTP wrapper on the SQL API) | 1-2 days | chief_architect | P1 |
| Submit to Anthropic MCP registry once available | 30 min | growth_lead | P1 |
| Add MCP install path to README ("Use with Claude Code: ...") | 2h | growth_lead | P1 |

**Why this matters:** Claude Code is a direct channel to developers already using Anthropic's stack. An MCP listing is a credibility signal and a discovery path orthogonal to the AWS/Mem0 channel.

### AWS Marketplace — MEDIUM PRIORITY

AWS Marketplace listing would be a direct counter to Mem0's AWS Agent SDK exclusivity. A pgmnemo AMI or CloudFormation template that provisions RDS + pgvector + pgmnemo extension could reach the same AWS-native developer cohort.

| Action | Effort | Urgency | Note |
|---|---|---|---|
| Package pgmnemo as an AWS CloudFormation template | 1 week | P2 | RDS + pgvector + extension install |
| Submit to AWS Marketplace as a free listing | 2-3 weeks (AWS review) | P2 | Need AWS Partner account |
| Explore AWS CDK construct (`pgmnemo-cdk`) | 3-5 days | P2 | Lowers friction for CDK shops |

**Risk:** AWS Marketplace listing for a free extension has low organic discovery. The strategic value is the credibility signal ("AWS-listed"), not the volume. Better ROI may come from being cited in AWS blog posts (e.g., the Aurora + pgvector blog series).

### Vercel Template Gallery — LOW PRIORITY NOW, revisit at v0.6.0

Vercel's template gallery is a strong distribution channel for JS/TS developers. pgmnemo is Postgres-native and works with Vercel Postgres (Neon-backed), but current SDK is SQL-first with no TypeScript client.

| Blocker | Status |
|---|---|
| TypeScript SDK | Not built (ROADMAP target: v0.6.0 adoption tooling) |
| Vercel Postgres compatibility | Untested; likely compatible (Neon + pgvector) |
| Template content | Would need a Next.js agent demo using pgmnemo for memory |

**Recommendation:** Defer Vercel template until TypeScript SDK ships (v0.6.0, target 2026-08-15). Flag for revisit at v0.6.0 release planning.

### Channel priority matrix

| Channel | Effort | Reach | Counter-threat | Priority |
|---|---|---|---|---|
| PGXN (done) | — | Postgres devs | Constructive | Maintain copy |
| Anthropic MCP Registry | Low | Claude/Anthropic devs | (all) | **P1 — now** |
| AWS Marketplace | Medium | AWS-native devs | Mem0 | P2 — v0.5.0 |
| Vercel template gallery | High (needs TS SDK first) | JS/TS frontend devs | — | P3 — post-v0.6.0 |

---

*Document version 1.0. Internal growth strategy artifact. Not for public distribution.*
