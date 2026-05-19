# SYNTHESIS — pgmnemo WG-VC-260517

**Doc:** spec/competitive/SYNTHESIS_VC_PGMNEMO_2026-05-17.md
**Date:** 2026-05-17
**Synthesizer:** TL Karpov (manual ratify — agency-api down due to v3 cutover SQLAlchemy `metadata` reserved-attribute bug at executive_cli/models.py:729)
**Status:** **RATIFIED — D1/D2/D3 VERDICTS LOCKED**
**Classification:** INTERNAL — do not distribute to investors without revision

> ⚠ **Review-gap flag.** This synthesis was authored by TL Karpov (operational/technical TL role)
> because agency-api was down and orchestrator could not dispatch a domain-correct RATIFY agent.
> Startup positioning + VC fundability is **NOT Karpov's zone of authority** — it belongs to
> startup_mentor (POS-VC author), growth_lead (POS-MARKET author), and product_owner
> (POS-WEDGE author). This document mostly tabulates their convergences; their judgment is the
> actual signal.
>
> **Before treating any verdict here as binding:** spawn a peer-review task for startup_mentor
> + growth_lead once agency-api is restored (incident:
> `/Users/gaidabura/Agentura-v2/spec/v2/INCIDENT_V3_CUTOVER_METADATA_RESERVED_2026-05-17.md`).
> Specifically: D1 tagline winner, D2 timing (track A vs wait), D3 TAM number — any of these
> may need revision by domain owners.

---

## §1 Quorum

| Position | Author (assignee) | Task ID | Status |
|---|---|---|---|
| POS-VC-PGM | startup_mentor as VC consultant | 6312 | ✅ DONE (TL-rescued from worktree zombie) |
| POS-WEDGE-PGM | product_owner | 6313 | ✅ DONE (TL-rescued) |
| POS-MARKET-PGM | growth_lead v2 | 6314 | ✅ DONE (TL-rescued) |
| POS-DEFENSE-PGM | chief_architect v2 | 6315 | ✅ DONE (TL-rescued) |
| POS-DATA-PGM | principal_investigator | 6316 | ✅ DONE (TL-rescued) |
| EA-FETCH (Sheets) | executive_assistant | 6311 | ✅ DONE (OAuth failed via MCP; TL fetched via Chrome MCP, commit 8c44419) |

5/5 positions submitted. Dependency guard verified. Synthesis methodology: convergent verdicts (≥3 agree) → C1–C7; divergent verdicts with deciding rules → D1–D3; ICP narrowing → Option A; forced decisions → §8.

---

## §2 Convergent Verdicts (≥3 agree, 5/5 unless noted)

**C1 — Provenance gate moat is real, architecturally unique, but commercially unvalidated (5/5)**
All 5 positions confirm SYNTHESIS-260517 §C1: no competitor (Mem0/Zep/Letta/Constructive/Graphiti) has write-time RLS enforcement. ALL 5 also confirm: 0 independent customers, 0 Mom Test interviews, 0 compliance-segment evidence. Architectural truth ≠ commercial truth.

**C2 — NOT seed-fundable today; pre-seed marginally possible only with strong narrative (5/5)**
POS-VC §1 verdict: pre-seed possible with narrative revision, seed not fundable, Series A 18+ months away. POS-DATA §2.2 + §6: 🔴 NO-GO for institutional seed, 🟡 BORDERLINE for angel pre-seed. POS-WEDGE §3 + POS-MARKET §6 concur. POS-DEFENSE §4 Risk 5 confirms VC-fundability "marginal" today.

**C3 — Karpov narrow ICP is the right answer (5/5); POS-DEFENSE Option A is the technical decision**
All 5 positions explicitly adopt the citation-grounded ICP framing. POS-DEFENSE §1 evaluates Options A/B/C: Option B (add `session_id`) explicitly rejected as collapsing the moat to `CHECK (TRUE)`; Option C (two-mode gate) rejected as contradictory positioning. Option A (narrow ICP, keep gate strict, walk away from conversational) selected unanimously.

**C4 — Tagline must change; "agent memory" universally is false advertising (5/5)**
Current "The write-time gate for agent memory" implies universality. Pure conversational/proactive/personal-assistant agents have no artifact_hash and structurally cannot use pgmnemo. POS-WEDGE §6 + POS-MARKET §1 + POS-DEFENSE §1 + POS-VC §1 + POS-DATA §1.3 all explicit on this.

