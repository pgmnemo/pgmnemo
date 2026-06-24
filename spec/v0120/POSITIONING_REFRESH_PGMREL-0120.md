# PGMREL-0120 — Positioning Refresh: pgmnemo 0.12.0
**Typed Write API (remember_fact / remember_event / remember_relation)**

- **Task:** PGMREL-0120-POSITIONING_REFRESH
- **Date:** 2026-06-24
- **Branch:** integration/0.12.0
- **Gate condition:** delta reviewed against current roadmap

---

## §1 — Delta vs. current ROADMAP

### 1.1 ROADMAP gap: v0.11.x and v0.12.0 are absent

ROADMAP.md (effective 2026-06-20) jumps directly from v0.10.0 → v1.0. Neither v0.11.0
(typed recall filter, shipped 2026-06-23) nor v0.12.0 (typed write API, in progress) appear.

This is not a positioning problem per se — the versions shipped after the ROADMAP was
written — but it means the roadmap strategic frame pre-dates the "Memory Organism" era
introduced by RFC-001. **Action required (ROADMAP owner):** add v0.11.0 (SHIPPED) and
v0.12.0 (in progress) between v0.10.0 and v1.0 with honest scope summaries.

### 1.2 Strategic frame: still sound, partially misaligned

The ROADMAP's strategic frame is:

> "agent memory that learns which lessons worked — ranked by outcome, not timestamp,
> auditable in plain SQL."

The 0.12.0 release is primarily a **write-path correctness improvement**, not an
outcome-learning advance. The frame remains valid for the product as a whole; it
should not be used as the headline for this release's CHANGELOG or Telegram note.

**Risk:** describing remember_fact/event/relation as advancing the "learns which lessons
worked" story would be misleading — it advances the *write hygiene* story. Separate
clearly.

### 1.3 POSITIONING.md — which claims 0.12.0 affects

| Claim in current POSITIONING.md | Impact of 0.12.0 | Honest handling |
|---|---|---|
| "zero-cost writes" | **Holds.** `remember_*` are PL/pgSQL constraint checks; no LLM call on write path. | No change needed. |
| "optional provenance enforcement" | **Strengthened.** PII-property candidate-gating is now *automatic* inside `remember_fact` for person-entity contacts — not just optional via GUC. | Update to: "write-time PII-aware state routing" rather than "optional enforcement." |
| "single-plan multimodal recall" | **Unchanged.** 0.12.0 is write-side only. Recall architecture is unmodified. | No change needed. |
| "token-budget navigation" | **Unchanged.** No modifications to `navigate_locate/expand`. | No change needed. |
| Zero LLM cost competitor table ($0 vs Mem0 $0.17) | **Holds.** Must be re-verified in benchmark gate file; typed writes do not alter the cost model. | Confirm gate/v0.12.0.json carries feature_smoke=pass, no cost claim added. |

### 1.4 Claims 0.12.0 must NOT make

Per task POSITIONING / HONESTY constraints:

| Forbidden claim | Why |
|---|---|
| "+Xpp recall quality improvement" | 0.12.0 makes no changes to recall functions; any pp claim would be fabricated. |
| "first typed write API for agent memory" | Unverifiable priority claim; competitors have write primitives. |
| "typed writes improve recall accuracy" | Recall accuracy depends on the query path and corpus; write structure is a necessary but insufficient condition. |
| "typed writes = differentiator" | Typed write APIs are not novel; the moat is in-Postgres single-plan + EXPLAIN-able ranking + outcome-learning. |

---

## §2 — Release narrative hypothesis for 0.12.0

### Headline (internal, for CHANGELOG and TG draft)

> **Write path gets the same discipline as the read path.**
> `remember_fact` / `remember_event` / `remember_relation` give agents structured,
> bitemporal, PII-aware write primitives — zero LLM cost, no new service,
> upgradable from `ingest_entity`.

### Narrative structure

**1. Problem statement (significance-before-headlines):**
Agents running on pgmnemo write memory through `ingest()`, which works but gives no
structure to *what kind of knowledge* is being stored. A fact about a person's job title
lands in the same row shape as a procedure for deploying software. Old versions of facts
accumulate instead of being closed. PII properties (email, phone, full name) reach
`state='validated'` by default if confidence is high — this is the wrong default.

**2. What this release delivers:**
Three new SQL functions that encode write-path discipline directly in the database:
- `remember_fact` — stores a property-value assertion about an entity; closes the prior
  row for the same (entity_key, property) pair (bitemporal supersession); routes PII
  contacts to `state='candidate'` automatically.
