# pgmnemo Roadmap

**Status:** v2 — customer-driven, bench-gated
**Effective:** 2026-05-13
**Supersedes:** the previous spec-driven ROADMAP (MAGMA §-numbered phases)
**Workflow rules:** see core-team workflow

---

## Strategic frame

pgmnemo is the **provenance-gated PostgreSQL memory layer** for AI agent developers
who already run Postgres. Our wedge customer (the team positioning (internal)) installs us in
under 5 minutes and replaces 200 lines of ad-hoc memory code with two SQL calls.

We have **one fixable competitive weakness today** and **one durable moat:**

- 🔴 **Weakness:** LongMemEval recall@10 = 0.933 (BM25 baseline = 0.982). A potential
  adopter benchmarks against `tsvector + ts_rank_cd` and we lose by 5 pp.
- 🟢 **Moat:** Provenance gate (`gate_strict` GUC + `verified_at` semantics). None of
  Mem0 / Zep / pgvector / MAGMA enforce "no commit SHA → no write" at the DB layer.

Everything in the next 18 months is shaped by these two facts.

### Competitive response (2026-05-17)

WG-STRAT-260517 ratified the following threat postures (full synthesis: `spec/competitive/SYNTHESIS_PGMNEMO_2026-05-17.md`):

- **T1 — Mem0 / AWS Agent SDK:** 3-day research spike (due 2026-05-30) to determine if the SDK memory provider interface is pluggable. If pluggable → build Lambda adapter for v0.6.0. If locked → kill AWS track; Anthropic MCP Registry wrapper proceeds regardless.
- **T2 — Graphiti pgvector driver (est. Q3 2026):** Monitor `getzep/graphiti` PRs for postgres/pgvector. Counter with bitemporality (H-07, v0.5.0) — DB-level trigger resolution vs LLM-detected contradiction. No feature parity race.
- **T3 — Letta Aurora in production:** "Postgres-native" is surrendered. Claim is now "write-time enforcement at the RLS layer." Letta is reframed as category-validator ("MemGPT showed agents need memory; pgmnemo shows memory needs a gate"). No defensive pivot required.

Tagline updated to: **"The write-time gate for agent memory."** (POSITIONING.md updated 2026-05-17.)

---

## Releases at a glance

