# POS-CA-PGM: Chief Architect Response to 3 Competitive Threats

**Doc:** spec/competitive/POS-CA-PGM.md  
**Date:** 2026-05-16  
**Author:** Chief Architect  
**Input:** CROSS_CUTTING_SYNTHESIS_2026-05-16.md + 4 competitor deep-dives + ROADMAP v2  
**Status:** WG review

---

## Positioning correction (P0, execute before this doc ships)

Update `POSITIONING.md §3` (Constructive AgenticDB): license is **MIT** not Apache-2.0 (constructive_agenticdb.md §7: *"License | Apache-2.0 | MIT [1][6]"*); vector index is **HNSW via pgvector** not none (*"Vector index | HNSW via pgvector (cosine/L2/inner-product) [6]"*); embeddings are **bundled** (Ollama + nomic-embed-text, not user-supplied). Failure to correct these exposes us to trivial fact-checks that undermine the rest of our positioning.

---

## 1. T1 — Mem0 as AWS Agent SDK Exclusive Memory Provider

### Threat

mem0.md §2: *"Mem0 publicly claims >80,000 developers signed up on the cloud platform and that they are the exclusive memory provider for AWS's Agent SDK (TechCrunch, ibid.) — that AWS exclusivity, if true and durable, is the single most important distribution fact in this entire report."* Q3 2025 run-rate: 186M API calls/month, ~30% MoM growth. For every new AWS-hosted agent that reaches for the SDK default, pgmnemo does not exist.

### Is there an AWS adapter path?

Yes — technically achievable, not trivial. Three viable patterns:

**Pattern A — Lambda adapter (recommended):** The AWS Agent SDK exposes a memory provider interface (confirmed present; exact schema requires 2-day research sprint). pgmnemo is pure SQL with no C compilation dependency (README: *"pgmnemo is pure SQL — no compilation"*). A `pgmnemo-aws-agent-sdk` Python package (~200 LOC) wraps `psycopg3` calls to `pgmnemo.recall_lessons()` / `pgmnemo.ingest()` and implements whatever ABC the SDK requires. Deployed as a Lambda function; pgmnemo backend is RDS PG17 or Aurora PG-compatible. Cold-start penalty is a psycopg3 connection, not a model load.

**Pattern B — CDK construct:** Ship a CDK L3 construct `PgmnemoMemoryProvider` that provisions: RDS PG17 instance, Lambda adapter function, IAM role with least-privilege RDS IAM auth, and wires the Lambda ARN into the agent's memory provider config. Developers using CDK get one-liner adoption. Effort adds 3–5 days on top of Pattern A.

**Pattern C — Lambda Layer:** Package `psycopg3` + the `pgmnemo` Python client as a Lambda Layer. Developers compose it manually. Low effort (1 day) but no first-class DX — not recommended as primary distribution.

**Effort estimate:**
| Phase | Work | Duration |
|---|---|---|
| Research | Read AWS Agent SDK memory provider interface spec; confirm extensibility | 3 days |
| MVP | Pattern A Lambda adapter + unit tests against docker-compose pgmnemo | 5 days |
| CDK construct | Pattern B CDK L3 + integration test on real RDS | 3–4 days |
| **Total** | | **~2 weeks** |

**Verdict: PURSUE (research-then-build).** Gate: week-1 research confirms the SDK memory provider interface is public and pluggable before committing to build. The strategic reason: Mem0's exclusivity is a *default* position, not a *lock*. AWS Agent SDK users can override the default if an alternative registers correctly. Our provenance gate (mem0.md §11: *"There is no public write-time provenance gate in the API. The closest analog is metadata= on add() and 'audit logging' on the enterprise tier, but those are post-hoc logs, not pre-write veto"*) is the differentiation story. Target ship: v0.6.0 (2026-08-15).

---

## 2. T2 — Graphiti pgvector Driver (one quarter away)

### Threat

zep.md §13: *"Medium risk that they extract a 'Graphiti for Postgres' driver and attack our home turf. Their multi-DB driver abstraction already supports Neptune; a pgvector driver is a quarter of work away. This is the single biggest threat to monitor."* If Graphiti merges a pgvector driver, it erodes the "Postgres-native" claim — but **not** the structural moat.

### Architectural differentiation that does not require Graphiti feature parity

The moat is write-time enforcement at the **database constraint level**, not at the application or graph layer. Even with a pgvector backend, Graphiti's write path remains fundamentally permissive.

zep.md §11: *"Episode-based provenance. Every node and edge has a back-reference to the originating 'episode' (raw input chunk)... but it's descriptive provenance, not gating provenance — they write first and let you inspect after."*

zep.md §10: *"Write-time provenance gate. They have provenance tracking post-hoc (episodes link back to source), but they do not have a gate that refuses to write low-provenance facts at ingestion time. That is our differentiator. Graphiti writes anything the LLM extracts; we hold the gate."*

### Specific guarantees pgmnemo offers that Graphiti+pgvector cannot

