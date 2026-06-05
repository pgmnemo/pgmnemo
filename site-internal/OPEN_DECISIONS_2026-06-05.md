# pgmnemo.com — Open Decisions: Founder Sign-Off Required
**Date:** 2026-06-05  
**Author:** growth_lead (92)  
**Input:** SITE_COMPETITIVE_TEARDOWN_2026-06-05.md + positioning briefs (REFRAME-260603, LIGHTRAG-260604, MULTIMODAL_SYNERGY-260529)  
**Status:** AWAITING FOUNDER GO/NO on each item below. Copy deck blocked on D1, D3, D4.

---

## D1 — Hero line selection [DECISION REQUIRED — blocks copy deck §S1]

**Question:** Which is the primary headline? Which becomes the sub?

**Option A (recommended):**
- H1: **"The missing retrieval stack for Postgres"**
- H2: "Single SQL plan across vector, BM25, graph, and metadata. Zero LLM cost per write. The memory learns what actually worked."

*Rationale:* "Missing retrieval stack" names the category and defines the audience (Postgres engineers) in one phrase. "Learns what actually worked" lands as emotional resonance in the sub — the outcome-confidence wedge in industrial terms. This follows the settled Layer-1 positioning from REFRAME_2026-06-03. The phrase "missing" does the heavy lifting: it is not "a retrieval layer," it is the one that wasn't there.

**Option B (alternative):**
- H1: **"Agent memory that learns what actually worked"**
- H2: "Single-plan vector + BM25 + graph recall inside your existing Postgres. No new service. Zero LLM cost per write."

*Rationale:* Leads with outcome benefit rather than infrastructure positioning. Stronger emotional hook, but blurs the category definition (sounds like Mem0/Zep territory). Violates the "don't open on a competitor-owned axis" rule from feedback_pgmnemo_content_voice.

**Growth_lead recommendation: Option A.**  
If founder prefers B, the comparison table must visually anchor pgmnemo in the Postgres/infrastructure axis, not the SaaS-memory axis.

**[ ] FOUNDER DECISION:** _______ (A / B / variant)

---

## D2 — Social proof: what can we honestly show right now? [DECISION REQUIRED — blocks §S2]

**What we can show without consent issues:**
- One anonymous production fleet: "Used in a multi-agent production fleet (~1,000 agent runs/week)" ✅ — this is Agency; references are sanitized, no company name
- A/B result: "−68% agent turns where recall fires a relevant hit" ✅ — Agency A/B, statistically significant on that slice; the case study in `research/CASE_STUDY_AGENCY_2026-06-01.md` is cleared except one [AGENCY-REVIEW] figure
- PGXN listing ✅ (public and verifiable)
- PyPI: `pgmnemo-mcp` on PyPI ✅
- GitHub star count ✅ (whatever the current count is — pull live)
- LongMemEval recall@10 = 0.9604 ✅ (published, reproducible)

**Potentially showable, needs founder decision:**
- **agentplatform.ru** — mentioned in v0.8.2 changelog as a bug reporter with production use ("agentplatform.ru/RZD: ghost rows, silent empty recall"). Can we name them as an adopter, or only as a "bug report from production user"? They appear to be a real external production user.
  - [ ] FOUNDER: Can we name agentplatform.ru by name on the site?
  - [ ] FOUNDER: Is there a written consent / case study draft we can reference?