| Tag | Theme | Headline gate | Target ship |
|---|---|---|---|
| **v0.3.1** | Hygiene + documentation + bench-gate in CI | All issues closed; gate file mechanism live; no recall change | 2026-05-13 (✅ SHIPPED) |
| **v0.4.0** | Hybrid retrieval promoted to default | LoCoMo session recall@10 +4.15pp (p<0.05); LongMemEval neutral | 2026-05-15 (✅ SHIPPED) |
| **v0.4.1** | **Production hardening** (per first external production-user feedback, 2026-05-16) | R1, R2 docs, R3, R4, R7 from production-user requirements; bench recall@10 gate maintained | 2026-05-17 (✅ SHIPPED) |
| **v0.5.0** | Per-category lift + graph helpers | R5, R6, R10 + H-06 temporal weight tune; previously-planned graph-deprecation cycle folded in here | 2026-05-17 (✅ SHIPPED) |
| **v0.5.1** | Correctness fixes | MCP write path via `ingest()` SP; `temporal_boost` comment corrected | 2026-05-18 (✅ SHIPPED) |
| **v0.5.2** | MCP wheel fix + CI gate | `pgmnemo-mcp` empty wheel fix ([#32](https://github.com/pgmnemo/pgmnemo/issues/32)), `packaging-smoke` CI, docs rollback/calibration | 2026-05-22 (✅ SHIPPED) |
| **v0.6.0** | Adoption tooling (Mem0/AWS, MCP wrapper) | 2026-05-23 (✅ SHIPPED) — RRF Fix-A attempt rolled back (`-22.44 pp` regression confirmed); `as_of_ts` deferred together |
| **v0.6.1** | `as_of_ts` (F2) + stress test fixtures (F3) | 2026-05-23 (✅ SHIPPED) — F1 RRF Fix-A A-scale variant benchmarked, regressed; F1 deferred to v0.6.2 with real-DB evidence in `benchmarks/longmemeval/results/v0.6.1_realdb_20260523/` |
| **v0.6.2** | RRF Fix-A — sparse-safe (Cormack 2009) | 2026-05-24 (✅ SHIPPED) — `recall@10: 0.9491 → 0.9604 (+1.13 pp, p=0.017)` on LongMemEval-S N=500 bge-m3 1024d; resolves v0.6.0/v0.6.1 RRF deferral |
| **v0.6.3** | `recall_lessons` / `recall_hybrid` AmbiguousColumn hotfix (R1) + R2-R4 USAGE.md docs | 2026-05-24 (✅ SHIPPED) — unblocks production recall (was failing at 0 % hit rate on an internal deployment); `#variable_conflict use_column` directive, no signature change |
| **v0.7.0** | Optional graph eval (only if adopter pulls) | Bench that exercises `mem_edge`; +X pp gate | 2026-09 (conditional) |
| **v1.0** | API freeze + stability commitment | ≥ 3 external adopters with public case studies; 2 consecutive non-breaking releases | 2026-Q4 |

---

## v0.3.1 — Hygiene foundation (in-flight)

**Theme:** close the gaps that block credibility, not the gaps that move recall.

### What ships
- All open issues (`#12`–`#16`) closed ✅ (done this session)
- `docs/BENCHMARK_PROTOCOL.md` + `METRICS_BY_VERSION.md` + `scripts/significance_test_extended.py` + viz tools ✅ (done this session)
- `docs/SQL_REFERENCE.md` ✅
- core-team workflow (this discipline document) ✅
- CI: `.github/workflows/release.yml` adds a blocking step that runs `significance_test_extended.py` against the `benchmarks/gate/v<version>.json` snapshot. Missing file = fail.
- LongMemEval v0.3.0 row in METRICS_BY_VERSION.md Table 3 (run is currently in-flight)

### Acceptance gate
- Significance test vs v0.3.0 = exit 0 or 3 (neutral or watchlist, no regression)
- CI gate-file mechanism passes on a smoke test
- Zero open GitHub Issues with `release-hygiene` label

### Customer value
"You install v0.3.1 and the docs answer everything a careful evaluator asks before adoption."

### Out of scope
No recall-algorithm change. No new SQL functions. This is purely hygiene.

---

## v0.4.0 — **Beat BM25 on LongMemEval** (the customer-acquisition release)

**Theme:** the only release in 2026 with a single goal: **adopters benchmark us and we win.**

### Strategy

Promote `recall_hybrid()` from EXPERIMENTAL to the default path, but **only if** real-DB
confirmation matches the v0.2.2 simulation. The hybrid formula is:

```
hybrid_score = 0.4 × cosine_similarity + 0.4 × ts_rank_cd(lesson_tsv, q, 32)
             + 0.1 × importance_factor + 0.1 × recency_factor
```

Simulation showed +12.7 pp LoCoMo recall@10 and +5.8 pp LongMemEval MRR. If real DB
confirms even half of that, we win the BM25 comparison.

### Pre-implementation hypothesis declaration

```
Hypothesis ID:    H-01 (was on ROADMAP H2 backlog)
Wedge problem:    Customer benchmarks pgmnemo vs `tsvector + ts_rank_cd`; pgmnemo loses by 5pp recall@10 on LongMemEval. Customer doesn't adopt.
Expected lift:    LongMemEval recall@10 0.933 → 0.97 (+3.7pp minimum), MRR 0.847 → 0.90 (+5pp minimum)
Acceptance gate:  significance_test_extended.py exit=1 with NO exit=2 cell on either LoCoMo or LongMemEval
Estimated cost:   2 weeks (algorithm exists; need real-DB run, weight tuning, default-switch RFC)
ICE:              I=10 C=8 E=6 (highest in backlog)
Alternative:      Stay EXPERIMENTAL, lose the BM25 race
```

### What ships if gate passes
- `recall_hybrid()` becomes the default in `recall_lessons()` (single function, two formula paths)
- `recall_lessons_vector_only()` kept for explicit dense-only callers
- Migration `pgmnemo--0.3.1--0.4.0.sql` flips internal default
- CHANGELOG one-liner: `recall@10 on LongMemEval-S improved 0.933 → 0.97x (+Xpp, p=Y). Now matches/beats BM25 baseline.`

### What ships if gate FAILS
- v0.4.0 becomes a different release (probably v0.5 content brought forward)
- `recall_hybrid()` stays EXPERIMENTAL with documented "simulation +12pp, real-DB +Xpp" in `BENCHMARKS.md`
- Open `HYBRID_REAL_DB_GAP` issue, defer promotion decision

### Out of scope
- New graph features
- New embedders (deferred to v0.5)
- Schema changes

### Customer value
"Postgres extension with provenance gate that's also competitive with BM25 on memory recall."

---

## v0.4.1 — Production hardening (✅ SHIPPED 2026-05-17) **— REPRIORITISED**

**Theme:** ship the items that the first external production adopter
asked for in their production requirements (2026-05-16). Previously this
release was scoped as "graph deprecation cycle"; that scope is deferred to v0.5.x
in favour of production-hardening items with concrete adopter pull.

**Pivot driver:** First external production-user RFC (production recall@10 gate passed
on an internal corpus, recall@10 = 0.5745 N=1060, p_adj < 0.001) requested specific
production-readiness improvements. Per `docs/the release process §4.4` "Do we have an
adopter who asked for this?" — answer: yes, 6 of 10 R-items, with specific
production evidence.

### What ships (production-feedback RFC items)

| R-item | Scope | Priority |
|---|---|---|
| **R1** — GUC registration | Register `recency_weight`, `ef_search`, `importance_weight`, `disable_hybrid` in `pg_settings`. New defaults per an internal ablation: `recency_weight=0.05` (was 0.20 in v0.2.x; v0.4.0 kept that), `ef_search=100`, `importance_weight=0.15`. | P0 (blocking) |
| **R2** — Distribution docs | Add `docs/INSTALL.md` covering PGXN + Dockerfile snippets. PGXN/GitHub release artifacts already shipped in v0.4.0. | P0 |
| **R3** — `pgmnemo.stats()` SP | Single diagnostic SP returning version + lesson_count + embedding_coverage_pct + mem_edge_count + GUC values + hybrid_enabled + orphan_count. | P1 |
| **R4** — `recall_lessons()` diagnostics | Append `vec_score`, `bm25_score`, `rrf_score` columns. Backward-compatible (named-column callers unaffected; positional callers re-audit). | P1 |
| **R7** — Upgrade orphan recovery | Document `docs/MIGRATION.md §B.5` recovery from extension-orphan functions. Include `orphan_count` in `pgmnemo.stats()` for proactive detection. | P0 |
| **R10** — Overload deprecation NOTICE | 4-arg `traverse_causal_chain()` emits NOTICE. Remove in v0.5.0. | P3 |

### What's deferred to v0.5.x

The previously-planned graph-deprecation cycle (BFS-mixin demotion, `traverse_*`
"advanced/optional" labelling, `recall_lessons_pooled()` documentation note,
`edge_kind` ENUM stays) **moves to v0.5.x**, decoupled from the production-hardening
release. The R6 item (mem_edge contract + helper) makes graph features actually
useful, which contradicts the v0.4.1-as-deprecation framing. Rationale: deprecate
features that nobody uses; document + improve features that someone *just started*
using.

### Acceptance gate

- `scripts/significance_test_extended.py` exit ≤ 1 (neutral or improvement) on all 3 tables
  vs v0.4.0 baseline. R1 changes GUC defaults — must re-bench LoCoMo session under new
  defaults and confirm no regression.
- An internal LoCoMo bench rerun on the v0.4.1 candidate shows recall@10
  ≥ 0.55 (production gate held).
- `pgmnemo.stats()` smoke test passes in CI (similar to `smoke_recall_hybrid.py`).
- `pg_settings` lists all 4 GUCs with documented defaults.
- `docs/INSTALL.md` walks a fresh user from `docker pull pgvector/pgvector:pg17` to
  `SELECT pgmnemo.stats()` in under 10 minutes.

### Customer value

"v0.4.1 is the first release driven by external production user requirements.
GUCs visible in pg_settings, `pgmnemo.stats()` for one-query health checks, and
`vec_score` exposed in `recall_lessons()` for diagnostic re-rankers."

### Bench cost reduction

`benchmarks/scripts/bench_embed_cache.py` (shipped v0.4.0) means weight-tuning
ablation studies for R1's GUC defaults are now feasible: 54-cell grid runs
in ~2.7 hours (was 45 hours). Phase B of v0.5.0 will use this.

---

## Inter-release docs (post-v0.4.1, pre-v0.5.0) — WG-STRAT-260517

Documentation and positioning work that landed in `main` after the v0.4.1 release
tag (2026-05-17). These items do **not** require their own extension version —
they ship continuously as docs commits, not PGXN releases. Tracked here so the
next release planning checkpoint sees them as done before v0.5.0 scope is locked.

| Item | Rec # | Priority | Owner | Status |
|---|---|---|---|---|
| POSITIONING.md created (MIT/HNSW/bundled Ollama corrections) + tagline "The write-time gate for agent memory." (Candidate A) | #1, #2 | **P0** | growth_lead | ✅ shipped 2026-05-17 (commits `01895f7`, `a27c3f9`) |
| Cost-per-1K-memories comparison table validated and published | #3 | P1 | growth_lead | due 2026-05-30 — validate GPT-5-mini pricing before publish; table drafted in POS-GROWTH §3 |
| Letta citation added to README §"Why this exists": "MemGPT showed agents need memory; pgmnemo shows memory needs a gate." | #8 | P2 | growth_lead | due 2026-05-30 |

---

## v0.5.0 — Per-category lift + graph helpers (target 2026-06-20)

**Theme:** fix the weakest LoCoMo category (`temporal`), unblock Stella V5, AND
ship the graph-feature documentation + helper SP requested by the production adopter (R6).
Previously-planned graph-deprecation cycle is folded in here (BFS-mixin
demotion + `recall_lessons_pooled()` documentation note + `recall_lessons_with_graph()`
opt-in function), now alongside `pgmnemo.add_edge()` (R6).

### Production-feedback RFC items shipped in v0.5.0

| R-item | Scope |
|---|---|
| **R5** — query_text preprocessing | `pgmnemo.max_query_text_chars` GUC (default 2000), internal truncation with NOTICE, NULL/empty graceful fallback |
| **R6** — `mem_edge` contract + helper | `pgmnemo.add_edge(source_id, target_id, relation_type, weight, metadata)` SP with `ON CONFLICT DO UPDATE`. `docs/SQL_REFERENCE.md §1.2` documents the canonical contract. |
| **R10** — Overload removal | 4-arg `traverse_causal_chain()` removed (only 5-arg form remains). NOTICE deprecation in v0.4.1 gave adopters one release to migrate. |

### Hypotheses

**H-06: Temporal weight tuning**
```
Wedge problem:    v0.3.0 showed -3.81pp drift on LoCoMo temporal/recall@5. Temporal is the weakest category at 0.645 recall@10.
Expected lift:    temporal/recall@10 0.645 → 0.70 (+5.5pp). OVERALL r@10 unchanged ± 1pp.
Acceptance gate:  significance_test_extended.py exit=1 on temporal/recall@10 cell, exit ≠ 2 anywhere
Cost:             1 week — single GUC default change + bench
ICE:              I=7 C=8 E=8
```

**H-02: Stella V5 embedder path unblock**
```
Wedge problem:    Paper-canonical LongMemEval embedder is Stella V5; transformers 5.8 incompatibility forced us to bge-m3 substitution. Customers comparing to paper numbers see a deviation footnote.
Expected lift:    LongMemEval recall@10 +1–3pp vs bge-m3 substitution baseline
Acceptance gate:  Bench against new embedder shows no regression vs bge-m3; ideally significant improvement
Cost:             1–2 days — fork modeling_qwen.py with rope_theta fix OR pin compatible transformers
ICE:              I=6 C=7 E=9
```

### What ships
- `pgmnemo.recency_weight` default re-tuned based on bench grid-search
- Stella V5 instructions documented in `benchmarks/ADDENDA/LONGMEMEVAL_EMBEDDER_STELLA.md`
- Optional: a `pgmnemo.temporal_boost` GUC for adopters with timestamp-sensitive workloads

### Competitive response items (WG-STRAT-260517, P1 + P2)

Added alongside the production-feedback RFC items. R5, R6, R10 scope unchanged.

| Item | Rec # | Priority | Owner | Notes |
|---|---|---|---|---|
| Bitemporality primitive (H-07): `t_valid_from TIMESTAMPTZ DEFAULT now()` + `t_valid_to TIMESTAMPTZ DEFAULT 'infinity'` on `mem_item`; trigger sets `t_valid_to = NOW()` on conflicting write; `mem.as_of(ts TIMESTAMPTZ)` view | #6 | P2 | chief_architect | Hypothesis declaration required per ROADMAP change policy. ICE score pre-addition. Acceptance gate: `significance_test_extended.py` exit ≤ 1 on all cells (additive schema, no recall-path change expected). 1-week effort. |
| Anthropic MCP server wrapper — HTTP wrapper on `pgmnemo.ingest()` / `pgmnemo.recall_lessons()` SQL API; ships as separate `pgmnemo-mcp` Python package (does NOT require extension version bump), tracked here for visibility | — | P1 | chief_architect | 1-2 days. Submit to Anthropic MCP Registry when available. Execute regardless of AWS Agent SDK research verdict (independent counter-channel). |

### Out of scope
- Graph features (no adopter has asked)
- New schema columns beyond H-07 bitemporality
- API breaking changes

### Customer value
"v0.5 sharpens the weakest recall category and matches the paper-canonical embedder when it works."

---

## v0.6.0 — Adoption tooling

**Theme:** make pgmnemo trivial to wire into the agent frameworks the wedge customer uses.

### What ships
1. **Framework adapters** (Python/TypeScript, ~50–100 LOC each):
   - `pgmnemo-langchain` — `BaseChatMessageHistory` implementation
   - `pgmnemo-llamaindex` — `BaseDocumentStore` implementation
   - `pgmnemo-anthropic-sdk` — example with `claude-agent-sdk` memory tool
   - `pgmnemo-openai-assistants` — example
   - `pgmnemo-ts` — minimal TS client (Vercel AI SDK style)
2. **"Compare to BM25" cookbook** (`docs/cookbook/vs_bm25.md`) — recipe that lets the
   adopter run our bench on their data with one command and see the side-by-side number
3. **Docker Compose quick-start** (`examples/docker-compose.yml`)
4. **First public case study** — concrete external adopter, real
   workload, real number

### Competitive response items (WG-STRAT-260517, P1 + P2)

Added alongside adoption tooling. R8, R9 scope unchanged.

| Item | Rec # | Priority | Owner | Notes |
|---|---|---|---|---|
| `pgpm install pgmnemo` — publish to npm registry under `@pgmnemo/pgmnemo`; manifest + smoke test via `pgpm deploy` | #5 | P1 | chief_architect | 3-5 days. pgmnemo is pure SQL — no compilation needed. Declare `pgvector >= 0.7.0` as dependency. |
| AWS Agent SDK Lambda adapter (Pattern A) + CDK L3 construct | #4 | P1-gated | chief_architect | **Gated on 2026-05-30 research verdict.** If SDK memory provider interface is public and pluggable: build. If contractually locked: kill; slot reclaimed for another adapter. |
| Benchmark card v0 (8-cell design per POS-RS spec; pre-registered protocol; CI auto-publish on tag) | #7 | P1 | research_supervisor | **Target: published pre-v0.6.0 tag, by 2026-07-15.** Mandatory negative cells C4 (BM25 gap) and C5 (production corpus) included. Raw per-question outputs committed to repo. |

### Acceptance gate
- ≥ 3 of the 5 adapters tested end-to-end against `docker compose up`
- Cookbook walkthrough completes in under 10 minutes from `git clone`
- At least one external project (not by us) committed to using pgmnemo in production
- `pgpm install pgmnemo` smoke test passes (if shipped in this release)
- Benchmark card v0 published and accessible (if shipped pre-tag)

### Out of scope
- Adapter framework breaking changes (we just wrap our SQL API; if they break, we patch)
- Cloud hosting offering (not building a service)

### Customer value
"In 10 minutes I went from `git clone` to `pgmnemo beats BM25 on my own benchmark`."

---

## v0.7.0 — Conditional: Graph eval (only if adopter pulls)

**Theme:** the graph machinery becomes valuable IFF a real adopter populates `mem_edge`
and shows it helps. Until then, this release does not exist.

### Pre-condition (must all be true to start this release)
1. At least one external adopter has populated `mem_edge` in a production workload
2. That adopter has a reproducible bench showing graph traversal lifts their recall
3. Their bench gets contributed back to our suite as `benchmarks/graph_*/`

### What ships (only if pre-conditions met)
- BFS graph-proximity mixin in default `recall_lessons()` (re-promoted from v0.4.1 deprecation)
- Documented graph-eval bench with reproducible methodology
- A second `edge_kind` extension if the adopter needed it (e.g. `entity-via-shared-attribute`)

### If pre-conditions not met by 2026-09
- v0.7 skipped; advance to v0.7 = embeddings configurability (DIM-FLEX) or whatever bench-validated H-N is next on ICE
- Graph features stay at v0.4.1 "advanced/optional" status indefinitely

### Customer value (conditional)
"Multi-hop graph reasoning works because a real production user proved it works."

---

## v1.0 — Stability commitment

**Theme:** API freeze; the project is officially production-ready.

### v1.0 gating criteria (all must be true)
| Gate | Threshold |
|---|---|
| LongMemEval recall@10 | ≥ 0.97 with p_corr < 0.05 (v0.4 hypothesis confirmed real-DB) |
| LoCoMo session recall@10 | ≥ 0.80 (held or improved vs v0.3.0 baseline 0.7994) |
| No `temporal` category regression | recall@10 ≥ 0.70 |
| Stable API | 2 consecutive releases without breaking SQL function signature changes |
| External adopters | ≥ 3 with public case study; ≥ 1 production deployment of > 6 months |
| Documentation | Every public SQL function has both a reference entry and a worked example |
| Operational story | Rollback procedure validated end-to-end on actual customer data once |
| Bench protocol | Snapshot mechanism (Phase A reuse) live; per-release bench takes < 10 min |

### What v1.0 explicitly does NOT promise
- MAGMA-paper full conformance (academic, separate audience)
- Real-time / streaming memory ingest (batch is fine for wedge customer)
- Cloud-hosted SaaS (not our shape)
- Compatibility with non-Postgres backends

---

## Workflow integration

Every release runs `docs/the release process §3` cycle. Each release ships with:
- A new row in `benchmarks/METRICS_BY_VERSION.md` (all applicable tables)
- A new `docs/img/scorecard_v<version>.svg`
- A regenerated `docs/img/all_metrics_history.svg`
- A regenerated `docs/img/progression_*.svg`
- A `spec/reports/SIG_<bench>_v<version>_vs_v<prev>.json`
- A `CHANGELOG.md` entry that uses customer-readable language (not implementation jargon)

If a release misses the bench-gate, **the tag is not pushed.** No "ship and document
the regression in CHANGELOG" pattern — that was v0.2.0 / v0.3.0 process and it ended in
the strategic pivot of 2026-05-13.

---

## What is NOT on this roadmap (and why)

| Idea | Status | Reason |
|---|---|---|
| DIM-FLEX (configurable vector dim) | 🔵 Backlog | Speculative; no adopter has asked; current `vector(1024)` works |
| REST API wrapper | 🔵 Backlog | We're an extension, not a service |
| MAGMA §4 Adaptive Traversal Policy | 🔵 Frozen | Spec-driven, no customer pull, no bench measures it |
| MAGMA §5 Dual-stream Consolidation | 🔵 Frozen | Same |
| Multi-tenant RBAC beyond RLS | 🔵 Backlog | No adopter request; RLS handles 95% of multi-tenant cases |
| Graph features expansion (more edge types, ML-learned edges) | ⏸ Conditional on v0.7 | See v0.7 pre-conditions |
| Compete on absolute scale (1B+ rows) | 🔵 Out of scope | Wedge customer is 10k–10M rows; pgvector handles it |
| Promote `recall_hybrid()` based on simulation only | ❌ Will not happen | Real-DB confirmation gate is mandatory |

---

## Roadmap-change policy

- **Minor scope trim** (remove item from a release): Project Lead unilateral; logged in CHANGELOG
- **Scope addition** (add item to release in progress): only if accompanied by hypothesis declaration (§2.1 of the release process) AND ICE re-score
- **Release date slip** ≤ 1 week: PI unilateral, posted in Monday status
- **Release date slip** > 1 week: requires written postmortem (in `spec/reports/`)
- **Cross-release pivot** (e.g. dropping a planned feature): WG vote 3/5 + customer-signal citation

This document is reviewed and updated at every release tag. Changes tracked in git log.
