# SYNTHESIS — pgmnemo WG-STRAT-260517

**Doc:** spec/competitive/SYNTHESIS_PGMNEMO_2026-05-17.md
**Date:** 2026-05-17
**TL:** Karpov (ratification role)
**Status:** RATIFIED
**Classification:** INTERNAL — do not publish externally

---

## §1 Quorum

| Position | Author | Task ID | Status |
|---|---|---|---|
| POS-CA-PGM | Chief Architect | 6228 | ✅ DONE |
| POS-GROWTH-PGM | growth_lead | 6229 | ✅ DONE |
| POS-MENTOR-PGM | External Mentor | 6230 | ✅ DONE |
| POS-RS-PGM | research_supervisor | 6231 | ✅ DONE |

4/4 positions submitted. Dependency guard verified via `tasks WHERE id IN (6228,6229,6230,6231)` — all DONE. Founder synthesis (CROSS_CUTTING_SYNTHESIS_2026-05-16) served as pre-read for all four positions. No position was submitted without reading the companion synthesis.

---

## §2 Convergent Verdicts (≥3 positions agree)

**C1 — Provenance gate moat holds (unanimous, 4/4)**
All four positions confirm: no competitor (Mem0, Zep/Graphiti, Letta, Constructive AgenticDB) has an equivalent write-time provenance gate. The mechanism — `gate_strict` GUC + RLS policy evaluated inside the Postgres executor — is architecturally impossible to replicate at the application layer or via a cloud API.
*Evidence:* CA §1-3 (per-competitor technical analysis); MENTOR §2 ("confirmed accurate by 4 competitor deep-dives"); RS §5.2 (falsification rule with security audit trigger); CROSS_CUTTING §"Подтверждённое."

