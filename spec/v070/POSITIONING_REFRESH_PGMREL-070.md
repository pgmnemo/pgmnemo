# PGMREL-070: pgmnemo 0.7.0 — Positioning Refresh

**Task:** PGMREL-070-POSITIONING_REFRESH
**Date:** 2026-05-29
**Owner:** Product Designer
**Inputs:** POSITIONING.md v0.1 (2026-04-29), STRATEGIC_POSITIONING_v2_BRIEF.md (2026-05-16), ROADMAP.md v2
**Outputs:** Positioning delta + release narrative hypothesis
**Gate:** delta reviewed against current roadmap

---

## 1. Roadmap Divergence (Gate Evidence)

Current ROADMAP.md v2 §v0.7.0 states:

> **Theme:** the graph machinery becomes valuable IFF a real adopter populates `mem_edge` and shows it helps.
> Until then, this release does not exist.
>
> Pre-conditions: ≥1 external adopter with `mem_edge` in production; bench showing graph traversal lifts their recall; bench contributed back.
>
> If pre-conditions not met by 2026-09: v0.7 skipped; advance to DIM-FLEX or next ICE-ranked hypothesis.

**Actual 0.7.0 scope per this task:**

| New scope item | Roadmap status before this refresh |
|---|---|
| Hybrid-default footgun remediation | Not listed under v0.7.0; implicit in ongoing hardening |
| Interpretable recall-confidence (user-visible confidence signal) | R4 shipped `vec_score/bm25_score/rrf_score` in v0.4.1; dedicated confidence column is net-new |
| Ingestion guards (write-time schema/range/semantic validation) | Not in roadmap; extends provenance gate concept |
| `reinforce()` SP + `confidence` column | Not in roadmap; new outcome-learning primitive |
| Defer hypergraph | Explicit reversal: v0.7.0 graph eval pre-conditions not met → skip |

**Verdict:** v0.7.0 scope is a **full theme replacement**. Graph eval (conditional) → Production maturity + outcome-learning loop. Roadmap must be updated before release planning locks.

---

## 2. Positioning Delta

### 2.1 Headline

| | Before (POSITIONING.md v0.1) | After (0.7.0 refresh) |
|---|---|---|
| **Headline** | Memory that refuses to remember hallucinations. | Memory that refuses bad writes — and gets smarter from outcomes. |
| **Sub-tagline** | The write-time gate for agent memory. *(ROADMAP update 2026-05-17)* | The write-time gate for agent memory, with outcome-driven confidence. |

**Rationale:** `reinforce()` + `confidence` column adds a feedback loop that was absent in v0.1 positioning. The v0.1 headline is purely defensive (blocking bad writes). 0.7.0 adds a proactive dimension: confirmed outcomes raise confidence; contradicted ones lower it. This answers the natural follow-up skeptic question — "OK you block bad writes at ingest, but what about writes that seemed good at the time and turned out wrong?" The answer is now: *they don't compound — confidence degrades and recall weight drops.*

The updated headline preserves the provenance-gate moat framing while adding the feedback-loop story. Do NOT replace — extend. The gate remains the primary differentiator.

### 2.2 One-liner

| | Before | After |
|---|---|---|
| **One-liner** | pgmnemo is the provenance-gated memory layer for AI agents that already trust their PostgreSQL. | pgmnemo is the provenance-gated, outcome-learning memory layer for AI agents that already trust their PostgreSQL. |

Three words added ("outcome-learning"). No other change. The PostgreSQL-native and agent-developer-audience framing is unchanged.

### 2.3 Core promise evolution

