# pgmnemo.com — Proof Asset Inventory
**Date:** 2026-06-05  
**Author:** growth_lead (92)  
**Purpose:** Honest inventory of every proof point we can show on pgmnemo.com RIGHT NOW.  
**Rule:** Nothing fabricated. Nothing that requires future consent we don't have. Flags where consent/verification is needed.

---

## Tier 1 — Verified, no consent needed, can publish immediately

### T1.1 — OSS metrics (pull at publish time)
- **GitHub stars:** live badge from shields.io — pull at build time, always current
- **GitHub forks:** same
- **Open/closed issues:** indicative of community activity
- **PyPI installs:** `pgmnemo-mcp` on PyPI — show monthly/total install count via pepy.tech badge or manual pull
- **PGXN listing:** `https://pgxn.org/dist/pgmnemo/` — verifiable

### T1.2 — Retrieval benchmarks (published, reproducible)
All numbers from README.md §Benchmarks, backed by `docs/BENCHMARK_PROTOCOL.md`:

| Benchmark | Number | Caveat |
|---|---|---|
| LongMemEval-S recall@10 | **0.9604** | Hybrid RRF Fix-A v0.6.2; gap to BM25 baseline (0.982) = −2.2pp; reproducible via `benchmarks/longmemeval/` |
| LoCoMo session recall@10 | **0.7994** | Session-level (paper-canonical); 22× smaller search space than paper Table 3 — must state this |
| LoCoMo turn-level recall@5 | **0.302** | Apples-to-apples with paper DRAGON baseline (0.225) → +7.7pp |

**Critical: honesty callout must accompany any benchmark number.** See `docs/COMPETITIVE_REALITY.md`. These are not "we beat everyone" numbers.

### T1.3 — Economic claims (derivable from published competitor pricing)
- **$0 LLM cost per write** — pgmnemo architecture (SQL constraint check). Falsification condition published in POSITIONING.md.
- **vs ~$0.17 / 1K writes (Mem0)** — Mem0 pricing page, GPT-3.5-mini fact extraction cost
- **vs ~$0.36 / 1K writes (Zep)** — Zep pricing, post-v0.29 LLM contradiction detection
- These are competitor pricing estimates. **Monitor for accuracy.** If Mem0/Zep change pricing, update within 30 days.

### T1.4 — Feature shipping status
All features in S5 "Why" section are shipped as of v0.8.x:

| Feature | Shipped version | Verification |
|---|---|---|
| Single-plan multimodal fusion | All versions | `EXPLAIN ANALYZE SELECT * FROM pgmnemo.recall_hybrid(...)` |
| EXPLAIN-able ranking | All versions | Same |
| `navigate_locate` / `navigate_expand` | 0.8.0 | CHANGELOG.md |
| `reinforce()` outcome-learning | 0.7.0 | CHANGELOG.md |
| `match_confidence` | 0.7.1 | CHANGELOG.md |
| Provenance gate (`gate_strict`) | All versions | SQL_REFERENCE.md |
| Self-embedding via EMBEDDING_SERVER | 0.8.2 | CHANGELOG.md |
| Zero data egress | Architecture — inherent | Any `EXPLAIN ANALYZE` shows in-DB execution |

### T1.5 — Regression test count
**21/21 pg_regress tests ✅** — visible in every CI run badge. Can be shown as a trust signal.

---

## Tier 2 — Real, needs consent decision before publishing

### T2.1 — agentplatform.ru / RZD [FLAG D2a]
**Evidence of real production use:** v0.8.2 CHANGELOG explicitly names "agentplatform.ru/RZD" as the source of three bug reports fixed in that release ("ghost rows, silent empty recall"). This means:
- They are a real external user
- They ran pgmnemo in production (hit real bugs under load)
- They communicated with the project (bug reports were incorporated)

**What we can show WITH consent:**
- Logo/name on proof strip
- "Used at agentplatform.ru for [use case]"
- Potential for a first named external case study

**What we can show WITHOUT consent:**
- "One production external deployment" (anonymous)
- The bug-fix narrative: "Bugs F1/F2/F3 in v0.8.2 were reported by a production user running agents at scale" — no name

**Action required:** Founder reaches out to agentplatform.ru contact. Ask for: (a) consent to name, (b) one sentence describing their use case, (c) whether they'd write a 3-paragraph case study. Even "we use pgmnemo for X" on a GitHub issue is consent.

**Priority:** High. A named external adopter is the single highest-leverage proof point we're currently missing.

### T2.2 — Agency A/B: −68% turns on relevant-hit runs [FLAG D2b]
**Evidence:** `research/CASE_STUDY_AGENCY_2026-06-01.md` contains:
> "on runs where recall found a relevant lesson, agents used about 68% fewer turns to finish (statistically significant on that slice; we treat it as a strong directional result, not a final number)"

