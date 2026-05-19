# Competitive Tracking — pgmnemo vs Agent Memory Market
## Weekly update log (growth_lead owned)

**Status:** Template + baseline (2026-05-19)  
**Update cadence:** Weekly (Mondays, 9am ET)  
**Audience:** founder, product team  
**Purpose:** Detect market moves, validate Option D moat timeline, trigger strategy pivots if needed  

---

## Competitive Landscape (Baseline 2026-05-19)

### Direct Competitors

| System | Positioning | Moat | Install | Status (as of 2026-05-19) |
|--------|-----------|------|---------|--------------------------|
| **Mem0** | LLM-coached memory extraction + consolidation | Entity-graph + proprietary cloud scale | SaaS API | 186M+ API calls/month; 80K+ registered developers; acquired by Sequoia (Series A funding) |
| **Zep / Graphiti** | Bitemporal knowledge graph + temporal reasoning | Neo4j + Zep Cloud | Self-hosted (Graphiti) or SaaS (Zep) | Enterprise customers; ParadeDB-style hybrid model (open-source Graphiti + managed Zep Cloud) |
| **Letta** | MemGPT variant + long-context reasoning | Production scale (1M+ agents on Aurora) | Self-hosted service or Letta Cloud | MIT license; Letta Cloud is managed offering; strong developer community |
| **Constructive AgenticDB** | Schema-only Postgres embedding + vector index | Simplicity + Postgres-native | `CREATE EXTENSION` (MIT license) | **JUST LAUNCHED 2026-04-28** (HIGH THREAT); no provenance enforcement mentioned |
| **pgmnemo** | Write-time provenance enforcement + citation-grounded agents | Architectural (RLS-enforced gate at DB layer) | `CREATE EXTENSION` (Apache 2.0) | v0.4.1 shipped; v0.5.0 pending (blockers); public launch planned T-7 (founder approval required) |

### Indirect Competitors / Alternatives

| System | What they do | Why they matter |
|--------|-------------|-----------------|
| **pgvector standalone** | Vector indexing in Postgres | Simplest option for orgs that want to DIY agent memory (no abstraction) |
| **Pinecone / Weaviate / QdrantCloud** | Vector DB as a service | Higher latency but proven at scale; appeal for teams without Postgres expertise |
| **Neo4j** | Graph DB as a service | Temporal reasoning use cases; Zep uses it |
| **Redis + RedisJSON** | In-memory vector + JSON storage | Low latency; appeal for session-scoped memory; not durable |
| **Chroma / LlamaIndex** | Vector RAG libraries | Low-code option for teams using Python frameworks; no persistence abstraction |

---

## Key Metrics to Track

### pgmnemo (Our Moat Position)

| Metric | Baseline (2026-05-19) | Target (T+90) | Notes |
|--------|----------------------|----------------|-------|
| **GitHub stars** | TBD (pre-public) | 500+ | Signals market resonance; threshold for series A conversation |
| **External production adopters (public)** | 0 | 2+ | Credibility signal; required for "proven in regulated domains" |
| **Monthly commits (active development)** | ~10/month (founder + agents) | 10+/month | Shows maintenance velocity |
| **Community issues (open rate)** | TBD (pre-public) | <48h response SLA | Team engagement signal |
| **Open PRs (external contributor)** | 0 | 3+ | Ecosystem health |
| **Benchmark: LoCoMo recall@10 turn-level** | 0.302 (vs DRAGON 0.225) | No change (v0.5.0) | Not primary metric; MAGMA graph scoring disabled pending v0.3 release |
| **Benchmark: LongMemEval recall@10** | 0.933 (vs BM25 0.982) | 0.960+ (v0.4 hybrid) | Primary roadmap item; honest acknowledgement of baseline |
| **Write-time enforcement regression tests** | <10 (informal) | >50 (formal suite) | Our biggest moat; must not break |

### Constructive AgenticDB (Highest Threat)

| Metric | Baseline (2026-05-19) | Threat level | Why it matters |
|--------|----------------------|-------------|-----------------|
| **GitHub stars** | ~50 (just launched 2026-04-28) | MONITOR: If >500 by T+90, market moving faster than projected | Indicates Postgres extension model resonates |
| **Announces RLS-enforced provenance gate** | NOT YET | RED FLAG: If announced by T+90, moat compressed | This would neutralize our unique claim |
| **Launches seed round / commercial backing** | Likely | MEDIUM THREAT | Well-funded competitor can accelerate feature parity |
| **Community adoption signals** | Early (just launched) | WATCH WEEKLY | If we see "Constructive vs pgmnemo" discussions, moat is under pressure |

### Mem0 (Scale Threat, Not Positioning Threat)

