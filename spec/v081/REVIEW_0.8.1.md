# pgmnemo 0.8.1 Release Review
**Date:** 2026-06-04  
**Reviewer:** research_supervisor (PGMDOC-260604-REVIEW)  
**Branch:** release/v0.8.1 vs origin/main  
**Verdict:** ✅ **APPROVE_FOR_RELEASE** (after fixes applied in this commit)

---

## 1. Scope reviewed

4 commits on release/v0.8.1 beyond origin/main:

| SHA | Task | Files |
|---|---|---|
| `347dcf4` | WRITE-AGENTS | `AGENTS.md` (+799 lines) |
| `bc7792c` | FIX-POSITIONING | `README.md`, `POSITIONING.md`, `docs/WHY_PGMNEMO.md`, `ROADMAP.md` |
| `04c241a` | ISSUES | `extension/pgmnemo--0.8.0--0.8.1.sql`, `extension/pgmnemo.control`, `META.json`, `docs/INSTALL.md`, `docs/USAGE.md`, `CHANGELOG.md` |
| (this commit) | REVIEW | `AGENTS.md` (bug fix), `META.json`, `extension/pgmnemo.control` (framing update) |

---

## 2. PUBLIC-SAFE gate

**Pass.** Exhaustive grep for prohibited strings across all changed public files:

| Check | Result |
|---|---|
| IAQS / Intelifore / design-partner names | ✅ Not found |
| Internal strategy gates G1/G2/G3 | ✅ Not found |
| WG-STRAT / WG-RESTRATEGY / working-group identifiers | ✅ Not found |
| T1/T2/T3 threat postures | ✅ Not found (removed from ROADMAP) |
| ICE: scores / H-0x hypothesis IDs | ✅ Not found in public docs |
| `wedge customer (internal)` / internal parentheticals | ✅ Not found |
| Competitor-owned axis as headline (`temporal = Zep` framing) | ✅ Not found; temporal is described as an in-Postgres capability |
| Roadmap speculation (future versions beyond v0.8.1 docs sprint) | ✅ v1.0 criteria are stable, no unpublished-feature promises |
| Builder/insider jargon in new content | ✅ Not found in sprint-added content |

**Accepted borderline items (pre-existing, not introduced by sprint):**
- `README.md` line 111: "Release workflow and internal process docs are maintained privately by the core team." — factual, acceptable for OSS project. Not a leak.
- `docs/USAGE.md` line 446: "An internal RFC (production corpus N=1081...)" — pre-existing content, not added by this sprint. No project names. Low-risk.
- `docs/USAGE.md` line 175: "MAGMA §3" in edge taxonomy section — describes the shipped `edge_kind` feature, not internal strategy. Acceptable.

---

## 3. AGENTS.md review

### Completeness
All 18 user-facing functions documented with purpose and at least one SQL example:
`ingest`, `reinforce` (×2 overloads), `reembed`, `reembed_batch`, `recompute_content`,
`add_edge`, `transition_lesson`, `evict_expired_lessons`, `recall_lessons`,
`recall_hybrid`, `recall_lessons_pooled`, `navigate_locate`, `navigate_expand`,
`traverse_causal_chain`, `traverse_temporal_window`, `stats()`, `recall_stats` (view),
`version()`, `get_temporal_boost()`. ✅

### SQL signature accuracy

| Function | AGENTS.md | Real 0.8.0 SQL | Match |
|---|---|---|---|
| `ingest(p_role, p_project_id, p_topic, p_lesson_text, [p_importance, p_embedding, p_commit_sha, p_artifact_hash, p_metadata])` | ✅ | 9 params, correct | ✅ |
| `recall_lessons(embedding, k, role_filter, project_id_filter, query_text, as_of_ts)` | ✅ | 6 params, as_of_ts last | ✅ |
| `recall_hybrid(embedding, query_text, k, role_filter, project_id_filter, vec_weight, bm25_weight, rrf_k)` | ✅ | 8 params + trailing confidence/match_confidence cols | ✅ |
| `navigate_locate(embedding, text, token_budget_chars, jsonb_filter)` | ✅ | Returns id/preview/score/tokens_consumed/navigation_path | ✅ |
| `navigate_expand(ids[], expand_fields[], graph_expand_depth, graph_expand_threshold)` | ✅ | Returns id/content/expand_detail/graph_neighbor_ids/graph_neighbor_previews/tokens_consumed/navigation_path | ✅ |
| `reinforce(p_lesson_id, p_outcome)` | **BUG FIXED** (see §5) | param is `p_lesson_id` | ✅ (after fix) |
| `reinforce(p_lesson_ids[], p_outcome)` | ✅ | correct | ✅ |
| `reembed(p_lesson_id, p_new_vector)` | ✅ | correct | ✅ |
| `reembed_batch(p_lesson_ids[], p_new_vectors[])` | ✅ | correct | ✅ |
| `recompute_content(p_lesson_id, p_new_text)` | ✅ | correct | ✅ |
| `traverse_causal_chain(start_id, max_depth, relation_types[], only_active, direction)` | ✅ | 5 params | ✅ |
| `traverse_temporal_window(start_id, window_interval, include_unlinked, role_filter, project_id_filter, k)` | ✅ | 6 params, `start_id` (not `start_lesson_id`) | ✅ |
| `stats()` → 19 cols | ✅ | confirmed in SQL | ✅ |