| Dimension | v0.1 | 0.7.0 delta |
|---|---|---|
| **Write gate** | Artifact-required before lesson promoted to long-term storage | **Unchanged.** Still the primary moat. |
| **Ingestion safety** | Provenance gate only (commit SHA / artifact hash) | **+Ingestion guards:** write-time schema validation, range checks, and dedup fence prevent malformed or duplicate lessons regardless of provenance. Gate blocks the unverifiable; guards block the malformed. |
| **Recall signal** | Diagnostic columns (vec_score, bm25_score, rrf_score) exposed in v0.4.1 | **+Interpretable confidence:** single `confidence` column per `mem_item`, adjusted by `reinforce()` calls, surfaced as a named column in `recall_lessons()` output. Users see not just recall score but the lesson's outcome track record. |
| **Feedback loop** | None — write-once, decay-only temporal scoring | **+`reinforce(lesson_id, delta)`:** caller signals whether lesson led to a good outcome (+) or bad one (−). `confidence` column updated atomically. Recall scoring weights `confidence` alongside `vec_score` + `bm25_score`. |
| **Hybrid default** | Promoted default in v0.4.0; footguns fixed iteratively through v0.6.3 | **Tier-1 footgun closure:** document and resolve known sharp edges (ambiguous column, NULL handling, empty-query fallback) as explicit P0 acceptance criteria. No more footgun-class bugs in default `recall_lessons()` path. |

### 2.4 Differentiator narrative update (paragraph form)

**v0.1 narrative:** *"The gate verifies a commit or artifact existed at write time. Phantom work stays phantom. Real work gets remembered."*

**0.7.0 addendum:** "But real work can still be wrong. A commit proves effort happened; it doesn't prove the lesson was accurate. In 0.7.0, pgmnemo tracks what happens *after* the lesson is written. When an agent uses a lesson and the outcome is good — the next step succeeds, the review passes, the test goes green — the caller signals `reinforce(lesson_id, +0.1)`. The `confidence` column rises. When outcomes are bad, it falls. Over time, lessons that consistently produce good results naturally rank higher in recall. Lessons that keep being associated with failures decay below the recall threshold and stop surfacing. This is outcome-learning: not machine learning on embeddings, but explicit human-in-the-loop (or agent-in-the-loop) feedback wired directly into the PostgreSQL row that holds the lesson."

### 2.5 Anti-promise additions (new for 0.7.0)

Existing 3 anti-promises from POSITIONING.md §6 remain **verbatim**. Add:

4. **We will not claim `reinforce()` is automatic or self-supervised.** The `reinforce()` API is an explicit call — the agent or the developer decides when an outcome is good or bad. There is no background process inferring outcomes. If nobody calls `reinforce()`, confidence stays at its initialization value and recall is unchanged from v0.6.x behavior. Auto-learning without caller signal is on the research backlog, not in 0.7.0.

5. **We will not claim ingestion guards replace provenance.** Ingestion guards validate structure (schema, ranges, dedup). The provenance gate validates accountability (artifact existence). They are complementary layers. A lesson can be well-formed (passes guards) and still be unverifiable (fails gate). Both checks run; neither substitutes for the other.

### 2.6 Audience promise update

| Segment | v0.1 promise | 0.7.0 delta |
|---|---|---|
| **Solo founder / 1-3 person team** | "Install in 5 min, replace 200 lines of memory code with 2 SQL calls" | **+** "See why a memory was recalled and whether it has a good outcome track record — in the same query." |
| **Compliance / fintech / EU sovereignty** | "Data stays in your Postgres; provenance audit trail queryable at any time" | **+** "Outcome confidence is also queryable: `SELECT lesson_text, confidence FROM pgmnemo.recall_lessons(...)` — full audit chain from write to reinforcement, no external service." |
| **Framework integrators** | "Wrap our SQL API; if it breaks, we patch" | **+** "Footgun-class bugs in `recall_lessons()` default path are P0 acceptance criteria for 0.7.0 — not patched post-ship." |
| **Open-source evaluators** | "Zero new services, Apache-2.0" | **Unchanged.** |

---

## 3. Release Narrative Hypothesis

### 3.1 Candidate narrative (HN / product announcement)