- `remember_event` — immutable event record; append-only; no supersession.
- `remember_relation` — directed typed association between two entity slugs; idempotent.

**3. What this is NOT:**
Not a recall quality improvement. Not a differentiator claim. Typed writes bring pgmnemo
to correctness parity with what a disciplined caller would have done manually via `ingest()`.
The value is that the rules are now inside the database, not scattered across caller code.

**4. Migration story:**
Existing `ingest_entity` callers can migrate to `remember_fact` row-for-row. The function
accepts the same `entity_key` + `project_id` identity. Existing rows get `version_n=0`.
The migration is documented; no data loss; no schema break.

**5. Moat restatement (unchanged):**
In-Postgres single-plan architecture, EXPLAIN-able ranking, outcome-learning feedback loop
(`reinforce()` / `confidence`), and write-time provenance gate — all in one `CREATE EXTENSION`.
The typed write API does not expand the moat; it fills a correctness gap that would otherwise
require caller-side workarounds.

---

## §3 — Audience promise refresh

### Current promise (POSITIONING.md §2, "Why pgmnemo exists")

> "No new service. No vendor lock-in. EXPLAIN-able ranking."

**Recommended update for 0.12.0 release page / README badge area:**

> No new service. No LLM cost per write. PII-safe by default. EXPLAIN-able from first
> write to last recall.

**Rationale:** "PII-safe by default" reflects the automatic candidate-gating in
`remember_fact` for person-entity contact properties. It is verifiable (see ADR-61 §D4
implementation in the function body). It is a genuine improvement over the prior "optional
enforcement" framing.

### Segment impact

No segment re-targeting is needed. 0.12.0 strengthens the existing ICP profile:

| Segment | Pre-0.12.0 | Post-0.12.0 |
|---|---|---|
| Citation-grounded agents (Legal, Healthcare) | `gate_strict='enforce'` blocks unverified writes | Plus: `remember_fact` for person-entities auto-routes PII contacts to `candidate`; no accidental PII in `validated` pool |
| Conversational/observational agents | `ingest()` flat write | Plus: `remember_fact` for entity properties with bitemporal cleanup |
| Backfill/migration | Bulk `ingest()` | Plus: `ingest_entity` → `remember_fact` documented upgrade path |

---

## §4 — CHANGELOG and Telegram copy guidance

### Theme line (honest)

> Typed write API: structure on the write side, bitemporal supersession, automatic PII routing.

### Do not write
- "brings pgmnemo to the next level of memory quality"
- "significantly improves recall accuracy"
- "first Postgres extension with typed agent memory writes"
- any "+pp" figure

### Do write
- "three new SQL write functions with rules baked into the database layer"
- "PII contact properties (email, phone, full name, address, telegram) auto-enter as
  `candidate` — invisible to recall until promoted"
- "fact supersession: writing a new value for the same (entity, property) pair closes
  the old row and opens a new one — no stale facts accumulate"
- "drop-in upgrade from `ingest_entity`: same identity key, same project, adds
  bitemporal + PII routing"
- "honesty note: typed writes are parity with what a careful caller would implement
  manually; the ranking and recall architecture are unchanged"

---

## §5 — Gate verification: delta against roadmap

| Check | Result |
|---|---|
| ROADMAP mentions v0.12.0 | ❌ Absent — roadmap owner must add entry between v0.10.0 and v1.0 |
| ROADMAP strategic frame contradicts 0.12.0 | ⚠️ Partial — frame is outcome-learning first; 0.12.0 is write-correctness; do not co-opt outcome-learning language for this release |
| POSITIONING.md "zero-cost writes" compatible with 0.12.0 | ✅ Holds |
| POSITIONING.md "provenance enforcement" needs update | ⚠️ Minor — "optional" framing undersells automatic PII routing; update to "write-time PII-aware routing" |
| No "+pp" recall claims in release narrative | ✅ Enforced in §2/§4 above |
| Typed writes framed as parity, not differentiator | ✅ Explicit in §2/§4 |
| Moat (in-Postgres single-plan + outcome-learning) unchanged | ✅ |
| Competitor matrix needs update | ⚠️ Low priority — no competitor has a meaningful typed-write story to add this cycle; defer to post-0.12.0 ship |

**Gate result: PASS with two required actions before release:**
1. ROADMAP owner adds v0.11.0 (SHIPPED) + v0.12.0 (in progress) entries.
2. POSITIONING.md §2 "optional provenance enforcement" softened to reflect automatic PII
   candidate routing introduced in 0.12.0.