| Guarantee | pgmnemo mechanism | Graphiti+pgvector status |
|---|---|---|
| **Pre-write veto** | `gate_strict` GUC: `INSERT` on `mem_item` with NULL `commit_sha`/`artifact_hash` fails at constraint level — not application level | No equivalent; write always succeeds if LLM extraction returns a result |
| **Bypass-proof enforcement** | RLS policy on `mem_item` is evaluated by Postgres executor, not by application code. A compromised agent or buggy SDK cannot sidestep it without `ALTER POLICY` (requires superuser) | Graphiti Python layer enforces nothing; calling code can write any edge |
| **Zero LLM dependency at ingest** | `pgmnemo.ingest()` gates, scores, embeds, and stores without a mandatory LLM call per chunk | Graphiti requires LLM NER+relation extraction per episode; zep.md §4: *"Entity & fact extraction. LLM-driven NER + relation extraction"* |
| **Operational unification** | pgmnemo + pgvector = one Postgres instance, one backup, one HA config, one RLS policy surface | Graphiti + pgvector still requires the Graphiti Python service running separately, plus Neo4j/FalkorDB/Kuzu if the full graph is used |
| **Bitemporality (post-v0.5)** | `t_valid_from`/`t_valid_to` trigger closes conflicting facts at write time inside the DB transaction | Graphiti's `invalid_at` is set by LLM-detected contradiction; no DB-level temporal constraint |

**Monitoring:** set a GitHub watch on `getzep/graphiti` PRs filtered for "postgres" or "pgvector". A merged pgvector driver is a P0 strategic event requiring a re-evaluation memo within 7 days. Assign to: Chief Architect.

---

## 3. T3 — Letta Aurora in Production (Bilt, 1M+ agents)

### Threat

letta.md §8: Bilt runs *"1M+ personalized stateful agents in production for neighborhood commerce"* on Letta backed by Aurora PostgreSQL. "Postgres-native memory" is now a mainstream claim, not a differentiator.

### What "write-time enforcement at the RLS layer" actually means

pgmnemo's gate is three interlocking mechanisms, all below the application layer:

1. **Column constraint:** `mem_item.commit_sha` has a `CHECK (gate_strict = false OR commit_sha IS NOT NULL)` evaluated per-row at `INSERT`/`UPDATE` time. No application code path can skip this check.
2. **RLS policy:** `CREATE POLICY mem_ingest ON mem_item FOR INSERT WITH CHECK (pgmnemo.gate_check(commit_sha, artifact_hash))` — evaluated by the Postgres executor after constraint check, before the row reaches the heap. A `SET ROLE agent_role` connection cannot write a provenance-free row regardless of how `INSERT` is constructed.
3. **GUC `gate_strict`:** When `ON` (default in production), the above policies are enforced. Application cannot disable them without `SUPERUSER` or explicit `ALTER SYSTEM`.

### What `core_memory_append` cannot prevent (letta.md §10)

letta.md §10: *"Letta has no equivalent. Their memory is whatever the agent writes via `core_memory_append` — no quality gate, no provenance check, no anti-poisoning defense. The MemGPT paradigm explicitly trusts the agent to manage memory well; in practice agents write hallucinations into core memory and they persist."*

`core_memory_append` is a Python function exposed to the LLM as a tool call. The call path is: **LLM → tool schema → Letta Python runtime → Postgres `UPDATE agents SET core_memory = core_memory || $1`**. There is no intermediate DB-level validation. A hallucinated memory write is indistinguishable from a valid one at the storage layer. Letta's Aurora usage (letta.md §4: *"backed by PostgreSQL in production or SQLite for local dev"*) stores agent memory *at the application layer* — Aurora is used as a durable KV store, not as an enforcement point.

pgmnemo's enforcement point is the **opposite**: Aurora/RDS with pgmnemo installed enforces the gate **inside the DB transaction**, before any row lands in the heap. Even if Letta's Python runtime is compromised or bypassed, the Postgres executor enforces the policy. The claim collapses to: Letta uses Postgres for durability; pgmnemo uses Postgres for **correctness guarantees**.

