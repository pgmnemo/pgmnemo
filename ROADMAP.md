# pgmnemo Roadmap

**Status:** v2 — customer-driven, bench-gated
**Effective:** 2026-05-13
**Supersedes:** the previous spec-driven ROADMAP (MAGMA §-numbered phases)
**Workflow rules:** see `docs/WORKFLOW.md`

---

## Strategic frame

pgmnemo is the **provenance-gated PostgreSQL memory layer** for AI agent developers
who already run Postgres. Our wedge customer (`docs/POSITIONING.md §4`) installs us in
under 5 minutes and replaces 200 lines of ad-hoc memory code with two SQL calls.

We have **one fixable competitive weakness today** and **one durable moat:**

- 🔴 **Weakness:** LongMemEval recall@10 = 0.933 (BM25 baseline = 0.982). A potential
  adopter benchmarks against `tsvector + ts_rank_cd` and we lose by 5 pp.
- 🟢 **Moat:** Provenance gate (`gate_strict` GUC + `verified_at` semantics). None of
  Mem0 / Zep / pgvector / MAGMA enforce "no commit SHA → no write" at the DB layer.

Everything in the next 18 months is shaped by these two facts.

---

## Releases at a glance

| Tag | Theme | Headline gate | Target ship |
|---|---|---|---|
| **v0.3.1** | Hygiene + documentation + bench-gate in CI | All open issues closed; gate file mechanism live; no recall change | 2026-05-20 |
| **v0.4.0** | **Beat BM25 on LongMemEval** — hybrid promotion | LongMemEval recall@10 ≥ 0.97 with `p_corr < 0.05`; no LoCoMo regression | 2026-06-10 |
| **v0.4.1** | Deprecation of dead complexity | BFS-mixin out of default recall path; graph traversal SPs marked optional | 2026-06-24 |
| **v0.5.0** | Per-category lift — temporal + embedder | LoCoMo `temporal/recall@10` ≥ 0.70 (was 0.645); Stella V5 path unblocked | 2026-07-15 |
| **v0.6.0** | Adoption tooling | 5 framework adapters; "Compare to BM25" cookbook; first external case study | 2026-08-15 |
| **v0.7.0** | Optional graph eval (only if adopter pulls) | Bench that exercises `mem_edge`; +X pp gate | 2026-09 (conditional) |
| **v1.0** | API freeze + stability commitment | ≥ 3 external adopters with public case studies; 2 consecutive non-breaking releases | 2026-Q4 |

---

## v0.3.1 — Hygiene foundation (in-flight)

**Theme:** close the gaps that block credibility, not the gaps that move recall.

### What ships
- All open issues (`#12`–`#16`) closed ✅ (done this session)
- `docs/BENCHMARK_PROTOCOL.md` + `METRICS_BY_VERSION.md` + `scripts/significance_test_extended.py` + viz tools ✅ (done this session)
- `docs/SQL_REFERENCE.md` ✅
- `docs/WORKFLOW.md` (this discipline document) ✅
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

## v0.4.1 — Deprecation cycle

**Theme:** remove the complexity that didn't earn its keep in v0.2.x – v0.3.0.

### What gets demoted (kept in SQL, removed from headline / default path)

| Feature | Action | Rationale |
|---|---|---|
| BFS graph-proximity mixin in `recall_lessons()` | Move to opt-in `recall_lessons_with_graph()` | Currently runs every call but no-op when `mem_edge` empty (typical case). Wastes CPU, adds attack surface. |
| `traverse_causal_chain()` | Mark "advanced/optional" in docs; keep SQL | Only useful when adopter has populated `mem_edge`; very rare |
| `traverse_temporal_window()` | Same | Same |
| `recall_lessons_pooled()` | Document as "for paper-canonical session-level bench only" | Wedge customer doesn't pool by session |
| `edge_kind` ENUM + per-kind indexes | Stay; cost is near-zero | Not headline, but kept for future graph eval |

### Acceptance gate
- `significance_test_extended.py` exit=0 (neutral) — removing dead code must not affect any cell
- No GitHub Issue created against any v0.4.0 release citing reliance on BFS-in-default

### Customer value
"pgmnemo became simpler in v0.4.1: the default recall path no longer carries graph machinery that production users don't enable."

---

## v0.5.0 — Per-category lift

**Theme:** fix the weakest LoCoMo category (`temporal`) and unblock Stella V5.

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

### Out of scope
- Graph features (no adopter has asked)
- New schema columns
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
4. **First public case study** in `docs/ADOPTION.md` — concrete external adopter, real
   workload, real number

### Acceptance gate
- ≥ 3 of the 5 adapters tested end-to-end against `docker compose up`
- Cookbook walkthrough completes in under 10 minutes from `git clone`
- At least one external project (not by us) committed to using pgmnemo in production

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

Every release runs `docs/WORKFLOW.md §3` cycle. Each release ships with:
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
- **Scope addition** (add item to release in progress): only if accompanied by hypothesis declaration (§2.1 of WORKFLOW.md) AND ICE re-score
- **Release date slip** ≤ 1 week: PI unilateral, posted in Monday status
- **Release date slip** > 1 week: requires written postmortem (in `spec/reports/`)
- **Cross-release pivot** (e.g. dropping a planned feature): WG vote 3/5 + customer-signal citation

This document is reviewed and updated at every release tag. Changes tracked in git log.