### Outcome strings verified
`reinforce()` outcome strings are `'success'`, `'failure'`, `'neutral'` — confirmed against `CASE p_outcome WHEN 'success'...` in `pgmnemo--0.8.0.sql`. ✅

### Recipe coverage
Six adoption recipes in §4: agent loop, token-economy retrieval, multi-tenant scoping, incremental embedding updates, bitemporal recall, provenance gate modes. All use correct signatures. ✅

---

## 4. Positioning docs review

### README.md
- Tagline: **"In-your-Postgres agent memory — single-plan multimodal recall, token-budget navigation, provenance-gated writes."** ✅ Reframed.
- Version badge: `0.8.1` ✅
- LongMemEval badge: `0.9604` ✅ (was 0.9334)
- LoCoMo badge: `0.8409` — correct, unchanged.
- Benchmark table row: updated to 0.9604, honest note about gap narrowing from −5pp to −2.2pp. ✅
- Compatibility matrix: shows `0.8.x (current)`. ✅
- "What's next" blurb replaced with v0.8.0 release note. ✅
- Docker/PGXN install: `v0.8.1`. ✅
- Features section: navigate_locate/expand, outcome-learning, hybrid RRF Fix-A, in-place maintenance, bitemporal recall, role scoping, diagnostic observability. ✅ MAGMA edge taxonomy label removed from features. ✅

### POSITIONING.md
- Header: no internal working-group identifiers remaining. ✅
- Tagline: added token-economy framing. ✅
- Differentiator claim: expanded to "single SQL query plan" + JSONB pushdown + graph proximity + EXPLAIN-able. ✅
- Competitor matrix: `recall_substrate` cell updated to single-plan fusion framing. ✅
- Benchmark table: LME 0.9334 → 0.9604. ✅
- Decision framework: added token-economy navigation and outcome-learning. ✅
- No Zep/temporal as headline axis. ✅

### docs/WHY_PGMNEMO.md
- Problem statement: expanded from hallucinated memory to 3 failure modes (hallucination, opaque ranking, context bloat). ✅
- What pgmnemo is: single-plan fusion as lead, 6 capabilities including navigate_locate quickstart. ✅
- "Don't choose us if": removed "entity-relation-temporal reasoning → use Zep"; replaced with accurate "LLM-driven, real-time contradiction resolution → use a purpose-built graph service". ✅
- Dockerfile: updated to v0.8.1. ✅
- Honest current state: v0.8.0 (2026-06-03), 0.9604, correct. ✅

### ROADMAP.md
- All internal-strategy content removed: WG-STRAT-260517, T1/T2/T3, wedge customer (internal), ICE scores, R-item codes in headlines, "core-team workflow", owner names (growth_lead, chief_architect, research_supervisor). ✅
- Releases table: all v0.7.x and v0.8.0 marked ✅ SHIPPED with accurate dates. ✅
- v0.8.1 in-progress row added. ✅
- v1.0 criteria: stable, no specific external-adopter count gating exposed. ✅
- "What is NOT on this roadmap" table: clean, no MAGMA §4/§5 frozen items with internal names. ✅

---

## 5. Bugs found and fixed in this commit

### BUG-1 (CRITICAL — wrong named argument in AGENTS.md) — FIXED

**Location:** `AGENTS.md` line 145 (original)  
**Severity:** Would cause PostgreSQL error if copied verbatim by users  
**Root cause:** Named-argument syntax used wrong parameter name

```sql
-- WRONG (before fix):
SELECT pgmnemo.reinforce(lesson_id := 42, p_outcome := 'success');
-- PostgreSQL would error: "function pgmnemo.reinforce(lesson_id => integer, ...) does not exist"

-- CORRECT (after fix):
SELECT pgmnemo.reinforce(p_lesson_id := 42, p_outcome := 'success');
```