**What we cannot show:**
- Star count (fabricated) — will use live badge
- Logos / named quotes from users without consent
- "Enterprise customers" language (we're pre-enterprise)
- Mem0/Zep comparative quality benchmarks on the same datasets (they optimize different objectives; apples-to-oranges per COMPETITIVE_REALITY.md)

**[ ] FOUNDER DECISION D2a:** Name agentplatform.ru by name? Yes / No / Only with their consent  
**[ ] FOUNDER DECISION D2b:** Is the −68% turns figure cleared for public use from case study? Yes / No (it's marked [AGENCY-REVIEW])

---

## D3 — 0.8.x claim freeze: which numbers go on the site [DECISION REQUIRED — blocks §S6]

Claims I'm confident are shipped and publicly defensible:

| Claim | Shipped | Falsification condition published? |
|---|---|---|
| $0 LLM cost per write | ✅ all versions | ✅ POSITIONING.md §falsification |
| Single-plan multimodal fusion | ✅ all versions | ✅ |
| EXPLAIN-able ranking | ✅ all versions | ✅ |
| `navigate_locate` / `navigate_expand` (token-economy) | ✅ 0.8.0 | ✅ |
| `reinforce()` outcome-learning | ✅ 0.7.0 | ✅ |
| `match_confidence` quality signal | ✅ 0.7.1 | ✅ |
| LongMemEval-S recall@10 = 0.9604 | ✅ 0.6.2 | ✅ benchmark protocol published |
| Self-embedding via EMBEDDING_SERVER | ✅ 0.8.2 | ✅ |
| −68% turns on relevant-hit runs | ✅ Agency A/B | ⚠️ internal data, needs consent decision (D2b) |

Claims that should NOT appear on the site at 0.8.x:
- pgmnemo beats NaiveRAG / BM25 baseline on open-QA retrieval quality — **FALSE per COMPETITIVE_ANALYSIS_LIGHTRAG**: NaiveRAG beats us on open-QA. Do not claim general retrieval quality superiority.
- "Temporal moat" / temporal advantage — **competitor-owned axis (Zep)**; removed per teardown recommendation.
- Any benchmark without the honesty caveat from COMPETITIVE_REALITY.md.

**[ ] FOUNDER: Any claims to add or remove from the freeze list above?**

---

## D4 — LightRAG 49x ingestion speed claim [DECISION REQUIRED — blocks §S6]

**Context from teardown:** TL flagged "latency 49x, $0 ingestion vs LightRAG" as a killer number buried in the site that should come to hero. I don't have COMPETITIVE_ANALYSIS_LIGHTRAG_2026-06-04.md directly, so I cannot verify this claim's exact methodology.

Before this appears on the landing page, I need:

1. **Source:** What is the 49x figure based on? (LightRAG ingestion pipeline time vs pgmnemo SQL INSERT? Under what conditions? What document corpus size?)
2. **Reproducibility:** Is there a benchmark script? Can this be challenged / reproduced by a skeptical commenter on HN?
3. **Honest framing:** "49x faster ingestion" compared to LightRAG graph-construction pipeline is credible (LightRAG does LLM-backed graph extraction per document, which is slow; pgmnemo does SQL INSERT, which is fast). But the framing needs to be precise: "49x faster to ingest" not "49x faster to retrieve."

**Proposed safe framing (if 49x is confirmed):**
> "Ingest in milliseconds — not minutes. LightRAG builds a knowledge graph via LLM extraction on every document (seconds to minutes per batch). pgmnemo ingests via SQL INSERT. The gap is ~49x at [N-doc corpus size]."

**[ ] FOUNDER: Please confirm (a) the 49x source and methodology, (b) whether it is reproducible, (c) if yes, cleared for hero placement.**

---

## D5 — Comparison table: which competitors to include [MINOR — growth_lead can decide, but flagging]

**Teardown recommendation:** Drop MAGMA from public-facing comparisons (academic, not a product competitor). Keep: Mem0, Zep, LightRAG.

**Growth_lead recommendation for comparison table columns:**
- pgmnemo vs LightRAG (structural win on ingestion cost — recommended new lead comparison based on COMPETITIVE_ANALYSIS_LIGHTRAG_2026-06-04)
- pgmnemo vs Mem0 (the known market leader; frames us relative to the incumbent)
- pgmnemo vs Zep (graph-memory axis; avoids temporal framing — compare on install complexity and write cost, not temporal features)

**What I'm NOT putting in the table:**
- MAGMA (academic; not a product)
- Constructive AgenticDB (too small; elevates them)
- Letta (different category: agent framework, not memory layer)

**[ ] FOUNDER: Approve comparison table scope? Any additions/removals?**

---

## Summary: what is blocking the copy deck

| Decision | Blocks | Priority |
|---|---|---|
| D1: hero line | §S1 (hero) — the entire first impression | P0 |
| D2: social proof consent | §S2 (proof strip) | P0 |
| D3: claim freeze | §S6 (numbers) | P0 |
| D4: 49x source | §S6 (numbers) | P0 |
| D5: competitor scope | §S7 (comparison table) | P1 |

**The copy deck (COPY_DECK_2026-06-05.md) is written with Option A for D1, agentplatform.ru named with [NEEDS CONSENT], and 49x marked [NEEDS FREEZE]. Founder can review the deck in parallel with making decisions above.**

---

*growth_lead (92) · 2026-06-05*
