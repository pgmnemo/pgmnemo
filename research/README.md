# pgmnemo — Research Archive

This folder is the **frozen research baseline** that informed the WG vote (5-0-0) on 2026-04-29
to spin pgmnemo out as a separate productized PostgreSQL extension.

> Source-of-record: these documents were authored under the prior `memory-svc` workstream
> (project_id=9, RES-MEM-001 / DESIGN-MEM-EXT-1/2). They are copied here verbatim so the
> pgmnemo repo / org has a self-contained provenance trail when the GitHub repo is
> initialised. **Do not edit in place** — for any updates create a new ADR / paper revision.

## Contents

| File | Origin | Purpose |
|------|--------|---------|
| `PAPER_v0.1.md` | `PAPER_DESIGN-MEM-001_v0.1.md` | Draft research paper (ICSE-SEIP / SIGMOD style) — system + eval design |
| `ADR_001_SUBSTRATE.md` | same name | ADR: PostgreSQL as memory substrate (vs. dedicated vector DB / graph DB) |
| `ADR_002_DATA_MODEL.md` | same name | ADR: 4-layer data model (working / episodic / semantic / archival) |
| `SPIKE_EMBED_BENCHMARK.md` | same name | Embeddings spike: bge-m3 vs alternatives, latency / recall trade-offs |
| `RESEARCH_TECH_FEASIBILITY.md` | `RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md` | EXT-1: PG extension feasibility (pgrx vs SQL-only, blockers) |
| `RESEARCH_COMMERCIAL.md` | `RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md` | EXT-2: competitive landscape, monetization variants, go-to-market |
| `SYNTHESIS_WG_RECOMMENDATION.md` | same name | WG synthesis + 5-0-0 vote with 4 conditions (the basis for `STRATEGY.md`) |

## How to use this archive

- **Reading order for new contributors:** `SYNTHESIS_WG_RECOMMENDATION.md` →
  `RESEARCH_COMMERCIAL.md` → `RESEARCH_TECH_FEASIBILITY.md` → `ADR_001_SUBSTRATE.md` →
  `ADR_002_DATA_MODEL.md` → `SPIKE_EMBED_BENCHMARK.md` → `PAPER_v0.1.md`.
- **For the WG conditions** (license=Apache-2.0, no LLM hard-dep, paper-first, bench gates):
  see `../STRATEGY.md` §3 — those four conditions came from this archive.
- **For the v0.2 paper revision** that the team is currently writing:
  see task 2117 (PAPER-MEM-EXT-V0.2) and the future
  `spec/v2/pgmnemo/PAPER_v0.2.md` once delivered.

## Provenance

```
spec/v2/memory-svc/PAPER_DESIGN-MEM-001_v0.1.md            → research/PAPER_v0.1.md
spec/v2/memory-svc/ADR_001_SUBSTRATE.md                    → research/ADR_001_SUBSTRATE.md
spec/v2/memory-svc/ADR_002_DATA_MODEL.md                   → research/ADR_002_DATA_MODEL.md
spec/v2/memory-svc/SPIKE_EMBED_BENCHMARK.md                → research/SPIKE_EMBED_BENCHMARK.md
spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-1_TECH_FEASIBILITY.md  → research/RESEARCH_TECH_FEASIBILITY.md
spec/v2/memory-svc/RESEARCH_DESIGN-MEM-EXT-2_COMMERCIAL.md → research/RESEARCH_COMMERCIAL.md
spec/v2/memory-svc/SYNTHESIS_DESIGN-MEM-EXT_WG_RECOMMENDATION.md  → research/SYNTHESIS_WG_RECOMMENDATION.md
```

Copied: 2026-04-29.
