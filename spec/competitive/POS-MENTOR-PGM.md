# POS-MENTOR: External Consultant Triage — pgmnemo

**Date:** 2026-05-16
**Task:** PGMNEMO-WG-STRAT-260517
**Role:** External startup mentor — independent of Agency strategy
**Input:** CROSS_CUTTING_SYNTHESIS_2026-05-16.md + 4 competitor deep-dives + ROADMAP v2 + README + STRAT_SESSION_2026-05-10

---

## 1. Recommendation Triage (8 items from CROSS_CUTTING_SYNTHESIS §"Новые рекомендации")

| # | Founder Priority | Mentor Verdict | Time-to-Signal | Owner | Fractional Cost |
|---|---|---|---|---|---|
| 1 — Fix POSITIONING.md (MIT/HNSW/bundled) | P0 | **AGREE P0** | <24 h | any contributor | 30 min |
| 2 — Sharpen tagline: "write-time enforcement at the RLS layer" | P0 | **AGREE P0** | 30 days | growth_lead | 1 h |
| 3 — Cost-per-1K-memories comparison | P1 | **AGREE P1** | 30 days | growth_lead | 2 h |
| 4 — AWS Agent SDK adapter research | P1 | **DOWNGRADE to P2** | 90 days | chief_architect | 3 days research cap |
| 5 — `pgpm install pgmnemo` (distribution parity) | P1 | **AGREE P1** | 30 days | chief_architect | 3–5 days |
| 6 — Bitemporality v0.3 (two columns + trigger) | P2 | **AGREE P2** | 180 days | chief_architect | 1 week |
| 7 — Honest reproducible benchmark card | P2 | **UPGRADE to P1** | 60 days | research_supervisor | 2 weeks |
| 8 — Letta citation as positioning anchor | P2 | **AGREE P2** | 30 days | growth_lead | 30 min |

**Disagreements, stated flatly:**

**Rec #4 (AWS adapter) → P2, not P1.** Mem0's AWS Agent SDK position may be contractual exclusivity, not a default that a plugin API can override. Spending 1–2 weeks researching a blocked door is burn. Cap this at 3 days: (a) read the public AWS Agent SDK plugin spec, (b) confirm whether there is any official memory provider extension point, (c) report back. If there is no extension API, kill the track entirely.

**Rec #7 (benchmark card) → P1, not P2.** The README already publishes honest numbers. The benchmark card is not marketing fluff — it is the ONLY artifact that converts "interesting project" to "we trust this in production." Agency already provides corpus data (recall@10=0.5745, N=1060). The card writes itself from data already in-hand. Delay costs credibility; the 2-week effort is low relative to impact. The ICSE-SEIP citation in README signals this is already the strategy — execute it.

---

## 2. Market Positioning Audit

**What README currently claims (v0.4.1 state):**

- "Write-time provenance gate — none of Pinecone, Letta, Mem0, or Zep have this" → **confirmed accurate** by 4 competitor deep-dives
- "No new service — `CREATE EXTENSION`" → **confirmed accurate, a real differentiator**
- "Hybrid recall in-database" → **confirmed, HNSW + BM25 + recency in one SQL call**
- LongMemEval recall@10=0.9334 below BM25 (0.982) → **disclosed honestly**, no overclaim

**Underclaims (what the README does NOT say but should):**

1. **The exact architectural location is missing.** "Provenance gate" is abstract. "Write-time enforcement at the RLS layer" is concrete and falsifiable. Letta runs Postgres at the app layer; their memory writes bypass RLS entirely. This is the gap. The current README does not make this comparison explicit.

2. **Zero LLM cost per write is never stated.** Zep and Mem0 run LLM extraction pipelines on every write. pgmnemo's `ingest()` is a SQL call with no model inference. This is a cost and latency advantage that no current public-facing content quantifies.

3. **Constructive AgenticDB is absent from all comparison tables.** The README comparison has "Generic Vector DB" and "Cloud Memory API" — neither matches Constructive's actual profile (MIT, pgvector/HNSW, bundled embeddings, closest architectural peer). This makes the table look strawmanned against weaker alternatives.

**Overclaims (what the README implies that requires caveats):**

1. The comparison table implies pgmnemo beats "Cloud Memory API" on all dimensions. Mem0's 186M API calls/month means their reliability SLA is real-world tested at scale that pgmnemo's 1 production user cannot match. Do not imply otherwise.