| Metric | Baseline (2026-05-19) | Threat level | Why it matters |
|--------|----------------------|-------------|-----------------|
| **Launches Postgres extension** | NOT PLANNED (proprietary cloud focus) | YELLOW: If announced, increases distribution reach | Would fragment Mem0 TAM but not address provenance |
| **Adds write-time provenance gate** | NOT DOCUMENTED | YELLOW: If added, reduces our unique claim | Unlikely (conflicts with LLM-coach model) |
| **Market share in general agent memory** | 186M+ API calls/month (~60% of market) | MONITOR: Growth rate | Our strategy is NOT to compete here; document if TAM shrinks |

### Zep / Graphiti (Temporal Threat)

| Metric | Baseline (2026-05-19) | Threat level | Why it matters |
|--------|----------------------|-------------|-----------------|
| **Adds write-time provenance gate** | NOT DOCUMENTED | MEDIUM: If added, reduces moat | Technically feasible in Neo4j via RLS equivalents |
| **Launches OSS schema-only option (like Constructive)** | UNLIKELY (Neo4j dependency) | YELLOW: If they pivot to Postgres, direct competition | Current Neo4j lock-in is their constraint |

---

## Weekly Tracking Template (Mondays)

Copy this template and fill in each Monday:

```
# Weekly Competitive Tracking — Week of [DATE]

## Changes This Week

### Constructive AgenticDB
- [ ] Any new GitHub releases or announcements?
- [ ] Star count: _____ (was: _____ last week)
- [ ] Any RLS-provenance-gate features mentioned?
- [ ] Funding announcement? Hiring? New leadership?
- [ ] Notable community discussion or comparison posts?

### Mem0
- [ ] API call volume (if publicly disclosed): _____ (was: _____ last week)
- [ ] Any new product features affecting agent memory?
- [ ] Seed/Series A updates?
- [ ] Community sentiment shift (HN/Reddit)?

### Zep / Graphiti
- [ ] New temporal reasoning features or benchmarks?
- [ ] Postgres support mentioned anywhere?
- [ ] Enterprise customer wins announced?

### pgmnemo (Our Moat)
- [ ] GitHub stars: _____ (was: _____ last week)
- [ ] Open issues trending toward which topics?
- [ ] Any external adopter conversations?
- [ ] v0.5.0 blocker status?

## Moat Health Assessment

| Dimension | Status | Evidence | Action |
|-----------|--------|----------|--------|
| **Architectural uniqueness of write-time provenance gate** | 🟢 Green / 🟡 Yellow / 🔴 Red | Constructive AgenticDB has NOT announced RLS gate | Monitor weekly; if announced, escalate to founder |
| **Regulatory TAM (healthcare, legal, compliance)** | 🟢 / 🟡 / 🔴 | TAM ~$650M/yr (stable as of 2026-05-19) | Validate with 3 domain conversations by T+30 |
| **Postgres-native install advantage** | 🟢 / 🟡 / 🔴 | Both pgmnemo and Constructive are `CREATE EXTENSION`; neither has advantage | N/A (table stakes) |
| **Benchmark honesty positioning** | 🟢 / 🟡 / 🔴 | We own "honest about BM25 beating us"; Constructive doesn't publish benchmarks | Maintain this messaging |

## Trigger Conditions for Strategy Pivot

If ANY of the following occur, escalate to founder for strategy review:

1. **Constructive AgenticDB announces RLS-enforced write-time provenance gate** → Moat compressed; pivot to different differentiator
2. **Mem0 launches Postgres extension option** → Distribution advantage reduced; accelerate our public launch
3. **pgmnemo stars <100 by T+30 despite clean launch** → ICP validation failed; pivot to code-agents or revisit positioning
4. **>3 healthcare/legal adopters say "no, still too risky by T+30** → Regulatory TAM may be smaller than projected; pivot to code-agents or research labs

## Notes

[Free-form observations, unexpected market signals, founder feedback, etc.]

---
```

---

## Historical Baseline (2026-05-19)

**Constructed from:**
- POSITIONING.md (2026-05-18)
- COMPETITIVE_REALITY.md (2026-05-13)
- Constructive AgenticDB GitHub (launched 2026-04-28)
- Mem0 public numbers (186M+ API calls/month as of 2026-05-19)
- Zep / Graphiti community discussions (2026-04 - 2026-05)

**Growth lead baseline interpretation:**
- Option D moat is solid for 18–24 months *unless* Constructive AgenticDB adds RLS enforcement
- Mem0 is the scale threat (186M calls/month) but not the positioning threat (doesn't target regulated domains)
- Zep is a partial threat only if they pivot to Postgres + RLS (unlikely due to Neo4j investment)
- Market is moving **fast** (Constructive launched 2026-04-28; we need to ship our launch by T+7 to stay ahead)

---

## First Update (Growth Lead Owned)

Growth_lead will post first weekly update on **Monday 2026-05-27** (assuming founder approval and v0.5.0 clean launch).

Format: Reply to this document with a dated section (## Week of 2026-05-27) following the template above.

---

**Document maintained by:** growth_lead  
**Review cadence:** Weekly (Mondays); escalate to founder if trigger conditions met  
**Last updated:** 2026-05-19 (baseline)
