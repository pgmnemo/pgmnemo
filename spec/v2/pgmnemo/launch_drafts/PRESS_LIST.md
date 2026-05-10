# Press & Outreach List

**Draft status:** Ready for founder review  
**Framing:** MAGMA-class implementation, not agentic-db alternative  
**Scores pending:** MAGMA-5 confirmation of 0.700 LoCoMo / 61.2% LongMemEval  

---

## Pitch template (email / DM)

**Subject:** pgmnemo — open-source PostgreSQL implementation of MAGMA multi-graph agent memory

Hi [Name],

I'm writing about pgmnemo, an open-source PostgreSQL extension that implements the multi-graph agent memory architecture from the MAGMA paper (arXiv:2601.03236v2).

**The problem pgmnemo solves:** Most agent memory systems use flat vector search. The MAGMA paper formalizes why this is insufficient — agent memory needs typed graph structure: causal derivation chains, temporal episode ordering, semantic abstraction hierarchies, and entity co-occurrence. pgmnemo implements all four as native Postgres objects with zero external dependencies.

**What makes it newsworthy:**
- First open-source PostgreSQL implementation of the MAGMA §3 edge taxonomy
- Benchmark anchor: 0.700 on LoCoMo (ACL 2024) / 61.2% on LongMemEval (MAGMA-5 confirmation pending)
- `CREATE EXTENSION pgmnemo;` — single-command install via PGXN, MIT license
- Graph traversal (MAGMA §4 adaptive policy) runs as native Postgres functions at ~3–8 ms query p50

**Angle options:**
1. *Technical:* MAGMA-spec implementation — how we built typed multi-graph memory inside Postgres
2. *Infrastructure:* Why agent memory belongs in your existing database, not a new service
3. *Open-source:* Implementing a formal ML memory spec as a Postgres extension

Happy to provide a technical brief, benchmark methodology details, or an interview. Demo available via `pgxn install pgmnemo` + provided SQL fixtures.

[Founder name]  
[GitHub link]

---

## Outreach list

### Tier 1 — Developer-focused publications

| Outlet | Contact / section | Angle | Notes |
|---|---|---|---|
| The Register | Developer section | Open-source Postgres tooling | Technical depth audience |
| InfoQ | Databases / AI | MAGMA implementation, benchmark methodology | Editor review process |
| Hacker News (Show HN) | Show HN post | See SHOW_HN.md | Self-submit |
| DevHunt | New tool listing | MAGMA-class agent memory | Simple listing form |
| Console.dev | Weekly picks | Open-source dev tool | curator@console.dev |

### Tier 2 — AI/ML newsletters

| Outlet | Contact / section | Angle | Notes |
|---|---|---|---|
| TLDR AI | Submissions | MAGMA implementation + benchmarks | tldr.tech/ai submissions |
| The Batch (deeplearning.ai) | Research spotlight | arXiv:2601.03236v2 implementation | Focus on MAGMA paper connection |
| Import AI (Jack Clark) | Open-source section | Typed memory graphs for agents | Focus on architectural novelty |
| Ahead of AI | Infrastructure section | Memory as graph, not vector store | Technical newsletter |
| Gradient Flow | Research → practice | MAGMA spec to Postgres implementation | O'Reilly affiliated |

### Tier 3 — Community channels (self-post)

| Channel | Post type | Notes |
|---|---|---|
| r/MachineLearning | Self-post | Link to arXiv:2601.03236v2 + implementation |
| r/LocalLLaMA | Self-post | Focus on local agent memory, no cloud deps |
| r/PostgreSQL | Self-post | Extension announcement, PGXN link |
| Lobsters | Submission | #postgres #ai #open-source tags |
| X / Twitter | Thread | See X.md |
| LinkedIn | Article | Founder byline, MAGMA framing |

### Tier 4 — Podcast outreach

| Podcast | Host | Angle | Format |
|---|---|---|---|
| Practical AI | Daniel Whitenack | MAGMA paper implementation, Postgres for agents | Guest interview |
| Software Unscripted | Richard Feldman | Systems design — graph memory in SQL | Technical deep-dive |
| The Changelog | Adam Stacoviak | Open-source release, MAGMA connection | "News" segment or guest |
| Postgres FM | Nikolay Samokhvalov | Postgres extension architecture | Core audience |

---

## Key facts for press

| Fact | Value | Caveat |
|---|---|---|
| MAGMA paper | arXiv:2601.03236v2 | Preprint, not peer-reviewed |
| LoCoMo score | 0.700 | Pending MAGMA-5 confirmation |
| LongMemEval score | 61.2% | Pending MAGMA-5 confirmation |
| LoCoMo metric | LLM-as-judge QA accuracy | Same metric as MAGMA paper |
| LongMemEval metric | QA accuracy, n=500 | bge-m3 embedder |
| Install | `pgxn install pgmnemo` | Requires pg_vector |
| License | MIT | Full open-source |
| Version | v0.2.1 (stable) / v0.3.0 (dev) | v0.3.0 completes MAGMA §3 |
| Postgres compatibility | 14–17 | Tested on 15/16 |

---

## Embargo / timing notes

- Do not publish benchmark numbers until MAGMA-5 score confirmation is complete
- Coordinate Show HN / PH / press on the same day where possible (cross-link boost)
- v0.3.0 release should ship before or simultaneously with press push to have MAGMA §3 schema in stable release
- PGXN v0.2.1 listing is live — mention it as available-now; v0.3.0 as "in active development"