2. The LongMemEval badge (0.9334, yellow) is displayed before the text that explains it loses to BM25. Most visitors read badges, not prose. The badge is technically accurate but the ordering creates a false impression that it is competitive with BM25 at a glance.

---

## 3. The "No Monetisation" Question

**The four paths:**

- **Paid SaaS hosted offering** — requires ops team, fights Mem0 and Zep on their home ground, contradicts "no new service" positioning which is core brand.
- **Paid commercial support** — works at scale (Elastic, Timescale do this), but requires ≥10 enterprise contracts to be meaningful. Not viable at 1 production user.
- **Enterprise extension feature gating** (dual-license: Apache-2 core + commercial license for audit-export, multi-cluster provenance dashboard) — competes on the exact feature (provenance compliance) where pgmnemo already has moat.
- **Pure OSS reputation play** — founder credibility, ICSE-SEIP paper, consulting → speaking → acquisition surface.

**Verdict: Pure OSS reputation play now, enterprise feature gating at v1.0.**

Rationale: at 1 production user, any monetization motion burns community trust faster than it generates ARR. The ICSE-SEIP submission is already in the bibtex — execute it. The provenance gate is a compliance feature; compliance buyers pay for audit-grade guarantees, not for the extension itself. At v1.0 (≥3 external adopters with case studies per ROADMAP), dual-license enterprise features — specifically an "audit-mode" that exports provenance logs to an external SIEM — is a defensible revenue wedge. Compliance teams need a paper trail; the gate creates the trail; exporting it is enterprise value.

Do NOT start a managed SaaS offering before v1.0. It splits engineering focus and the "no new service" positioning is a real trust signal with the developer ICP. Break it only if you have a paying enterprise customer requesting it.

---

## 4. Anthropic-as-Strategic-Actor

**Question: will Anthropic ship a memory service that absorbs pgmnemo's niche?**

**Verdict: No — and the structural reason is durable.**

Claude.ai already has consumer memory (profile-based facts). Anthropic's trajectory is: build models and research, publish MCP as an open standard, let the ecosystem build tooling on top. They have no incentive to become a Postgres infrastructure vendor — it is not their competence and it would compete with their ecosystem partners (Mem0 is already AWS Agent SDK exclusive, a partnership surface Anthropic benefits from keeping healthy).

More precisely: pgmnemo's moat is write-time enforcement AT THE RLS LAYER inside a Postgres extension. A cloud API — even one built by Anthropic — cannot replicate this. It would require Anthropic to ship a managed Postgres service with a custom extension pre-loaded, which puts them in direct competition with AWS RDS and Azure Database for PostgreSQL. That is not their business.

**Defensible positioning IF Anthropic ships a memory tool anyway:** pgmnemo's claim does not depend on being the only memory tool. It depends on being the only memory tool whose provenance enforcement is architecturally impossible to bypass from the application layer. A cloud API can be called incorrectly. A Postgres extension with `gate_strict = enforce` at the RLS layer cannot be silently circumvented. This is a category difference, not a feature difference.

The one genuine risk from Anthropic: if they extend MCP to include a first-class memory capability spec, and if that spec does not include write-time provenance as a primitive, pgmnemo's gate becomes a non-standard extension of the spec. Mitigation: submit the provenance gate semantics as a proposed MCP extension now, before the spec solidifies.

---

## 5. Forced-Decision Item — Answer by 2026-05-23

**Decision: Does pgmnemo start a managed hosting waitlist in 2026, or commit to extension-only through v1.0?**

This is not a feature decision. It is a positioning lock-in. You must answer it before Graphiti ships its pgvector driver (est. Q3 2026), because:

- If pgmnemo is extension-only when Graphiti lands, developers who want a managed Postgres-native memory layer will default to Zep (managed Graphiti) because it has a hosted option and pgmnemo does not.
- If pgmnemo opens a waitlist now (zero engineering cost, one landing page form), you capture those developers' email before Graphiti lands and can convert them to the hosted offering later.
- If pgmnemo commits to extension-only through v1.0, the "no new service" positioning is unambiguous and community trust is maximized, but the managed-Zep threat is unaddressed.

Both choices are defensible. Neither is reversible without trust cost. Choose one and commit.

**Mentor lean:** extension-only through v1.0, but open the waitlist form now. The form costs nothing and costs no positioning — it signals demand without committing to infrastructure. If the waitlist hits 50 signups before Q3 2026, revisit.