The case study is marked "DRAFT for pgmnemo team use" and has one [AGENCY-REVIEW] figure (cost per repeated failure, $2–$18). The −68% figure itself is marked as cleared.

**What we can show:**
- The −68% figure with its full honest framing: "on the subset of runs where recall fired a relevant hit; statistically significant on that slice"
- The case study itself can be adapted and published as a blog post (see CONTENT CALENDAR)
- "Agency, a multi-agent production fleet, saw −68% turn reduction on relevant-recall runs"

**What we cannot show:**
- The [AGENCY-REVIEW] cost figure ($2–$18 per repeated failure) — this is internal Agency financial data
- Claims about "average across all runs" — the effect averages out; only the hit-subset matters

**Action required:** Founder confirms: (a) cleared to use −68% on the landing page, (b) cleared to publish the case study (adapted, without [AGENCY-REVIEW] figure) as a blog post under a pseudonym (e.g., "an autonomous agent orchestrator").

### T2.3 — ~97% production recall hit rate
**Evidence:** `research/CASE_STUDY_AGENCY_2026-06-01.md`:  
> "~97% of meaningful runs now receive at least one relevant prior lesson at dispatch"

Same consent situation as T2.2. Can be shown as "production fleet" figure without naming Agency.

**Action:** Covered by D2b decision.

---

## Tier 3 — Needs verification before publishing

### T3.1 — 49x ingestion speed vs LightRAG [FLAG D4]
**Current status:** Mentioned in teardown as a "killer number buried in the site." Source document: `COMPETITIVE_ANALYSIS_LIGHTRAG_2026-06-04.md` (Agency private, not in my current access path).

**What I know:** The claim is directionally credible:
- LightRAG default pipeline: LLM graph extraction per document (seconds to minutes)
- pgmnemo `ingest()`: SQL constraint check + indexed INSERT (~milliseconds)
- The ratio depends on: corpus size, LightRAG config, hardware

**What I need before publishing:**
1. Exact methodology: what corpus size, what hardware, which LightRAG config?
2. Is there a benchmark script? Can a skeptical HN commenter reproduce this?
3. Is 49× the median or the worst-case for LightRAG?

**Risk if unchecked:** LightRAG's "fast local" mode (NanoVectorDB) skips the LLM graph extraction for some use cases. If we claim 49× against the full pipeline but a user compares to fast-local, the claim looks cherry-picked.

**Safe fallback copy (no freeze needed):**  
> "pgmnemo ingests via SQL INSERT — milliseconds. LightRAG builds a knowledge graph via LLM extraction — seconds to minutes per document batch. The gap is structural, not tunable."  

This copy is true and defensible without a specific multiplier.

### T3.2 — "Learns what actually worked" (outcome-learning claim)
**Status:** Feature shipped (v0.7.0 `reinforce()`). Claim is accurate.  
**Verification gap:** We have no external benchmark showing that confidence weighting from `reinforce()` meaningfully improves recall@K on a standard dataset. The Agency A/B measures turn reduction, not recall@K delta from reinforcement specifically.

**Safe use:** Present outcome-learning as a capability ("the memory grades itself from live outcomes") — not as a quantified retrieval quality improvement. Don't claim "X% better recall with reinforcement."

---

## Tier 4 — Do NOT use (fabricated or unverifiable)

| Claim | Why not |
|---|---|
| Any screenshot showing fake stars (e.g., "1.2K stars") | Not verified — only use live badge |
| "Enterprise customers" | No enterprise customers confirmed |
| "Used by 100+ teams" | No data for this |
| "Beats Mem0 on retrieval quality" | False or apples-to-oranges — Mem0 is SaaS RAG, not the same benchmark domain |
| "Best-in-class recall" | Only true in specific benchmarks with specific caveats |
| Any logo without written consent | Standard — no exceptions |
| Quotes attributed to named individuals without their consent | Standard |

---

## Proof asset action plan (priority order)

| Action | Owner | Unblocks | Priority |
|---|---|---|---|
| Reach out to agentplatform.ru for consent to name them | Founder | T2.1 — named adopter on site | P0 |
| Founder confirms −68% cleared for public use | Founder | T2.2, T2.3 — production stats on site | P0 |
| Founder confirms / sources 49x LightRAG claim | Founder | T3.1 — hero number in S6 | P0 |
| Pull live GitHub star count, PyPI installs | growth_lead (can do at publish time) | T1.1 — live badges | P1 |
| Adapt Agency case study for blog post (no [AGENCY-REVIEW] figure) | growth_lead | First content piece post-launch | P1 |
| Contact one more external user for a quote or mini-case-study | Founder + growth_lead | Named social proof beyond 1 | P2 |

---

*growth_lead (92) · 2026-06-05*