**C5 — Mom Test interviews are blocking (5/5)**
DISCOVERY_PROTOCOL.md (Agency #6217, 2026-05-17) instrument exists, ZERO interviews executed. POS-VC §5.1, POS-WEDGE FD-1, POS-MARKET App., POS-DEFENSE §4.Risk 5, POS-DATA §3.P0 + §5.Gate F1 all explicitly block fundraising on this. Hard deadline: 2026-06-15.

**C6 — Compliance segment (S2/S4) is the only commercially viable wedge (4/5)**
S1 (software dev) is the wedge for distribution and testimonials but has near-zero ARPU. S2 (customer support) and S4 (regulated industries: healthcare, legal, financial) have compliance budgets ($50K–$500K/year) and regulatory mandates that force the buying decision. POS-WEDGE §4 sequencing, POS-MARKET §3 customer profiles, POS-DEFENSE §3 build-vs-buy, POS-VC §2 partner-fit ("compliance story" for Unusual/Amplify) all point to this. POS-DATA implicit via §3.P1.

**C7 — Lifestyle/OSS-reputation play is the honest current state; venture-scale requires 90-day validation (5/5)**
POS-VC §6 recommends NOT approaching VCs until BLOCKING gaps close; treat next 6 months as PMF validation sprint. POS-DATA §5 falsification gates F1–F5 define explicit pivot/kill points. POS-DEFENSE §4 Risk 5: "If ICP stays at compliance-bound... pgmnemo is a $2M–$10M ARR business — sustainable, profitable, not a venture-scale exit." POS-MARKET M6 verdict: "If M6 targets not met: do not raise. Continue as OSS reputation project."

---

## §3 Divergent Verdicts

### D1 — Tagline winner: POS-WEDGE vs POS-MARKET candidate A vs B vs C

| Position | Recommendation | Words |
|---|---|---|
| POS-WEDGE | "Provenance-enforced memory for agents that must cite their sources." | 8 |
| POS-MARKET A (README hero) | "The write-time gate for agents that cite their sources." | 9 |
| POS-MARKET B (pitch deck) | "No artifact hash, no write — memory enforcement for grounded agents." | 11 |
| POS-MARKET C (PGXN/Postgres) | "Write-time provenance enforcement inside Postgres, for citation-grounded agents." | 9 |

**Deciding rule:** POS-WEDGE phrasing is most honest about *requirement* ("must cite") vs *optionality* ("that cite"). Honesty about requirement is precisely what defeats Karpov's critique — ICP self-selects on read.

**🔒 RATIFIED VERDICT: WINNER = POS-WEDGE phrasing as primary tagline.**
> **"Provenance-enforced memory for agents that must cite their sources."**

Secondary deployment (per POS-MARKET §1 channel-surface analysis):
- README hero: WINNER tagline above
- Sub-headline: *"Every `ingest()` call is verified against source provenance before the row commits."* (from current POSITIONING.md, unchanged)
- PGXN listing: POS-MARKET Candidate C
- Pitch deck: POS-MARKET Candidate B

### D2 — Pre-seed timing: now vs after 90-day validation sprint

| Position | Recommendation |
|---|---|
| POS-WEDGE FD-4 | Raise $500K angel round NOW for 6-month runway to get 3 customers |
| POS-VC §6 | Do not approach VCs until BLOCKING gaps in §5 close (= 6-month sprint first) |
| POS-DATA §6 | 🟡 BORDERLINE for angel pre-seed; 🔴 NO-GO for institutional seed |
| POS-MARKET §6 | Not addressed directly; M6 (Nov 2026) is the explicit fundability checkpoint |
| POS-DEFENSE §4 Risk 5 | "Marginal" today; "Fundable if 2-3 independent adopters by 6 months" |

**Deciding rule:** POS-WEDGE's "angel round now" assumes a specific kind of investor (technical angel comfortable with team+moat bet, no traction). POS-VC's "wait" assumes institutional pattern-matching. Both are right for their target.

**🔒 RATIFIED VERDICT: TWO-TRACK approach.**
- **Track A (immediate):** Founder can pursue $250K–$500K angel/pre-seed conversations NOW with technical angels (DB infrastructure investors, OSS founders, Postgres-adjacent ops) who understand the moat without needing customer traction. Frame: "we need 6 months runway to validate the citation-grounded ICP." Expected close rate: low (1 of 10 conversations). Do not invest founder time beyond 4 hours/week.
- **Track B (primary):** 90-day PMF validation sprint per POS-DATA §4. Mom Test interviews + design partner pilots + benchmark card. If Track A produces a check, accelerate hiring. If not, Track B's results enable institutional seed in Q4 2026.

**Do NOT:** approach institutional seed funds (Amplify/Unusual/Madrona per POS-VC §2) before benchmark card published AND ≥2 design partners signed. POS-VC §5 BLOCKING list is correct on this.

### D3 — Bottom-up TAM number: hold or revise

| Position | Number |
|---|---|
| POS-WEDGE §3 | SAM = $720M by 2028; SOM = $180K–$1.4M ARR (base to bull) |
| POS-VC §3 Q1 | 20-30% of enterprise agent deployments (unsourced assertion, flagged WEAK) |
| Others | Did not compute |

**Deciding rule:** POS-WEDGE's number is derived bottom-up with stated assumptions (IDC AI software forecast × 10% agent infra × 20% memory × 40% citation-grounded × 45% Postgres). It is the only investable number in the documents. Use it.

**🔒 RATIFIED VERDICT:** Adopt POS-WEDGE §3 TAM/SAM/SOM as canonical. Cite in pitch materials with the caveat ("derived estimate; no analyst publishes 'agent memory' line item"). Update if Mom Test interviews surface different segment sizing.

---

## §4 ICP-Narrowing Decision: Option A Adopted

Per POS-DEFENSE §1 unanimous selection. Implementation impact:

- v0.5.0: **No SQL/code change.** Add `docs/ICP.md` documenting citation-grounded framing with worked examples. Add POSITIONING.md "Who this is NOT for" section.
- v0.6.0: **AWS Agent SDK research adds citation-grounded filter** — if most AWS Agent SDK uses are conversational (Lex bots), kill the AWS track regardless of pluggability. Target citation-grounded AWS use cases only: Bedrock Knowledge Bases, Amazon Connect Contact Lens, AWS CodeWhisperer memory.
- v0.6.0: **Framework adapters narrowed** — prioritize LangChain `RetrievalQA`, LlamaIndex `VectorStoreIndex`/`DocumentSummaryIndex`. Deprioritize `ConversationBufferMemory` adapter (violates ICP).
- v0.6.0: **MCP server wrapper** (P1, 1-2 days, separate `pgmnemo-mcp` Python package) — unchanged scope; citation-grounded when MCP server sits in RAG pipeline.

---

## §5 Investability Verdict (Today, May 2026)

**Today:** Lifestyle/OSS-reputation business with venture-scale technical moat and zero commercial validation.

**Pre-seed angel ($250K–$500K, 6-month runway):** 🟡 Marginal-yes via Track A. Closes 1 of ~10 conversations. Do not block other work waiting for it.

**Institutional seed ($2–5M, Amplify/Unusual/Madrona):** 🔴 NO-GO today. Reachable in Q4 2026 IF 90-day sprint hits §6 checkpoints.

**Series A:** 18+ months minimum. Requires $100K+ ARR from compliance customers + monetization decision + BD function (currently zero of these).

**Honest base case (recommended):** Acquisition by Supabase or Neon at $10–25M in 2028–2029, conditional on v1.0 + ≥3 external adopters + ICSE-SEIP acceptance. Not venture-scale return; a sound technical founder outcome. Frame this as the planned outcome, not the consolation prize.

---

## §6 First-10-Customers Acquisition Plan (Synthesis)

Drawn from POS-WEDGE §2 (10 customer profiles) + POS-MARKET §3 (acquisition actions + templates).

**Profile (top-3 priority segments):**
1. AI dev tooling / coding-agent startup (S1) — wedge for distribution + free testimonials
2. B2B SaaS customer support platform (S2) — first revenue-generating segment, ticket_id-grounded
3. Legal AI / healthcare AI / financial compliance AI (S4/S5) — high ARPU but 6-12 month sales cycle

**Channels (top-3 from POS-MARKET §2):**
1. Postgres ecosystem (PGXN + Postgres Weekly + PGConf) — $0 cost, 30-45 day lead time
2. GitHub cold outreach on memory/provenance issues in RAG repos (LlamaIndex/LangChain/CrewAI/Haystack) — $0 cost, 14-21 day lead time
3. Direct cold email to compliance-adjacent AI startups (AngelList/Crunchbase/LinkedIn search) — manual, 30-60 day lead time

**Outbound templates:** Use POS-MARKET §3 Templates 1 (Legal/Compliance), 2 (Healthcare/Pharma), 3 (Customer Support). Pre-qualify: confirm artifact source presence (document_hash, patient_record_id, ticket_id) BEFORE pitching.

**90-day numerical targets (from POS-MARKET §6 M1-M3):**
- M1 (June): 150 GitHub stars, 10 outbound sent, 2 responses, 0 paying
- M2 (July): benchmark card published, 250 stars, 1 trial adopter
- M3 (August): v0.6.0 ships, MCP Registry live, 2 trial adopters, first invoice discussions

---

## §7 Falsification Gates

Per POS-DATA §5 (mechanical pivot/kill triggers):

| Gate | Trigger | Date | Action if triggered |
|---|---|---|---|
| **F1 — Interview failure** | <3/8 Mom Test interviews confirm problem | 2026-06-15 | WG within 7 days; pivot or absorb as Agency-internal tool |
| **F2 — Pilot stall** | 0/2-3 compliance pilots produce LOI/expansion | 2026-08-15 | Kill venture-scale plan; continue as OSS reputation |
| **F3 — Recall regression** | Agency-corpus recall@10 < 0.55 (p_corr<0.05) | ongoing | Block tag, publish incident, notify Agency |
| **F4 — Gate bypass** | External researcher demonstrates bypass without SUPERUSER | anytime | Retract claim, security advisory, no investor talks until patched |
| **F5 — Card not published** | v0.6.0 ships without benchmark card v0 | 2026-08-15 | Freeze growth work until card ships |

---

## §8 Forced-Decision Items for Founder

**Carried from POS-WEDGE FD-1..FD-4 and POS-VC §5. Founder must decide; WG cannot ratify.**

### FD-1 — Mom Test interviews: kick off before next eng sprint? **(2026-05-20)**
**Recommendation: YES.** Block growth_lead/PI for 2 weeks. Without 5-8 interviews by 2026-06-15, F1 fires and entire venture trajectory is unsupported. Cost: ~20 hours founder + ~30 hours PI/growth_lead.

### FD-2 — Pre-seed angel conversations: start Track A now or wait until Q4? **(2026-05-23)**
**Recommendation: START NOW, BUDGET ≤4 hours/week.** Track A is opportunistic — technical angels who bet on team+moat. Do not let it absorb >5% of founder time. Do NOT approach institutional seed funds before §6 M3 checkpoint.

### FD-3 — Managed hosting waitlist: open form now or commit extension-only through v1.0? **(2026-05-23, carried from prior SYNTHESIS)**
**Recommendation: open zero-cost waitlist form NOW.** Single landing page, no engineering. Captures demand signal before Graphiti pgvector lands (est. Q3 2026). Reversible. MENTOR lean from prior session.

### FD-4 — AWS Agent SDK: 3-day research spike build/kill verdict **(2026-05-30, from prior SYNTHESIS)**
**Recommendation: CA delivers verdict; founder ratifies.** Updated criterion per Option A: kill the track if AWS Agent SDK use cases are predominantly conversational (Lex bots). Pursue only if Bedrock Knowledge Bases + Connect Contact Lens + CodeWhisperer paths are commercially significant.

### FD-5 — Honest acquisition framing in fundraising deck **(before any VC meeting)**
**Recommendation: PLAN the $10-25M Supabase/Neon acquisition path explicitly.** Per POS-VC §4, this is the honest base case (probability 55%). A founder pitching "lifestyle or acquisition" is more credible than one pitching "$1B unicorn" with 0 customers. Choose the frame before the first VC meeting.

### FD-6 — Dual-license enterprise feature gating timing **(before v1.0 scope lock)**
Carried from prior SYNTHESIS. No new evidence; recommendation unchanged.

---

## §9 Deliverables Applied by This Synthesis

1. **This file** — `spec/competitive/SYNTHESIS_VC_PGMNEMO_2026-05-17.md` (internal)
2. **POSITIONING.md** — rewritten (root, public)
3. **ROADMAP.md** — updated Strategic frame + v0.5.0 docs section
4. **STARTUP_TEMPLATE_FILLED.md** — `spec/competitive/STARTUP_TEMPLATE_FILLED.md`, filled per actual 7-sheet structure extracted via Chrome MCP (commit 8c44419)

All in one commit: `docs(WG-VC-260517): manual ratify — positioning v3 + roadmap + filled startup template`.

---

*Synthesis authored manually by TL Karpov 2026-05-17 because agency-api (orchestrator) is down on SQLAlchemy `metadata` reserved-attribute error at apps/executive-cli/src/executive_cli/models.py:729 — this is an active v2→v3 cutover artifact (commit 42ca8ff9 "archive(v2): move api/cli/v3 to archive/"). Manual ratify proceeded per founder instruction "Karpov должен решить".*