Real parameter name confirmed in `extension/pgmnemo--0.8.0.sql`:
```sql
CREATE OR REPLACE FUNCTION pgmnemo.reinforce(
    p_lesson_id BIGINT,
    p_outcome   TEXT
)
```

**Fix applied:** `AGENTS.md` line 145 corrected. USAGE.md was already correct (`p_lesson_id`).

---

### Minor framing updates (applied in this commit)

**`extension/pgmnemo.control` comment:**  
- Before: `'Multi-agent memory substrate for PostgreSQL — provenance-gated, vector-hybrid recall'`  
- After: `'In-your-Postgres agent memory — single-plan multimodal recall, token-budget navigation, provenance-gated writes'`  
*Rationale: control file comment surfaces in `SELECT * FROM pg_extension` and `pgxn info` — should match the new framing.*

**`META.json` abstract and description:**  
Updated to single-plan multimodal fusion framing, listing all 0.8.0 capabilities. PGXN search and package index will reflect the corrected description.

---

## 6. Issue resolutions — accuracy verdict

| Issue | Resolution status | Accuracy |
|---|---|---|
| **#18** GUC access pattern | `docs/INSTALL.md §"Reading the GUCs"` (pre-existing, complete); new GUC table added to `docs/USAGE.md §"GUC reference"` | ✅ Accurate. `SHOW pgmnemo.*` limitation correctly explained. All 10 GUCs documented. |
| **#19** Docker without compiler | `docs/INSTALL.md` Path 3 (ADD + unzip, no build tools) and Path 4 (COPY, air-gapped). v0.8.1 versions throughout. | ✅ Accurate. Dockerfile snippets use COPY semantics, no `make` or compiler required. |
| **#20** `pgmnemo.stats()` SP | stats() ships in v0.4.1 (14 cols) and v0.7.0 (19 cols). `docs/USAGE.md §"Health check"` documents all 19 columns. `pgmnemo--0.8.0--0.8.1.sql` is a no-DDL version bump. | ✅ Accurate. stats() was already in 0.8.0 — correctly handled as docs-only. |
| **#24** Orphan recovery | `docs/MIGRATION.md §B.5` (pre-existing, complete). Cross-reference added to `docs/USAGE.md §"Health check"`. | ✅ Accurate. Detection query and `ALTER EXTENSION pgmnemo ADD FUNCTION` recovery documented. |
| **#41** Stale release failure | Noted in CHANGELOG.md as "superseded by v0.7.2 packaging fix + v0.8.0". | ✅ Correct — issue is fully stale. |

---

## 7. Extension packaging review

**`extension/pgmnemo--0.8.0--0.8.1.sql`:**
- Contains `\echo ... \quit` guard — correct PGXS pattern; only activates via `ALTER EXTENSION UPDATE`
- Zero DDL statements — correct for a docs-only version bump
- Schema is identical to v0.8.0
- Comment header accurately describes all resolved issues
- Will pass CI `installcheck` (no schema changes to regress)

**`extension/pgmnemo.control`:**
- `default_version = '0.8.1'` ✅
- `trusted = true` — correct; pure SQL extension, no C code
- `superuser = false` — correct

**`META.json`:**
- `version: '0.8.1'` ✅
- `provides.pgmnemo.file: 'extension/pgmnemo--0.8.0.sql'` — points to flat install SQL (0.8.0), which is correct (flat install creates the full schema; upgrade delta is separate)
- All required PGXN spec 1.0.0 fields present

---

## 8. Issues safe to close (orchestrator/founder closes after merge)

| Issue | Safe to close? | Reason |
|---|---|---|
| **#18** | ✅ YES | GUC access pattern fully documented in INSTALL.md + USAGE.md |
| **#19** | ✅ YES | Docker COPY install (no compiler) in INSTALL.md Paths 3 & 4; versions updated to v0.8.1 |
| **#20** | ✅ YES | stats() already shipped in 0.8.0; 19-col reference in USAGE.md; acknowledged in CHANGELOG |
| **#24** | ✅ YES | MIGRATION.md §B.5 complete; cross-referenced from USAGE.md with orphan_count query |
| **#41** | ✅ YES | Stale automated issue; superseded by v0.7.2 + v0.8.0; noted in CHANGELOG |

---

## 9. Verdict

**✅ APPROVE_FOR_RELEASE**

All 5 targeted issues resolved accurately. One SQL signature bug (BUG-1: wrong named arg `lesson_id` → `p_lesson_id` in AGENTS.md) found and fixed in this review commit. Framing updates applied to `pgmnemo.control` comment and `META.json` abstract/description. All public docs pass the PUBLIC-SAFE gate. Extension packaging is correct for a docs-only version bump. Branch is ready to merge and tag `v0.8.1`.