**Revised positioning tagline (CROSS_CUTTING_SYNTHESIS #2):** *"Write-time enforcement at the RLS layer"* — not *"Postgres-native"*. Letta is already Postgres-native. We are Postgres-enforced.

---

## 4. ROADMAP Impact

### v0.4.1 (target 2026-05-30) — No change

Production hardening (R1–R4, R7, R10) remains the correct priority. T1/T2/T3 do not change the urgency of the Agency RFC items. Hold scope.

### v0.5.0 (target 2026-06-20) — Add bitemporality item

**Add:** Bitemporality primitive (Rec #6) alongside existing H-06 temporal weight tuning.

Scope: `t_valid_from TIMESTAMPTZ DEFAULT now()` and `t_valid_to TIMESTAMPTZ DEFAULT 'infinity'` on `mem_item`; trigger that sets `t_valid_to = NOW()` on the superseded row when a conflicting write arrives (matching `lesson_key` or explicit `supersedes_id`); SQL view `mem.as_of(ts TIMESTAMPTZ)` filtering on `t_valid_from <= ts AND t_valid_to > ts`. This closes the most-cited Graphiti advantage (zep.md §4: *"Bitemporal edges (t_valid / t_invalid) — Graphiti core"*) without requiring LLM extraction.

**Hypothesis declaration required:** ICE score before adding to v0.5.0 scope. Effort ~1 week. No bench impact expected (retrieval function unchanged; `as_of()` is additive). No acceptance gate change unless temporal weight tuning hypothesis H-06 reuses the same column.

### v0.6.0 (target 2026-08-15) — Add two adoption-tooling items

**Add to existing "framework adapters" scope:**
- `pgpm install pgmnemo` package (Rec #5) — 3–5 days
- AWS Agent SDK adapter MVP (Rec #4) — gated on week-1 research confirming SDK extensibility

Both fit the v0.6.0 "adoption tooling" theme without displacing existing items (R8, R9, five framework adapters). If AWS research fails (SDK is not pluggable), the slot is reclaimed for another adoption item.

### No items drop

T3 (Letta Aurora) validates current positioning; no pivot required. T2 (Graphiti) does not require feature parity — bitemporality is additive, not defensive. T1 (Mem0 AWS) adds work but removes nothing.

---

## 5. Recommendation Feasibility: #4, #5, #6

### Rec #4 — AWS Agent SDK adapter

**Feasibility: HIGH** (pure Python client wrapping pure SQL — no compilation, no binary packaging). Key unknown is whether the AWS Agent SDK memory provider interface is public and pluggable; this is the sole research gate. If the interface is documented, Pattern A (Lambda adapter) is 5 engineering days of implementation.

**Effort:** 3-day research spike + 5-day build + 3-day CDK construct = **~2 weeks total**. Assign to: one engineer.

**Target release:** v0.6.0 (2026-08-15). If research spike (by 2026-05-30) confirms SDK is pluggable, begin implementation in parallel with v0.5.0. If spike returns negative, escalate to WG for alternative wedge into AWS ecosystem.

**Risk:** Mem0's exclusivity may be contractual (AWS Marketplace partner agreement). If the SDK enforces the default programmatically and does not expose a provider registration API, the adapter is not possible at the SDK layer — we fall back to documentation ("use pgmnemo on RDS and wire your agent manually") rather than a first-class integration. Probability of contractual lock: estimated ~30% based on TechCrunch framing ("exclusive").

### Rec #5 — `pgpm install pgmnemo`

**Feasibility: VERY HIGH.** pgmnemo is pure SQL (no C compilation). pgpm packages are pure SQL DDL distributed via npm with dependency resolution (constructive_agenticdb.md §10: *"pgpm is npm-for-SQL [4][5]. Modules are pure SQL, distributed via npm, versioned, with dependency resolution"*). pgmnemo's SQL files already exist; packaging requires writing a `pgpm.toml` (or equivalent manifest), declaring `pgvector >= 0.7.0` as a dependency, and publishing to the npm registry under `@pgmnemo/pgmnemo`.

**Effort:** 3–5 days (manifest authoring + publish + smoke test via `pgpm deploy`). No existing ROADMAP items displaced.

**Target release:** v0.6.0 (2026-08-15). Could ship earlier as a standalone distribution-channel action in v0.5.x if adoption urgency warrants.

**Why this matters beyond Constructive:** pgpm is positioning itself as the de-facto distribution channel for modular Postgres packages (constructive_agenticdb.md §13: *"Their incentive is to make pgpm the standard distribution channel"*). If pgmnemo is absent from pgpm, Constructive AgenticDB owns the channel by default for any developer who discovers pgpm first.

### Rec #6 — Bitemporality (`t_valid_from` / `t_valid_to` + `mem.as_of()`)

**Feasibility: HIGH.** The schema change is additive (new nullable columns + trigger + view). No existing query signatures break. `mem_item` already has `created_at`; adding `t_valid_from DEFAULT created_at` on migration is safe.

**Effort:** 1 week: 2 days schema + trigger, 1 day `mem.as_of()` view, 1 day migration SQL + MIGRATION.md update, 1 day bench re-run to confirm no recall regression.

**Target release:** v0.5.0 (2026-06-20). Requires hypothesis declaration per ROADMAP change policy. Proposed hypothesis ID: H-07 (temporal schema). Acceptance gate: `significance_test_extended.py` exit ≤ 1 on all LoCoMo/LongMemEval cells (bitemporality column is additive; no recall-path change expected).

**Strategic note:** This does NOT require Graphiti feature parity. Graphiti's temporal edges are produced by LLM-detected contradiction resolution. pgmnemo's `t_valid_to` is set by a DB trigger on schema-level conflict (`supersedes_id FK` or duplicate `lesson_key`). The mechanism is simpler, more deterministic, and does not require an LLM call — which is precisely the cost advantage (zep.md §9: *"Graphiti's per-chunk LLM extraction is expensive at scale"*).

---

*This document is an internal architectural position paper. Verbatim competitor quotes are sourced from deep-dive reports dated 2026-05-16. Do not publish externally.*