**C2 — "Postgres-native" is no longer differentiating; tagline must change (3/4: CA, GROWTH, MENTOR)**
Letta runs Aurora in production at Bilt (1M+ agents). Constructive AgenticDB ships "The Postgres Memory Layer for AI Agents." Both arrived before pgmnemo had a public tagline. The precise differentiating claim is now "write-time enforcement at the RLS layer."
*Evidence:* CA §3 ("Postgres-enforced, not Postgres-native"); GROWTH §1 (tagline problem statement); MENTOR §2 (underclaim #1 — "architectural location is missing").

**C3 — POSITIONING.md Constructive AgenticDB facts are factually wrong — P0 immediate fix (3/4: CA, GROWTH, MENTOR)**
License: MIT (not Apache-2.0). Vector index: HNSW via pgvector (not "none"). Embeddings: bundled Ollama + nomic-embed-text (not user-supplied). Errors are trivially fact-checked and undermine all adjacent claims.
*Evidence:* CA §0 (P0 correction block, first item before all else); GROWTH §2 (MAGMA note + corrected facts); MENTOR §1 (AGREE P0, <24h).

**C4 — Rec #5 (`pgpm install pgmnemo`) is P1 (3/4: CA, GROWTH, MENTOR)**
Constructive AgenticDB controls pgpm channel discovery. Absence from pgpm means Constructive owns the channel by default. Pure SQL packaging: 3–5 days effort. Manifest + publish + smoke test.
*Evidence:* CA §5 (Rec #5, "VERY HIGH" feasibility); GROWTH §5 (channel priority matrix, P1); MENTOR §1 (AGREE P1).

**C5 — Rec #3 (cost-per-1K-memories comparison) is P1 (3/4: GROWTH, MENTOR; CA implicit)**
pgmnemo's $0 LLM cost per write vs Mem0's ~$0.17 and Zep's ~$0.36/1K writes is quantifiable and defensible. The table is already drafted (GROWTH §3). Needs one pricing validation pass before publishing.
*Evidence:* GROWTH §3 (full cost table with footnotes); MENTOR §1 (AGREE P1, "2h" effort).

**C6 — Rec #8 (Letta citation "MemGPT showed agents need memory; pgmnemo shows memory needs a gate") is P2 (3/4: GROWTH, MENTOR, CA all reference it)**
Frames Letta as category-validator while claiming the gate primitive. Risk accepted: their lead (22.7K stars) is already undeniable, and denying it costs credibility. Mitigation: ship now while the technical gap is unambiguous.
*Evidence:* GROWTH §4 (surface-by-surface deployment plan); MENTOR §1 (AGREE P2, "30 min"); CA §3 (uses the phrase verbatim).

**C7 — No managed SaaS before v1.0 (MENTOR explicit; ROADMAP v2 implicit)**
"No new service" is a real trust signal with the developer ICP. Managed hosting splits engineering and contradicts positioning. Revisit at v1.0 (≥3 external adopters with case studies).
*Evidence:* MENTOR §3; ROADMAP v2 "What v1.0 does NOT promise."

---

## §3 Divergent Verdicts

### D1 — Rec #4 (AWS Agent SDK adapter): P1 vs P2

| Position | Label | Core argument |
|---|---|---|
| Founder synthesis | P1 | Meta-distribution risk; pgmnemo ICP overlaps heavily with AWS RDS/Aurora users |
| CA | P1 with research gate | Pattern A Lambda adapter is feasible; sole unknown is whether SDK memory provider interface is public; ~30% contractual lock risk |
| GROWTH | P1 | Anthropic MCP Registry as parallel counter-channel |
| MENTOR | **P2 (downgrade)** | Contractual exclusivity may block the entire track; cap research at 3 days before committing to build |

**Conflict with founder synthesis:** Founder and CA label this P1; MENTOR downgrades to P2. Recorded per task constraint (do not silently override).

**Deciding rule:** MENTOR's 3-day hard cap is compatible with CA's "research-then-build" gate; the conflict is label, not substance. **Synthesis verdict: P1-gated research spike — 3-day hard cap, due 2026-05-30. WG decision gate after research: if AWS SDK interface is public and pluggable → escalate to P1 build track (Pattern A Lambda adapter + CDK construct) targeting v0.6.0; if contractually locked → kill the AWS track and redirect slot to Anthropic MCP Registry (P1, execute regardless).** The "P1" label covers the research decision only; the build commitment is gated.

### D2 — Rec #7 (Benchmark card): P2 vs P1

| Position | Label | Core argument |
|---|---|---|
| Founder synthesis | P2 | Lower urgency vs distribution and positioning moves |
| MENTOR | **P1 (upgrade)** | Converts "interesting project" to "trusted in production"; 2-week effort, data already in-hand |
| RS | Full design spec (8-cell, pre-registered protocol, CI auto-publish) | Execution-ready |
| CA | Not addressed | — |

**Deciding rule:** RS has a complete execution spec ready (8-cell design, replication scripts, pre-registration protocol committed before runs, CI release integration). MENTOR's credibility argument is well-evidenced — Mem0/Zep benchmark integrity disputes (HN 44883133) are a real trust cost that pgmnemo can differentiate on. Unambiguous execution path. **Synthesis verdict: Upgrade Rec #7 to P1. Target: benchmark card v0 published pre-v0.6.0 tag (by 2026-07-15). research_supervisor owns execution per RS spec.**

### D3 — Managed hosting waitlist (MENTOR only; no other positions address)

MENTOR §5 raises as a forced decision: open a zero-cost waitlist form now vs commit extension-only through v1.0. No other position addresses this. **Not resolved by this synthesis — carried to §8 as founder forced-decision item.**

---

## §4 8-Recommendation Triage

| # | Recommendation | Final Priority | Owner | Due Date | Release |
|---|---|---|---|---|---|
| 1 | Fix POSITIONING.md (MIT/HNSW/bundled Ollama) | **P0** | growth_lead | 2026-05-17 ✅ this commit | v0.4.1 |
| 2 | Sharpen tagline → Candidate A | **P0** | growth_lead | 2026-05-17 ✅ this commit | v0.4.1 |
| 3 | Cost-per-1K-memories comparison (pricing-validated, public) | **P1** | growth_lead | 2026-05-30 | v0.4.1 |
| 4 | AWS Agent SDK — 3-day research spike (hard cap); build decision gated on verdict | **P1-gated** | chief_architect | 2026-05-30 (verdict) | build: v0.6.0 |
| 5 | `pgpm install pgmnemo` — distribution channel parity | **P1** | chief_architect | 2026-08-15 | v0.6.0 |
| 6 | Bitemporality (`t_valid_from`/`t_valid_to` + `mem.as_of()`) — H-07 | **P2** | chief_architect | 2026-06-20 | v0.5.0 |
| 7 | Honest reproducible benchmark card v0 (RS 8-cell spec) | **P1** *(upgraded from P2)* | research_supervisor | 2026-07-15 | pre-v0.6.0 |
| 8 | Letta citation in README §"Why this exists" + POSITIONING.md | **P2** | growth_lead | 2026-05-30 | v0.4.1 |

**P0 note:** Rec #1 and #2 are delivered in this commit (POSITIONING.md created, ROADMAP.md updated). No separate task required.

---

## §5 3-Threat Response Verdicts

### T1 — Mem0 as AWS Agent SDK Exclusive Memory Provider

**Verdict: Counter-channel with 3-day research gate. Do not assume the door is open; do not assume it is locked.**

**Actions (ordered):**
1. **Regardless of AWS research:** wrap pgmnemo as an Anthropic MCP server (HTTP wrapper on `ingest()`/`recall_lessons()` SQL API; 1-2 days; chief_architect). Submit to Anthropic MCP Registry when available. Add MCP install path to README.
2. **Research spike (3-day hard cap, due 2026-05-30, chief_architect):** read AWS Agent SDK public spec; confirm whether memory provider interface exposes a plugin/registration API. Report verdict to WG.
3. **If pluggable:** build Pattern A Lambda adapter (~5 days) + CDK L3 construct (~3-4 days) for v0.6.0.
4. **If contractually locked:** kill AWS track; redirect build slot to one additional framework adapter or pgpm publish.
5. **PGXN description:** update to Candidate A tagline now (growth_lead, trivial).

**What we do not do:** spend >3 days researching a potentially blocked door.

### T2 — Graphiti pgvector Driver (one quarter away)

**Verdict: Monitor + publish bitemporality moat. No feature parity race required.**

**Actions:**
1. **GitHub watch:** set PR filter on `getzep/graphiti` for "postgres" or "pgvector". Assign: chief_architect. A merged pgvector driver is a P0 strategic event → re-evaluation memo within 7 days.
2. **Bitemporality (v0.5.0, H-07):** `t_valid_from`/`t_valid_to` + trigger that sets `t_valid_to = NOW()` on conflicting write + `mem.as_of(ts)` view. DB-level trigger-based resolution vs Graphiti's LLM-detected contradiction resolution — faster, cheaper, deterministic.
3. **Maintain narrative explicitly:** POSITIONING.md competitor matrix already captures "pre-write veto vs descriptive provenance" gap. Even with a pgvector backend, Graphiti's write path is permissive at the application layer. RLS enforcement does not exist.

**What we do not do:** build Graphiti graph feature parity. The moat is architectural, not feature-list.

### T3 — Letta Aurora in Production (Bilt, 1M+ agents)

**Verdict: No defensive pivot. Reframe Letta as category-validator.**

**Actions:**
1. **Accept the concession:** "Postgres-native" is surrendered. Letta and Constructive already own it. Do not use it as a lead claim.
2. **Claim the precise position:** "Write-time enforcement at the RLS layer" (CA §3) — Letta stores agent memory at the application layer; their memory writes bypass RLS entirely. This is the gap. The tagline change (Rec #2) executes this.
3. **Deploy Letta citation:** "MemGPT showed agents need memory; pgmnemo shows memory needs a gate." README §"Why this exists" (Rec #8) and POSITIONING.md wedge statement closing sentence.
4. **Scale honesty:** pgmnemo has 1 production user (founder + early adopter). Letta has 1M+ agents at Bilt. Do not imply scale equivalence. The provenance gate claim is architectural, not operational.

---

## §6 Tagline Winner

**Winner: Candidate A — "The write-time gate for agent memory."**

| Candidate | Text | Decision |
|---|---|---|
| **A (WINNER)** | "The write-time gate for agent memory." | Primary tagline — POSITIONING.md, README hero, PGXN description |
| B | "Agent memory enforced at write time, not logged after." | Pitch decks and conference talks only |
| C | "One Postgres extension. Write-time provenance. No extra service." | Second line of README hero / PGXN description |

**Rationale for A:**
- GROWTH's explicit recommendation; 7 words; falsifiable
- Does not claim "Postgres-native" (correctly surrendered)
- "Gate" is the single confirmed differentiator across all 4 positions
- Requires explanatory sub-headline: *"Every `ingest()` call is verified against source provenance before the row commits."*
- CA, GROWTH, MENTOR all use "gate" as the central framing concept

**Why B is not primary:** picks a jab at Zep's provenance model; requires the team to defend head-to-head in public.
**Why C is not primary:** "No extra service" is defensive framing; positions pgmnemo as commodity extension, not category primitive.

---

## §7 ROADMAP Additions/Changes Applied in Deliverable #3

The following diff was applied to ROADMAP.md:

1. **Added §"Competitive response (2026-05-17)"** subsection in Strategic frame — names the 3 active threats and synthesis verdict per threat in 1-2 sentences each.

2. **v0.4.1** — added "Competitive response items" sub-section:
   - Rec #1/2: POSITIONING.md corrected + tagline updated (P0 — done in this commit)
   - Rec #3: cost-per-1K-memories table validated + published (P1, growth_lead, due 2026-05-30)
   - Rec #8: Letta citation added to README §"Why this exists" (P2, growth_lead, due 2026-05-30)
   - Anthropic MCP server wrapper (P1, chief_architect, 1-2 days; do regardless of AWS research)

3. **v0.5.0** — added "Competitive response items" sub-section:
   - Rec #6: Bitemporality primitive H-07 (`t_valid_from`/`t_valid_to` + `mem.as_of()`) — P2, chief_architect

4. **v0.6.0** — added "Competitive response items" sub-section:
   - Rec #5: `pgpm install pgmnemo` (P1, chief_architect)
   - Rec #4: AWS Agent SDK Lambda adapter — gated on May-30 research verdict (P1-gated, chief_architect)
   - Rec #7: Benchmark card v0 publication — target pre-v0.6.0 by 2026-07-15 (P1, research_supervisor)

**All Agency RFC items (R1-R10) preserved unchanged per constraint.**

---

## §8 Forced-Decision Items for pgmnemo Founder

Carried forward from POS-MENTOR §5. These are positioning lock-ins, not feature decisions. WG cannot ratify them; founder must decide.

**Decision 1 — Managed hosting waitlist (due: 2026-05-23)**
Does pgmnemo open a managed hosting waitlist before Graphiti's pgvector driver merges (est. Q3 2026), or commit to extension-only through v1.0?

- Extension-only: unambiguous "no new service" positioning; maximum community trust; managed-Zep threat unaddressed.
- Waitlist now (zero engineering cost, one landing page form): captures demand signal before Graphiti lands; reversible to hosted offering if waitlist hits ≥50 signups before Q3 2026.
- MENTOR lean: extension-only through v1.0, but open the waitlist form. **Both choices are defensible. Neither is reversible without trust cost. Choose one and commit.**

**Decision 2 — AWS Agent SDK track: build or kill (due: 2026-05-30)**
After chief_architect delivers 3-day research verdict, founder must ratify build or kill. WG is informed. No vote required — founder unilateral.

**Decision 3 — Dual-license enterprise feature gating: when (before v1.0 scope lock)**
MENTOR recommends dual-license at v1.0 (≥3 external adopters): Apache-2.0 core + commercial license for audit-mode provenance log export to SIEM. Founder decides if this is v1.0 add-on or deferred. Roadmap-change policy applies (cross-release pivot requires WG vote 3/5 + customer-signal citation).

---

*Classification: INTERNAL. Authored by TL Karpov under WG-STRAT-260517. Not for public distribution. Verbatim competitor references sourced from deep-dive reports dated 2026-05-16.*