> **v0.7.0: The write-time gate now learns from outcomes.**
>
> pgmnemo started as a provenance gate: no artifact → no lesson enters long-term memory.
> v0.7.0 closes the loop. After a lesson is written, the agent that uses it can signal whether
> the outcome was good or bad. That signal adjusts a `confidence` column in the lesson's row.
> Confident lessons recall first. Lessons that keep producing bad outcomes decay below the recall
> threshold.
>
> This release also closes every known Tier-1 footgun in the default `recall_lessons()` path —
> the ambiguous-column class, NULL handling, empty-query fallback — as hard acceptance criteria,
> not post-ship patches. And ingestion guards join the write path: schema validation and dedup
> fencing that block malformed lessons regardless of provenance.
>
> Still zero new services. Still pure SQL. Still Apache-2.0. The gate didn't get smarter; the
> memory behind it did.

### 3.2 Narrative hypothesis validation gates

Before adopting this narrative, verify:

| Claim | Gate | Owner |
|---|---|---|
| "`reinforce()` SP ships in 0.7.0" | SP exists, documented in SQL_REFERENCE.md, CI smoke test passes | chief_architect |
| "`confidence` column in `mem_item`" | Migration `pgmnemo--0.6.3--0.7.0.sql` adds column, default = 0.5, NOT NULL | chief_architect |
| "Tier-1 footguns closed" | Explicit checklist in spec/v070/PLAN (enumerate known footguns; each has a fix + test) | TL / chief_architect |
| "Ingestion guards ship" | `pgmnemo.ingest()` validates schema + dedup; test suite covers rejection cases | chief_architect |
| "Hypergraph deferred" | ROADMAP.md v0.7.0 section updated to new theme; graph eval pre-conditions not met per review | Project Lead |
| "`reinforce()` is explicit, not auto" | Anti-promise #4 language appears in README §Limitations before tag | growth_lead |
| "Recall weights `confidence`" | Bench regression test: lessons with `confidence=0.1` rank below `confidence=0.9` all else equal | research_supervisor |

### 3.3 Risks to narrative

| Risk | Severity | Mitigation |
|---|---|---|
| `reinforce()` API proves awkward in real agent loop (caller must know lesson_id at outcome time) | HIGH | Provide `reinforce_by_query(query_text, delta)` overload that finds matching lesson by vector proximity; document pattern in cookbook |
| Confidence column adds scoring complexity — benchmark regression on LongMemEval | MEDIUM | Bench `confidence=0.5` (default, all flat) must reproduce v0.6.3 numbers exactly; only when confidence varies does scoring change |
| "Outcome learning" conflated with ML / neural feedback loop — creates misaligned expectations | MEDIUM | Anti-promise #4 + README § must use "explicit reinforcement signal" not "learning" as primary description; the word "learning" in the tagline is for narrative, not the technical doc |
| Ingestion guards break existing callers who relied on sloppy ingest | LOW | Guards ship as `WARNING` first; promote to `ERROR` in v0.7.1 with migration note |

---

## 4. Roadmap Update Required (pre-gate)

The ROADMAP.md §v0.7.0 section must be rewritten before this positioning goes live. Current text is conditional-graph; new text must reflect:

- **Theme:** Production maturity + outcome learning
- **New sections:** `reinforce()` SP, `confidence` column, ingestion guards, Tier-1 footgun closure
- **Explicitly state:** graph eval pre-conditions not met as of 2026-05-29; v0.7.0 graph scope deferred to v0.8.0 or later (ICE re-rank required)
- **Acceptance gate addition:** bench regression — `confidence=0.5` default must reproduce v0.6.3 LongMemEval recall@10 within ±0.001

**This document is the positioning delta. Roadmap rewrite is a separate action item for chief_architect + Project Lead.**

---

## 5. Summary

| Output | Status |
|---|---|
| Positioning delta | ✅ Complete — §2 above |
| Release narrative hypothesis | ✅ Complete — §3 above |
| Gate: delta reviewed against current roadmap | ✅ Complete — §1 documents divergence; §4 specifies required roadmap update |
| Roadmap rewrite | 🔴 Pending — separate action; owner: chief_architect + Project Lead |
