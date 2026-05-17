# POS-DEFENSE-PGM: Moat Strength After ICP Narrowing

**Doc:** spec/competitive/POS-DEFENSE-PGM.md  
**Task:** PGMNEMO-WG-VC-260517  
**Role:** CA — moat analysis under narrowed ICP  
**Date:** 2026-05-17  
**Status:** RATIFIED  
**Inputs:** POSITIONING.md (2026-05-17), ROADMAP.md (v2), SYNTHESIS_PGMNEMO_2026-05-17.md, CROSS_CUTTING_SYNTHESIS_2026-05-16.md, POS-CA/GROWTH/MENTOR/RS-PGM.md

---

## §1 Gate-Applicability Decision: Option A / B / C

### The Karpov Critique, Stated Precisely

The current `ingest()` gate requires `commit_sha` OR `artifact_hash` as a provenance anchor
(POSITIONING.md: *"An `ingest()` call without a valid `commit_sha` or `artifact_hash` is rejected
by the Postgres executor"*). This works structurally only where the caller possesses a deterministic
artifact identifier at write time.

**Works:** RAG pipelines (document `artifact_hash` = SHA-256 of chunk), customer support
(`ticket_id` as `commit_sha`-equivalent), medical (`patient_record_id`), legal (`case_id`),
software dev (literal `commit_sha`). These are the ICPs where a citation anchor exists before the
memory write is attempted.

**Fails structurally:** pure conversational agents, proactive observation, personal assistant
chitchat. These agents produce memory claims from unanchored inference — "user said X" — where no
artifact identifier precedes the claim. Forcing them to supply `commit_sha` produces either silent
fabrication (callers hash the LLM turn text and pass it off as provenance) or rejection-at-write
with no recovery path.

The Karpov critique is correct: POSITIONING.md's tagline "The write-time gate for **agent memory**"
implies universal applicability. The actual applicability is **citation-grounded agent memory**.

### Decision: **Option A — Narrow the ICP, Keep the Gate Strict**

**Rationale:**

Option B (extend gate to accept `conversation_id`/`session_id`) solves adoption friction by
accepting any string as provenance. It destroys the moat. If the gate accepts a session UUID with
no semantic binding to an external artifact, then the gate is a labeling convention, not an
enforcement primitive. Mem0 can add a `metadata={"session_id": x}` field in 48 hours. The RLS
enforcement no longer means "this memory is anchored to a real-world artifact" — it means "this
memory has a string attached." The falsification condition in POSITIONING.md ("A standard
`pgmnemo.ingest()` call with no `commit_sha` / `artifact_hash` succeeds") is vacuously satisfied
by accepting anything.

Option C (two-mode: strict + permissive with `provenance:llm_inferred` tag) is a middle path that
preserves the strict mode for compliance buyers while extending reach. It is architecturally
defensible but creates a product with two personas that confuse the positioning. The compliance buyer
asks: "Can the agent bypass strict mode?" If the answer is yes (by switching to permissive), the
buyer's compliance counsel will say no. If permissive mode is truly isolated by tenant/role, the
implementation cost approaches building two separate gates and maintaining both. This creates a
v0.5.0/v0.6.0 engineering debt that the team cannot afford at 1 production user.

**Option A verdict:** Walk away from conversational agents. They are not the ICP. The gate means
something precisely because it requires a real artifact anchor. Narrowing the ICP *is* the moat.

### Implementation Impact on v0.5.0 / v0.6.0

**v0.5.0 (target 2026-06-20) — ICP signal changes, scope unchanged:**

No gate schema change. The existing `gate_strict` GUC + RLS policy + column constraint remains
as-is. The following documentation and tooling changes are required:

| Change | Scope | Effort |
|---|---|---|
| Update `docs/INSTALL.md` to add "Is pgmnemo right for your agent?" decision tree | Docs | 2h |
| Add `pgmnemo.check_provenance_type(anchor TEXT)` diagnostic function that classifies the anchor type (commit-sha pattern, content-hash, ticket-id pattern, or "unrecognized — gate will reject") | SQL, 1 function | 4h |
| Update POSITIONING.md tagline sub-headline to "For agents with a citation: RAG, document-grounded, compliance, support, legal, software dev" | Docs | 30 min |
| Block "pure conversational" from the comparison table framing — do not claim to replace Mem0 for chatbot memory | Docs | 1h |

None of these changes touch v0.5.0's primary scope (R5, R6, R10, H-06 temporal weight, bitemporality H-07).

**v0.6.0 (target 2026-08-15) — Provenance-type registry:**

Add a `provenance_type` ENUM to `mem_item` with values: `commit_sha`, `content_hash`,
`ticket_id`, `record_id`, `case_id`. The gate continues to reject NULL; accepted values are
now typed. This enables per-`provenance_type` audit queries (`WHERE provenance_type =
'ticket_id'`) and per-type policy overrides for multi-tenant deployments. The ENUM is
additive — no migration required for existing rows (default `provenance_type = 'untyped'`
for backward compatibility, treated as `content_hash` by gate logic).

This is Option A done right: not broadening what the gate accepts, but making the
accepted provenance types machine-readable and auditable.

---

## §2 Moat-Strength Curve: 12 / 24 / 36 Months

### Baseline Moat (May 2026)

The structural moat is three interlocking Postgres mechanisms (POS-CA-PGM §3):
1. Column `CHECK` constraint: `CHECK (gate_strict = false OR commit_sha IS NOT NULL)`
   evaluated per row at `INSERT`/`UPDATE` — Postgres executor, not application code.
2. RLS policy: `CREATE POLICY mem_ingest ON mem_item FOR INSERT WITH CHECK
   (pgmnemo.gate_check(commit_sha, artifact_hash))` — enforced after constraint, before
   heap write. A `SET ROLE agent_role` connection cannot bypass without `ALTER POLICY`
   (requires `SUPERUSER`).
3. GUC `gate_strict`: application cannot disable enforcement without `SUPERUSER` or
   `ALTER SYSTEM`.

No competitor has an equivalent (SYNTHESIS C1, unanimous 4/4). Constructive AgenticDB
(closest architectural peer) does not implement provenance gating — it embeds and stores
without write-time veto.

### Scenario (a): Graphiti Ships pgvector + Adds RLS

**Timeline:** Q3 2026 estimated (POS-CA-PGM §2 monitoring note; zep.md §13 "quarter away").

**12 months (May 2027):** Graphiti has a pgvector backend. "Postgres-native" framing collapses
for pgmnemo (Letta already did this). Graphiti still has **no write-time veto**. Their provenance
model is post-hoc episodic back-reference (zep.md §10: "write first, inspect after"). Even with
pgvector storage, a Graphiti write always succeeds if LLM extraction returns a result. RLS is a
Postgres feature Graphiti *could* add, but it would require them to:
- Restructure their Python write path to run `SET ROLE` before write
- Implement a `gate_check()` equivalent at the DB layer — not in application code
- Drop their LLM-detected contradiction resolution (which happens *after* the write) in favor
  of pre-write rejection

This is a 3–6 month architectural rewrite, not a feature addition.

**pgmnemo positioning move:** "Graphiti added pgvector. pgmnemo added provenance gating.
Both run on Postgres. Only one can tell you a hallucinated write never reached the heap."

**24 months (May 2028):** If Graphiti invests in compliance and adds RLS-backed gating,
the differentiation narrows to (a) bitemporality at the DB trigger layer (pgmnemo) vs LLM
contradiction resolution (Graphiti), and (b) zero-LLM-cost per write (pgmnemo) vs required
LLM extraction (Graphiti). At 2 years, bitemporality is table stakes; the cost argument
(`$0 vs $0.36/1K writes at gpt-4o-mini`) is increasingly compelling at enterprise write volumes.

**Moat survival at 24 months:** Yes, but diminished. Requires shipping audit-export enterprise
features (MENTOR §3: "enterprise feature gating at v1.0") to create a revenue-protected moat layer
that Graphiti cannot clone without a comparable compliance program.

**36 months (May 2029):** pgmnemo moat is either validated by 3+ compliance-segment case studies
(legal, medical, finance) or has been commoditized. If 3 enterprise customers with case studies
by v1.0 (ROADMAP: "≥3 external adopters with public case studies") — moat holds and enterprise
feature gating activates revenue defense. If still at 1 production user — moat exists but is
not revenue-generating; acquisition is the realistic exit, not Series A.

### Scenario (b): Mem0 Adds Metadata-Gate Option

**Timeline:** 30–90 days from decision (Mem0 engineering velocity at 186M API calls/month is high).

**12 months:** Mem0 ships `gate_mode=strict` on `add()` that rejects writes without a
`source_id`. This is an application-layer gate, not a DB-layer gate. The Mem0 architecture
is a cloud API (SaaS): the gate lives in their Python service, not in Postgres. A buggy
caller, a compromised API key, or a Mem0 service bug can still write an ungated row —
the caller has no cryptographic proof that the gate fired. pgmnemo's RLS gate produces a
Postgres error (`ERROR: new row violates row-level security policy`) that is logged in
`pg_log`, auditable, and provably transactional (the write either fails or succeeds atomically).
A cloud API's "we rejected it" is an unverifiable assertion to a compliance auditor.

**pgmnemo positioning move:** "Mem0 added a metadata gate. The gate lives in their Python
service. We cannot audit whether their gate fired without trusting Mem0's logs. pgmnemo's
gate is a Postgres transaction — your DBA can audit it in `pg_log` without asking us for
anything."

**24 months:** If Mem0 launches managed Postgres with a pgmnemo-equivalent extension
(highly unlikely — it contradicts their SaaS model), the moat collapses. Short of that,
the architecture gap is durable. Self-hosted Postgres with RLS enforcement is an
uncloneable guarantee for SaaS vendors.

**Moat survival at 24 months:** Yes, with one required move: publish the write-rejection
audit query (`SELECT * FROM pg_log WHERE error_message LIKE '%violates row-level security%'`)
as a first-class compliance artifact. Make the auditability gap concrete and documented.

### Scenario (c): Anthropic Ships MCP-Memory Primitive

**Timeline:** Unknown; no public roadmap item. MENTOR §4: "no incentive to become a
Postgres infrastructure vendor."

**12 months:** Anthropic extends MCP (currently at spec version 2025-11-05, see §5 for
analysis) with a `memory/store` and `memory/retrieve` tool schema. This is a message-passing
spec, not a storage enforcement spec. The spec defines the API contract between an MCP client
(Claude) and an MCP server (the memory provider). It does not — and cannot — enforce what
happens inside the memory server. A `memory/store` call can be received by pgmnemo's MCP
server adapter, which then routes to `pgmnemo.ingest()` with full RLS enforcement. The MCP
spec becoming a standard *helps* pgmnemo by creating a distribution surface (MCP Registry).

**The one genuine risk** (POS-MENTOR §4): if the MCP memory spec explicitly defines provenance
as optional metadata rather than a mandatory gate primitive, pgmnemo's gate becomes a
non-standard extension. Mitigation: submit a provenance-gate extension proposal to the MCP
spec before v1.0 (see §5).

**24 months:** MCP memory ecosystem matures with multiple providers. pgmnemo is one of them —
differentiated by RLS enforcement, not by being the only MCP memory provider. The moat
shifts from "only gate" to "only auditable gate."

**Moat survival at 24 months:** Yes, as a compliance-grade MCP server. Requires the MCP
adapter to ship (v0.6.0 Anthropic MCP Registry wrapper, ROADMAP T1 track).

---

## §3 Build-vs-Buy Analysis: Compliance-Bound Enterprise

Three paths for an enterprise that needs provenance-gated agent memory (legal, medical,
financial services ICP):

### Path (i): Build In-House

**What "in-house" actually requires:**

| Component | Implementation | Ongoing cost |
|---|---|---|
| Postgres schema | `mem_item` table with `commit_sha NOT NULL` constraint | 1 day |
| RLS policy | `CREATE POLICY` + `gate_check()` function | 2–3 days |
| GUC for enable/disable | Custom Postgres extension (`CREATE EXTENSION`) to register GUC | 1 week (C code, PG extension API) |
| `gate_strict` bypass-proof enforcement | RLS policy evaluated by Postgres executor — requires testing against all role configurations | 3–5 days testing |
| Hybrid recall (BM25 + vector) | `tsvector` + `ts_rank_cd` + pgvector HNSW — standard Postgres, ~200 LOC | 1 week |
| Bitemporality triggers | `t_valid_from`/`t_valid_to` + supersession trigger | 3 days |
| Benchmark validation | Reproduce recall@10 against LoCoMo/LongMemEval | 2–4 weeks |
| Security audit (RLS bypass scenarios) | Requires Postgres RLS expert review | $15K–$30K one-time |
| **Total first-build** | | **6–8 engineer-weeks + $15K–$30K audit** |
| **Ongoing maintenance** | PG version upgrades, pgvector API changes, security patches | 0.25 FTE/year |

**Realistic enterprise TCO (3 years, 1 FTE at $180K loaded):**
- Year 0: 6–8 weeks build = $20K–$27K + $15K–$30K audit = **$35K–$57K**
- Year 1–3: 0.25 FTE maintenance = $45K/year = **$135K**
- **3-year TCO: $170K–$192K** (excluding opportunity cost)

**Hidden risk:** the in-house RLS policy is untested against all Postgres role escalation
paths. A `SET SESSION AUTHORIZATION` or `SECURITY DEFINER` function could bypass a naively
written policy. pgmnemo has tested this surface (POSITIONING.md falsification table:
"A compromised or buggy agent cannot write a provenance-free memory row without database
superuser access, regardless of how the `INSERT` is constructed"). In-house build inherits
this risk without the test coverage.

### Path (ii): Buy pgmnemo (Apache 2.0, self-hosted)

**Current cost (May 2026):** $0 license. Self-hosted on existing Postgres infrastructure.

| Component | Cost |
|---|---|
| License | $0 (Apache 2.0) |
| Integration engineering | 2–3 days (ROADMAP: "under 5 minutes" for basic install; production hardening 2–3 days) |
| Ongoing updates | Git pull + `ALTER EXTENSION pgmnemo UPDATE` — same as any Postgres extension |
| Security audit of pgmnemo itself | Share with other pgmnemo users; open-source codebase auditable independently |
| Missing: enterprise audit-export | Not yet shipped (planned v1.0 dual-license feature per MENTOR §3) |

**3-year TCO (self-hosted):** Integration engineering $3K–$5K + 0.05 FTE ongoing maintenance
= $3K–$5K + $27K = **$30K–$32K**.

**The current gap:** No enterprise support SLA. No audit-export to SIEM. No SOC2/HIPAA
compliance documentation. For a regulated enterprise, this means pgmnemo is a **components
play** — they use it but their legal counsel will want something more. This gap closes at
v1.0 with dual-license enterprise features.

**Honest assessment for VC:** pgmnemo at $0 ARR with 1 production user cannot quote TCO
competitively against a vendor with SLA. The path to enterprise sale requires v1.0 features
and at least 2 reference customers in the compliance segment.

### Path (iii): Buy Mem0 Enterprise + Custom Audit

**Mem0 enterprise pricing:** Not publicly listed; estimated $0.17/1K writes LLM extraction
cost at list pricing suggests enterprise contracts in the $50K–$200K ARR range for meaningful
write volumes.

| Write volume | Mem0 LLM extraction cost/year | Mem0 contract (est.) | Custom audit layer |
|---|---|---|---|
| 1M writes/month | $2,040/year | $50K–$100K ARR | $30K–$80K build (no write-time DB gate available) |
| 10M writes/month | $20,400/year | $100K–$200K ARR | Same $30K–$80K |

**The compliance problem with Path (iii):** Mem0's gate is an application-layer assertion.
A compliance auditor asking "prove no ungated write reached your memory store" cannot be
answered from Mem0's infrastructure — it requires trusting Mem0's internal audit logs.
For HIPAA, GDPR audit trails, or SOC2 Type II controls, this is architecturally insufficient.
The custom audit layer (Path iii's $30K–$80K add-on) would need to build exactly what pgmnemo
already provides: a DB-layer write-time veto with audit trail in `pg_log`.

**Verdict:** For compliance-bound enterprise, Path (iii) is the most expensive option
and the weakest compliance guarantee. Path (i) is cheaper than Path (iii) for regulated
entities but carries build-and-maintain risk. Path (ii) is cheapest total cost but missing
enterprise packaging. pgmnemo's commercial opportunity is converting Path (i) builders to
Path (ii) buyers with v1.0 enterprise features — the audience is real, the TCO case is real,
the product gap is specific and closeable.

---

## §4 Technical Risk Register

### R1: PostgreSQL Row-Level Security Policy Evolution

**Risk:** PostgreSQL core team modifies RLS evaluation semantics in a future major version
(PG18+). Specifically: if `SECURITY DEFINER` functions inside `WITH CHECK` policies change
behavior, or if a new `BYPASS RLS` role capability is introduced that affects `agent_role`
scope, the gate could silently weaken.

**Severity:** Critical. The moat's bypass-proof claim rests on current PG17 RLS semantics.

**Mitigation:** 
- Pin CI to both PG17 and the latest PG beta. Any test that exercises RLS bypass scenarios
  (`scripts/rls_audit.sql` — create if not exists) must pass on both.
- Monitor PostgreSQL commitfest and `pgsql-hackers` list for patches touching `src/backend/
  rewrite/rowsecurity.c` and `src/backend/utils/misc/guc.c`.
- The falsification table in POSITIONING.md ("`SET ROLE agent_role` cannot write a
  provenance-free row") is a regression test commitment. If a PG version change breaks it,
  treat as P0 and publish a security advisory before the affected PG version reaches GA.

**ROADMAP window:** R1 is ongoing infrastructure hygiene. No specific release; add PG-beta
CI target in v0.5.0 CI config.

### R2: pgvector Deprecation or API Break

**Risk:** `pgvector` is MIT-licensed by ankane/pgvector. If the project is abandoned,
acquired, or its HNSW index API changes (e.g., `ivfflat` → new index type with incompatible
`SELECT ... ORDER BY embedding <=> $1 LIMIT k` syntax), `recall_lessons()` hybrid path breaks.

**Severity:** High for retrieval quality; does not affect the provenance gate.

**Mitigation:**
- pgvector's operator class syntax (`<=>` for cosine, `<#>` for inner product, `<->` for L2)
  is stable and widely adopted. A breaking change would affect Supabase, Neon, AWS, and
  every hosted Postgres offering — upstream incentive to maintain stability is extremely high.
- pgmnemo's SQL is vendor-neutral: `recall_lessons()` uses standard `pgvector` operators and
  `tsvector` — no pgmnemo-specific fork of pgvector.
- Mitigation action: abstract the embedding similarity call behind a single SQL function
  `pgmnemo.vec_similarity(a vector, b vector)` so that a pgvector API change requires
  editing one function, not all callers. Ship in v0.5.0 (already touched in H-06 scope).

**ROADMAP window:** v0.5.0 abstraction layer. Low effort (~2h refactor).

### R3: RLS Bypass via SECURITY DEFINER Function

**Risk:** An application developer installs a `SECURITY DEFINER` function (runs with the
definer's privileges, not the caller's) that inserts into `mem_item` under a superuser-owned
function definition. The RLS policy applies to the calling role; if the function is owned by
a superuser and `SECURITY DEFINER`, the insert runs as superuser and `BYPASS RLS` applies.

**Severity:** Critical. This is a known PostgreSQL behavior (documented in `CREATE FUNCTION`
reference: *"A SECURITY DEFINER function is executed with the privileges of the user that
owns it"*; superusers have `BYPASS RLS` implicitly).

**Mitigation:**
- POSITIONING.md falsification condition already scopes the claim correctly: "without database
  superuser access." The claim is not "bypass-proof against superusers" — it is "bypass-proof
  from the application layer under a normal role."
- Add explicit documentation in `docs/SECURITY.md` (create if not exists): "Do not grant
  SUPERUSER or create SECURITY DEFINER functions owned by a superuser in the pgmnemo schema.
  Doing so bypasses RLS enforcement by design (PostgreSQL documented behavior)."
- Provide a `pgmnemo.audit_privileges()` diagnostic function that queries `pg_proc` for any
  `SECURITY DEFINER` functions in the schema and warns if they are superuser-owned.
- Ship in v0.5.0 as part of the `pgmnemo.stats()` extension to diagnostics track.

**ROADMAP window:** v0.5.0. Low-effort documentation + 1 diagnostic function.

### R4: Apache 2.0 Competitor Fork

**Risk:** A well-funded competitor (Mem0, or a new entrant) forks pgmnemo under Apache 2.0,
strips the pgmnemo brand, adds a managed SaaS wrapper, and competes directly with "pgmnemo
but hosted" — without contributing back.

**Severity:** Medium. Apache 2.0 explicitly permits this. The fork cannot remove the
`NOTICE` file (attribution requirement) but can compete commercially.

**Mitigation:**
- Apache 2.0 was chosen deliberately (SYNTHESIS C7: "no managed SaaS before v1.0" aligns
  with staying Apache 2.0 for community trust). Do not change the license defensively — it
  would destroy community trust faster than a fork would hurt revenue.
- The moat against a fork is not the license — it is the benchmark ledger (POS-RS-PGM §2)
  and the pre-registered evaluation protocol. A fork inherits the code; it cannot inherit
  the reproducible benchmark chain. "pgmnemo has 8 publicly pre-registered cells; the fork
  has none" is a trust argument the compliance buyer will find compelling.
- At v1.0, dual-license the enterprise audit-export module under a commercial license
  (MENTOR §3: "enterprise feature gating"). This is the revenue-protecting layer; the core
  gate stays Apache 2.0.
- **No action required in v0.5.0/v0.6.0.** This risk materializes only after pgmnemo
  achieves meaningful adoption, which is still 12+ months away.

### R5: Single Production User Concentration Risk

**Risk:** Agency is the only production user. If Agency deprioritizes pgmnemo (switches to
Mem0, gets acquired, or shuts down), pgmnemo loses 100% of its production evidence. Every
benchmark cell sourced from Agency corpus (C5: recall@10=0.5745, N=1060) becomes
unverifiable.

**Severity:** High for VC narrative; Medium for technical moat (the gate still works;
the production evidence disappears).

**Mitigation:**
- This is the primary risk for pre-seed fundability (see §6 below).
- Mitigation is user acquisition, not technical: DISCOVERY_PROTOCOL.md (Agency #6217)
  Mom Test instrument is written — run the interviews before 2026-06-01. Three independent
  companies using pgmnemo in production reduces concentration risk from "100% Agency" to
  "33% Agency."
- Technical mitigation: decouple the benchmark card from Agency corpus. Add a synthetic
  benchmark corpus (LoCoMo + LongMemEval already provide this) as the primary published
  cells. C5 (Agency corpus) becomes one cell in an 8-cell card, not the sole production
  evidence.
- **ROADMAP window:** Discovery interviews P1 before v0.5.0. Benchmark card v0 (pre-v0.6.0,
  due 2026-07-15) makes the Agency corpus dependency visible and bounded.

---

## §5 The "Anthropic Ships Memory" Question

### What the MCP Spec Actually Governs (May 2026)

MCP spec version 2025-11-05 defines the protocol between MCP clients and MCP servers.
Relevant spec sections for memory:

- **Section 3.3 (Tools):** MCP servers expose tools as structured JSON schema. A `memory/
  store` tool would be a server-side tool definition — the spec defines the *call contract*,
  not the *storage implementation*.
- **Section 3.4 (Resources):** Servers expose resources for read access. Memory retrieval
  maps to this primitive.
- **Section 5.1 (Security Considerations):** The spec notes that servers are responsible for
  access control. It does not prescribe how access control is implemented.

**Conclusion:** MCP is a message-passing spec. It defines how Claude calls `memory/store`,
not what happens inside the server when that call arrives. An Anthropic-built MCP memory
server is a specific implementation of the MCP tool contract — pgmnemo can expose the same
contract via its own MCP server adapter. Anthropic shipping "MCP memory" creates a **category
standard**, not a monopoly.

### If Anthropic Launches First-Class MCP-Memory in Claude SDK

**What they would ship:** A managed `memory/store` + `memory/retrieve` tool server, likely
cloud-hosted, profile-based (similar to Claude.ai consumer memory), optimized for conversational
context, not for compliance-grade provenance gating.

**Why this is not pgmnemo's market:**

Anthropic's memory product will optimize for: Claude.ai consumer UX, API simplicity for
hobby developers, and conversational context retention. It will not optimize for:
- Write-time provenance veto at the DB layer (requires self-hosted Postgres control plane)
- `pg_log`-auditable rejection events (requires direct Postgres access)
- Bitemporality with DB-level trigger supersession (requires schema ownership)
- Zero-LLM-cost per write (Anthropic's memory product will likely use embedding or extraction)

Anthropic shipping memory *legitimizes* the category. The positioning move is identical to
the Letta framing: "Claude showed agents benefit from memory. pgmnemo shows agent memory
needs a write-time gate."

### Specific Technical Hooks That Complement (Not Compete With) Anthropic

**Hook 1 — MCP Server Adapter (v0.6.0 Anthropic MCP Registry wrapper):**

Implement pgmnemo as an MCP server that registers `pgmnemo/store` and `pgmnemo/retrieve`
tools. Any Claude SDK client that connects to this server gets RLS-enforced provenance gating
as the backend. The MCP client (Claude) is unchanged; pgmnemo is the *server-side enforcement
layer* behind the MCP contract.

```json
{
  "name": "pgmnemo/store",
  "description": "Write-time provenance-gated memory store. Rejects writes without artifact_hash or commit_sha.",
  "inputSchema": {
    "type": "object",
    "required": ["content", "provenance_anchor"],
    "properties": {
      "content": {"type": "string"},
      "provenance_anchor": {
        "type": "string",
        "description": "commit_sha, content_hash, ticket_id, record_id, or case_id"
      }
    }
  }
}
```

This positions pgmnemo as the *compliance-grade MCP memory server* — not competing with
Anthropic's conversational memory, but providing the auditable alternative for enterprise
Claude deployments where provenance matters.

**Hook 2 — Provenance Gate as MCP Extension Proposal:**

Submit a provenance gate primitive proposal to the MCP spec (GitHub: modelcontextprotocol/
specification) before Anthropic finalizes a memory spec. Proposed addition to Section 5.1:

> Servers that store agent memory SHOULD support a `provenance` field on write operations
> identifying the source artifact. Servers MAY implement write-time rejection of unprovenance
> memory items as a security primitive.

If accepted, pgmnemo's gate becomes the reference implementation of a spec-defined security
primitive — not a non-standard extension.

**Hook 3 — Anthropic as Validator, Not Competitor:**

If Anthropic ships MCP memory and pgmnemo has a compliant MCP server adapter, the correct
response is: submit pgmnemo to the MCP Registry (ROADMAP T1 track). The MCP Registry makes
pgmnemo discoverable to every Claude SDK user who needs a self-hosted, provenance-gated
alternative to Anthropic's managed option.

This is the positioning: "Anthropic's MCP memory is the easiest path. pgmnemo is the
auditable path. Your compliance team decides which you need."

---

## §6 VC-Fundability Assessment: Honest Framing

### Pre-Seed / Seed TODAY (May 2026)

**What can be said to a VC today:**
- Unique technical primitive: write-time RLS-enforced provenance gate with no competitive
  equivalent (SYNTHESIS C1, 4/4 unanimous).
- 1 production user with reproducible benchmark evidence (recall@10=0.5745, N=1060).
- Apache 2.0 with honest benchmark disclosure (competitive rarity per POS-RS-PGM §2.1 —
  Mem0/Zep benchmark integrity dispute, HN 44883133).
- Clear ICP narrowing: citation-grounded agents in compliance-sensitive verticals.

**What cannot be said:**
- "We have validated the compliance segment" — DISCOVERY_PROTOCOL.md interviews not
  conducted (Agency #6217, 2026-05-17).
- "We have multiple production customers" — 1 user (Agency, which is the builder, not
  an independent validation).
- "We have revenue" — $0 ARR.

**Pre-seed fundability verdict:** Fundable as a technical bet by a thesis-driven pre-seed
fund (infrastructure, compliance-AI, or developer tools focus). NOT fundable on traction
alone. The ask must be: "fund the interviews and the benchmark card; we have the primitive."

**Series A in 6 months (November 2026):** Requires by November 2026:
- ≥3 independent production users (not Agency-related) using pgmnemo for a compliance use case.
- At least 1 paying customer (even at $5K ARR) to demonstrate willingness-to-pay for
  enterprise features.
- Benchmark card v0 published (pre-v0.6.0, 2026-07-15) establishing trusted-third-party
  credibility.
- At least one of: ICSE-SEIP paper accepted, or feature in a major Postgres community resource
  (pgxn.org featured extension, Crunchy Data blog post, pganalyze reference).

**Series A fundability verdict:** Not currently achievable in 6 months on the current
trajectory without running the Mom Test interviews NOW and converting at least 2 of them
to active users before August 2026.

### Lifestyle Business vs Venture-Scale Exit: Honest Framing

**Lifestyle business path:** pgmnemo as Apache 2.0 infrastructure that Agency (and similar
internal teams) use. Founder maintains it. Revenue: consulting, speaking, potential paper
acceptance. Exit: not applicable or acqui-hire at $500K–$2M if a larger infra company
wants the primitive.

**Venture-scale path:** pgmnemo as the compliance-grade memory layer for citation-grounded
agents across legal (case_id), medical (patient_record_id), and financial (audit trail)
verticals. Enterprise dual-license at v1.0 targets $50K–$200K ARR per customer. At 10
enterprise customers: $500K–$2M ARR. Series A at 3–5× ARR = $1.5M–$10M raise.

**Honest verdict:** The venture path is technically viable but requires 3 things that are
not yet done and cannot be faked: (1) Mom Test interviews in the compliance segment, (2) at
least 2 independent production deployments before Series A, (3) enterprise feature packaging
at v1.0. Without these, the honest framing is: strong technical primitive in a lifestyle
project, with venture-scale option value contingent on discovery validation.

---

*Commit: 9aa8f85*
